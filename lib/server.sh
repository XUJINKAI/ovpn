#!/usr/bin/env bash
# 服务端初始化、渲染、应用和 CA 维护。

ovpn_render_server() {
    local output="$1" template_name="${2:-default}" assignments_name="${3:-}" configs_name="${4:-}"
    local template="$OVPN_RESOURCE_DIR/config/server/$template_name.conf.tpl" assignment key appended
    local OVPN_WARN_UNUSED_TEMPLATE_VARS=0
    local -a empty_assignments=() empty_configs=()
    local -A env_values=()
    [[ -n "$assignments_name" ]] || assignments_name=empty_assignments
    [[ -n "$configs_name" ]] || configs_name=empty_configs
    local -n assignments_ref="$assignments_name"
    ovpn_safe_regular_file "$template"
    ovpn_load_env "$OVPN_RESOURCE_DIR/config/ovpn.env" env_values
    for assignment in "${assignments_ref[@]}"; do
        key="${assignment%%=*}"
        env_values["$key"]="${assignment#*=}"
    done
    appended="$output.appended"
    ovpn_render_append_config "$template" "$appended" "$configs_name" "服务端"
    mv -- "$appended" "$output"
    ovpn_apply_env "$output" env_values
    ovpn_template_replace "$output" "$output.paths" \
        CA_CERT "$OVPN_RUNTIME_CA" \
        SERVER_CERT "$OVPN_RUNTIME_SERVER_CERT" \
        SERVER_KEY "$OVPN_RUNTIME_SERVER_KEY" \
        CRL_FILE "$OVPN_RUNTIME_CRL" \
        TLS_CRYPT_V2_SERVER_KEY "$OVPN_RUNTIME_TLS_CRYPT_V2" \
        AUTH_VERIFY_SCRIPT "$OVPN_AUTH_VERIFY_SCRIPT" \
        AUTH_DB "$OVPN_STATE_DIR/auth-db"
    mv -- "$output.paths" "$output"
}

ovpn_build_ca() {
    local days="${1:-3650}"
    ovpn_info "初始化 CA 和签发数据库"
    ovpn_pki_init "$days" || return
    ovpn_info "签发服务端证书"
    ovpn_pki_sign_server "$days" || return
    ovpn_info "生成 tls-crypt-v2 服务端密钥"
    openvpn --genkey tls-crypt-v2-server "$OVPN_STATE_DIR/pki/tls-crypt-v2-server.key" || return
    chmod 0600 -- "$OVPN_STATE_DIR/pki/tls-crypt-v2-server.key" || return
}

ovpn_ca_init() {
    local force=0 exists=0 days=3650 timestamp backup=""
    local -a backup_sources=()
    while (( $# > 0 )); do
        case "$1" in
            --force) force=1; shift ;;
            --days) (( $# >= 2 )) || ovpn_die "--days 缺少天数"; days="$2"; shift 2 ;;
            *) ovpn_die "ca init 未知参数：$1" ;;
        esac
    done
    ovpn_validate_days "$days" || ovpn_die "--days 必须是 1 到 36500 的整数"
    ovpn_require_root
    ovpn_validate_state_dir
    [[ ! -e "$OVPN_STATE_DIR/pki" && ! -L "$OVPN_STATE_DIR/pki" ]] || exists=1
    (( exists == 0 || force == 1 )) || ovpn_die "PKI 已存在；如需替换 CA，请使用 --force"
    (( exists == 1 || force == 0 )) || ovpn_die "PKI 不存在，首次初始化不需要 --force"
    if (( exists == 1 )); then
        ovpn_audit_file A "$OVPN_STATE_DIR/backup/ca-init-<时间>"
        ovpn_audit_file M "$OVPN_STATE_DIR/pki"
        ovpn_audit_file D "$OVPN_STATE_DIR/clients"
    else
        ovpn_audit_file A "$OVPN_STATE_DIR"
    fi
    [[ "$OVPN_DRY_RUN" != 1 ]] || { ovpn_print_audit "检查成功"; return; }

    ovpn_require_command openssl
    ovpn_require_command openvpn
    [[ -x "$OVPN_EASYRSA" ]] || ovpn_die "缺少 Easy-RSA，请先运行 ovpn core install"
    ovpn_info "获取 CA 初始化锁"
    ovpn_lock
    exists=0
    [[ ! -e "$OVPN_STATE_DIR/pki" && ! -L "$OVPN_STATE_DIR/pki" ]] || exists=1
    (( exists == 0 || force == 1 )) || ovpn_die "PKI 已存在；如需替换 CA，请使用 --force"
    install -d -o root -g root -m 0755 -- "$OVPN_STATE_DIR"
    install -d -o root -g root -m 0700 -- "$OVPN_STATE_DIR/backup"
    if (( exists == 1 )); then
        ovpn_info "警告：--force 将替换 CA，并使全部现有客户端失效"
        timestamp="$(date +%Y%m%d-%H%M%S)"
        backup="$OVPN_STATE_DIR/backup/ca-init-$timestamp"
        install -d -o root -g root -m 0700 -- "$backup"
        local path
        for path in "$OVPN_STATE_DIR/pki" "$OVPN_STATE_DIR/clients" "$OVPN_STATE_DIR/auth-db"; do
            [[ -e "$path" || -L "$path" ]] && backup_sources+=("$path")
        done
        (( ${#backup_sources[@]} == 0 )) || cp -a -- "${backup_sources[@]}" "$backup/"
        rm -rf -- "$OVPN_STATE_DIR/pki" "$OVPN_STATE_DIR/clients" "$OVPN_STATE_DIR/auth-db"
    fi
    install -d -o root -g root -m 0700 -- "$OVPN_STATE_DIR/clients"
    : >"$OVPN_STATE_DIR/auth-db"
    chown root:nogroup -- "$OVPN_STATE_DIR/auth-db"
    chmod 0640 -- "$OVPN_STATE_DIR/auth-db"
    if ! ovpn_build_ca "$days"; then
        if (( exists == 1 )); then
            rm -rf -- "$OVPN_STATE_DIR/pki" "$OVPN_STATE_DIR/clients" "$OVPN_STATE_DIR/auth-db"
            for path in "$backup/pki" "$backup/clients" "$backup/auth-db"; do
                [[ ! -e "$path" && ! -L "$path" ]] || cp -a -- "$path" "$OVPN_STATE_DIR/"
            done
            [[ ! -e "$OVPN_STATE_DIR/auth-db" ]] || { chown root:nogroup -- "$OVPN_STATE_DIR/auth-db"; chmod 0640 -- "$OVPN_STATE_DIR/auth-db"; }
            ovpn_die "CA 初始化失败，旧状态已从 $backup 恢复"
        fi
        rm -rf -- "$OVPN_STATE_DIR/pki"
        ovpn_die "CA 初始化失败；已清理不完整 PKI，修复后重新运行 ca init"
    fi
    if (( exists == 1 )); then
        ovpn_cleanup_backups "$OVPN_STATE_DIR/backup"
        printf '旧 CA 和客户端备份：%s\n' "$backup"
    fi
    printf 'CA 初始化完成；运行 ovpn apply 验证配置、部署运行文件并启动服务。\n'
    ovpn_print_audit
}

ovpn_apply_internal() {
    local force_apply="${1:-0}" template_name="${2:-default}" assignments_name="${3:-}" configs_name="${4:-}" activate="${5:-0}"
    local temporary rendered backup was_active=0 was_enabled=0
    temporary="$(mktemp -d)"
    ovpn_register_temp "$temporary"
    rendered="$temporary/server.conf"
    ovpn_render_server "$rendered" "$template_name" "$assignments_name" "$configs_name"
    ovpn_safe_regular_file "$OVPN_RESOURCE_DIR/scripts/auth-verify.sh"
    install -o root -g root -m 0755 -- "$OVPN_RESOURCE_DIR/scripts/auth-verify.sh" "$temporary/auth-verify.sh"
    install -o root -g root -m 0644 -- "$OVPN_STATE_DIR/pki/ca-chain.crt" "$temporary/ca.crt"
    install -o root -g root -m 0644 -- "$OVPN_STATE_DIR/pki/issued/server-chain.crt" "$temporary/server.crt"
    install -o root -g root -m 0600 -- "$OVPN_STATE_DIR/pki/private/server.key" "$temporary/server.key"
    install -o root -g root -m 0644 -- "$OVPN_STATE_DIR/pki/crl.pem" "$temporary/crl.pem"
    install -o root -g root -m 0600 -- "$OVPN_STATE_DIR/pki/tls-crypt-v2-server.key" "$temporary/tls-crypt-v2.key"
    ovpn_info "校验 OpenVPN 候选配置"
    ovpn_core_test_file "$rendered" "$temporary/auth-verify.sh"
    if (( force_apply == 0 )) && [[ -f "$OVPN_SERVER_CONF" && -f "$OVPN_DROPIN" ]] &&
        cmp -s -- "$rendered" "$OVPN_SERVER_CONF" && cmp -s -- "$OVPN_RESOURCE_DIR/systemd/ovpn.conf" "$OVPN_DROPIN" &&
        cmp -s -- "$temporary/ca.crt" "$OVPN_RUNTIME_CA" && cmp -s -- "$temporary/server.crt" "$OVPN_RUNTIME_SERVER_CERT" &&
        cmp -s -- "$temporary/server.key" "$OVPN_RUNTIME_SERVER_KEY" && cmp -s -- "$temporary/tls-crypt-v2.key" "$OVPN_RUNTIME_TLS_CRYPT_V2" &&
        cmp -s -- "$temporary/auth-verify.sh" "$OVPN_AUTH_VERIFY_SCRIPT" && cmp -s -- "$temporary/crl.pem" "$OVPN_RUNTIME_CRL"; then
        rm -rf -- "$temporary"
        ovpn_info "运行配置没有变化"
        if (( activate == 1 )); then
            systemctl enable --now "$OVPN_SERVICE" || ovpn_die "OpenVPN 启动失败；运行配置未改变，请检查 journalctl -u $OVPN_SERVICE"
            ovpn_info "OpenVPN 服务已启用并启动"
        fi
        return
    fi
    ovpn_info "部署 OpenVPN 运行配置"
    systemctl is-active --quiet "$OVPN_SERVICE" && was_active=1
    systemctl is-enabled --quiet "$OVPN_SERVICE" && was_enabled=1
    backup="$temporary/backup"
    install -d -- "$backup"
    [[ ! -d "$OVPN_SERVER_DIR" ]] || cp -a -- "$OVPN_SERVER_DIR" "$backup/server"
    [[ ! -e "$OVPN_DROPIN" ]] || { install -d -- "$backup/dropin"; cp -a -- "$OVPN_DROPIN" "$backup/dropin/ovpn.conf"; }
    install -d -o root -g root -m 0755 -- "$OVPN_SERVER_DIR" "$(dirname -- "$OVPN_AUTH_VERIFY_SCRIPT")" "$(dirname -- "$OVPN_DROPIN")"
    install -o root -g root -m 0600 -- "$rendered" "$OVPN_SERVER_CONF"
    install -o root -g root -m 0644 -- "$temporary/ca.crt" "$OVPN_RUNTIME_CA"
    install -o root -g root -m 0644 -- "$temporary/server.crt" "$OVPN_RUNTIME_SERVER_CERT"
    install -o root -g root -m 0600 -- "$temporary/server.key" "$OVPN_RUNTIME_SERVER_KEY"
    install -o root -g root -m 0644 -- "$temporary/crl.pem" "$OVPN_RUNTIME_CRL"
    install -o root -g root -m 0600 -- "$temporary/tls-crypt-v2.key" "$OVPN_RUNTIME_TLS_CRYPT_V2"
    install -o root -g root -m 0755 -- "$temporary/auth-verify.sh" "$OVPN_AUTH_VERIFY_SCRIPT"
    install -o root -g root -m 0644 -- "$OVPN_RESOURCE_DIR/systemd/ovpn.conf" "$OVPN_DROPIN"
    systemctl daemon-reload
    local service_failed=0
    if (( was_active == 1 )); then
        if (( activate == 1 )) && ! systemctl enable "$OVPN_SERVICE"; then service_failed=1; fi
        if (( service_failed == 0 )) && ! systemctl restart "$OVPN_SERVICE"; then service_failed=1; fi
    elif (( activate == 1 )); then
        systemctl enable --now "$OVPN_SERVICE" || service_failed=1
    fi
    if (( service_failed == 1 )); then
        rm -f -- "$OVPN_SERVER_CONF" "$OVPN_RUNTIME_CA" "$OVPN_RUNTIME_SERVER_CERT" "$OVPN_RUNTIME_SERVER_KEY" "$OVPN_RUNTIME_CRL" "$OVPN_RUNTIME_TLS_CRYPT_V2" "$OVPN_AUTH_VERIFY_SCRIPT"
        [[ ! -d "$backup/server" ]] || cp -a -- "$backup/server"/. "$OVPN_SERVER_DIR"/
        rm -f -- "$OVPN_DROPIN"
        [[ ! -e "$backup/dropin/ovpn.conf" ]] || cp -a -- "$backup/dropin/ovpn.conf" "$OVPN_DROPIN"
        systemctl daemon-reload
        if (( was_active == 1 )); then systemctl start "$OVPN_SERVICE" >/dev/null 2>&1 || true; else systemctl stop "$OVPN_SERVICE" >/dev/null 2>&1 || true; fi
        if (( was_enabled == 1 )); then systemctl enable "$OVPN_SERVICE" >/dev/null 2>&1 || true; else systemctl disable "$OVPN_SERVICE" >/dev/null 2>&1 || true; fi
        ovpn_die "OpenVPN 启动或重启失败；运行文件和原服务状态已尝试回滚，请检查 journalctl -u $OVPN_SERVICE"
    fi
    if (( activate == 1 )); then ovpn_info "OpenVPN 服务已启用并启动"; elif (( was_active == 1 )); then ovpn_info "OpenVPN 服务已重启"; fi
    ovpn_audit_file M "$OVPN_SERVER_CONF"
    ovpn_audit_file M "$OVPN_RUNTIME_CA"
    ovpn_audit_file M "$OVPN_RUNTIME_SERVER_CERT"
    ovpn_audit_file M "$OVPN_RUNTIME_SERVER_KEY"
    ovpn_audit_file M "$OVPN_RUNTIME_CRL"
    ovpn_audit_file M "$OVPN_RUNTIME_TLS_CRYPT_V2"
    rm -rf -- "$temporary"
}

ovpn_apply() {
    local temporary template_name=default assignment
    local -a env_assignments=() extra_configs=()
    while (( $# > 0 )); do
        case "$1" in
            --template) (( $# >= 2 )) || ovpn_die "--template 缺少名称"; template_name="$2"; shift 2 ;;
            --env) (( $# >= 2 )) || ovpn_die "--env 缺少 KEY=VALUE"; ovpn_validate_env_assignment "$2"; env_assignments+=("$2"); shift 2 ;;
            --add-config)
                (( $# >= 2 )) || ovpn_die "--add-config 缺少配置行"
                [[ -n "$2" && "$2" != *$'\n'* && "$2" != *$'\r'* ]] || ovpn_die "--add-config 必须是非空单行配置"
                extra_configs+=("$2")
                shift 2
                ;;
            *) ovpn_die "apply 未知参数：$1" ;;
        esac
    done
    ovpn_validate_name "$template_name" || ovpn_die "模板名称格式无效：$template_name"
    ovpn_require_root
    ovpn_require_initialized
    ovpn_audit_file M "$OVPN_SERVER_CONF"
    ovpn_audit_file M "$OVPN_AUTH_VERIFY_SCRIPT"
    ovpn_audit_file M "$OVPN_DROPIN"
    ovpn_audit_command systemctl daemon-reload
    ovpn_audit_command systemctl enable --now "$OVPN_SERVICE"
    if [[ "$OVPN_DRY_RUN" == 1 ]]; then
        temporary="$(mktemp -d)"
        ovpn_register_temp "$temporary"
        ovpn_render_server "$temporary/server.conf" "$template_name" env_assignments extra_configs
        ovpn_safe_regular_file "$OVPN_RESOURCE_DIR/scripts/auth-verify.sh"
        install -m 0755 -- "$OVPN_RESOURCE_DIR/scripts/auth-verify.sh" "$temporary/auth-verify.sh"
        ovpn_safe_regular_file "$OVPN_STATE_DIR/pki/crl.pem"
        install -m 0644 -- "$OVPN_STATE_DIR/pki/crl.pem" "$temporary/crl.pem"
        ovpn_core_test_file "$temporary/server.conf" "$temporary/auth-verify.sh"
        rm -rf -- "$temporary"
        ovpn_print_audit "检查成功"
        return
    fi
    ovpn_info "获取应用锁"
    ovpn_lock
    ovpn_info "渲染并验证服务端配置"
    ovpn_apply_internal 0 "$template_name" env_assignments extra_configs 1
    ovpn_print_audit
}

ovpn_status() {
    (( $# == 0 )) || ovpn_die "status 不接受参数"
    printf '管理目录：%s\n' "$OVPN_STATE_DIR"
    ovpn_ca_summary
    printf '服务端证书过期时间：%s\n' "$(ovpn_cert_expiry "$OVPN_STATE_DIR/pki/issued/server.crt")"
    if systemctl is-active --quiet "$OVPN_SERVICE" 2>/dev/null; then printf '服务：运行中\n'; else printf '服务：未运行\n'; fi
    printf '服务端模板：%s\n' "$([[ -s "$OVPN_RESOURCE_DIR/config/server/default.conf.tpl" ]] && printf 存在 || printf 缺失)"
    printf '运行配置：%s\n' "$([[ -s "$OVPN_SERVER_CONF" ]] && printf 存在 || printf 缺失)"
    ovpn_network_summary
    ovpn_print_audit
}
