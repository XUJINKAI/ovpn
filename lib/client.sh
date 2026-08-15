#!/usr/bin/env bash
# 客户端身份、密码、吊销与模板导出。
# shellcheck disable=SC2034  # OVPN_WARN_UNUSED_TEMPLATE_VARS 与通过名称传递的 nameref 由被调用函数消费。

ovpn_auth_update() {
    local name="$1" value="${2:-}" auth="$OVPN_STATE_DIR/auth-db" temporary
    temporary="$(mktemp --tmpdir="$OVPN_STATE_DIR" .auth.XXXXXX)"
    ovpn_register_temp "$temporary"
    awk -F: -v name="$name" '$1 != name' "$auth" >"$temporary"
    [[ -z "$value" ]] || printf '%s:%s\n' "$name" "$value" >>"$temporary"
    install -o root -g nogroup -m 0640 -- "$temporary" "$auth"
    rm -f -- "$temporary"
}

ovpn_password_hash() {
    # 只从终端读取密码并返回 SHA-512 摘要，不写任何状态；无终端时在读取前报错。
    local no_passwd="$1" password hash
    if [[ "$no_passwd" == 1 ]]; then
        printf '%s\n' '!'
        return
    fi
    [[ -r /dev/tty ]] || ovpn_die "设置密码需要交互终端；使用 --no-passwd 跳过"
    read -r -s -p "客户端密码（留空表示不设置）：" password </dev/tty
    printf '\n' >&2
    if [[ -n "$password" ]]; then
        hash="$(printf '%s\n' "$password" | openssl passwd -6 -stdin)"
    else
        hash='!'
    fi
    unset password
    printf '%s\n' "$hash"
}

ovpn_password_update() {
    local name="$1" no_passwd="$2" hash
    hash="$(ovpn_password_hash "$no_passwd")"
    ovpn_auth_update "$name" "$hash"
    unset hash
}

ovpn_client_add() {
    local name="${1:-}" no_passwd=0 days=1095 hash
    shift || true
    while (( $# > 0 )); do
        case "$1" in
            --no-passwd) no_passwd=1; shift ;;
            --days) (( $# >= 2 )) || ovpn_die "--days 缺少天数"; days="$2"; shift 2 ;;
            *) ovpn_die "用法：ovpn add NAME [--no-passwd] [--days DAYS]" ;;
        esac
    done
    ovpn_validate_name "$name" || ovpn_die "客户端名称格式无效：$name"
    ovpn_validate_days "$days" || ovpn_die "--days 必须是 1 到 36500 的整数"
    ovpn_require_root
    ovpn_require_initialized
    [[ ! -e "$OVPN_STATE_DIR/clients/$name" ]] || ovpn_die "客户端已存在：$name"
    ovpn_audit_file A "$OVPN_STATE_DIR/clients/$name"
    [[ "$OVPN_DRY_RUN" != 1 ]] || { ovpn_print_audit "检查成功"; ovpn_dry_run_result; return; }
    hash="$(ovpn_password_hash "$no_passwd")"
    ovpn_lock
    ovpn_pki_sign_client "$name" "$days"
    ovpn_auth_update "$name" "$hash"
    unset hash
    ovpn_print_audit
    ovpn_result "客户端 $name 已创建完成。"
}

ovpn_client_passwd() {
    local name="${1:-}" no_passwd=0
    shift || true
    [[ "${1:-}" != --no-passwd ]] || { no_passwd=1; shift; }
    (( $# == 0 )) || ovpn_die "用法：ovpn passwd NAME [--no-passwd]"
    ovpn_validate_name "$name" || ovpn_die "客户端名称格式无效：$name"
    [[ -s "$OVPN_STATE_DIR/pki/issued/$name.crt" && -d "$OVPN_STATE_DIR/clients/$name" ]] || ovpn_die "客户端不存在：$name"
    ovpn_require_root
    ovpn_audit_file M "$OVPN_STATE_DIR/auth-db"
    [[ "$OVPN_DRY_RUN" != 1 ]] || { ovpn_print_audit "检查成功"; ovpn_dry_run_result; return; }
    ovpn_lock
    ovpn_password_update "$name" "$no_passwd"
    ovpn_print_audit
    if (( no_passwd == 1 )); then
        ovpn_result "客户端 $name 已设为仅证书认证。"
    else
        ovpn_result "客户端 $name 的口令认证设置已更新。"
    fi
}

ovpn_inline_block() {
    local tag="$1" file="$2"
    printf '<%s>\n' "$tag"
    cat -- "$file"
    printf '</%s>\n' "$tag"
}

ovpn_certificate_to_pem() {
    local source="$1" output="$2"
    openssl x509 -in "$source" -outform PEM -out "$output" ||
        ovpn_die "无法转换客户端证书为 PEM：$source"
}

ovpn_render_client() {
    local template="$1" output="$2" ca_block="$3" cert_block="$4" key_block="$5" tls_block="$6" auth_line="$7" configs_name="$8" line appended token count
    for token in CA_INLINE CLIENT_CERT_INLINE CLIENT_KEY_INLINE TLS_CRYPT_V2_CLIENT_INLINE AUTH_USER_PASS; do
        count="$(ovpn_template_token_count "$template" "$token")"
        if (( count == 0 )); then
            ovpn_warn "模板变量 {{$token}} 出现 0 次，本次值未被使用"
        elif (( count > 1 )); then
            ovpn_warn "模板变量 {{$token}} 出现 $count 次，将替换全部匹配位置"
        fi
    done
    appended="$output.appended"
    ovpn_render_append_config "$template" "$appended" "$configs_name" "客户端"
    : >"$output"
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            '{{CA_INLINE}}') cat -- "$ca_block" >>"$output" ;;
            '{{CLIENT_CERT_INLINE}}') cat -- "$cert_block" >>"$output" ;;
            '{{CLIENT_KEY_INLINE}}') cat -- "$key_block" >>"$output" ;;
            '{{TLS_CRYPT_V2_CLIENT_INLINE}}') cat -- "$tls_block" >>"$output" ;;
            '{{AUTH_USER_PASS}}') [[ -z "$auth_line" ]] || printf '%s\n' "$auth_line" >>"$output" ;;
            *) printf '%s\n' "$line" >>"$output" ;;
        esac
    done <"$appended"
    rm -f -- "$appended"
}

ovpn_client_export() {
    local name="${1:-}" template_name=default output="" force=0 user template client_dir temporary rendered auth_line="" assignment key
    local -a env_assignments=() extra_configs=()
    local -A env_values=()
    local OVPN_WARN_UNUSED_TEMPLATE_VARS=0
    shift || true
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
            --output) (( $# >= 2 )) || ovpn_die "--output 缺少路径"; output="$2"; shift 2 ;;
            --force) force=1; shift ;;
            *) ovpn_die "export 未知参数：$1" ;;
        esac
    done
    ovpn_validate_name "$name" || ovpn_die "客户端名称格式无效：$name"
    ovpn_validate_name "$template_name" || ovpn_die "模板名称格式无效：$template_name"
    ovpn_require_root
    ovpn_require_initialized
    client_dir="$OVPN_STATE_DIR/clients/$name"
    [[ -s "$OVPN_STATE_DIR/pki/issued/$name.crt" && -d "$client_dir" ]] || ovpn_die "客户端不存在：$name"
    template="$OVPN_RESOURCE_DIR/config/client/$template_name.conf.tpl"
    ovpn_safe_regular_file "$template"
    ovpn_load_env "$OVPN_RESOURCE_DIR/config/ovpn.env" env_values
    for assignment in "${env_assignments[@]}"; do
        key="${assignment%%=*}"
        env_values["$key"]="${assignment#*=}"
    done
    user="$(ovpn_invoking_user)"
    [[ -n "$output" ]] || output="$PWD/$name.ovpn"
    [[ "$output" == /* ]] || output="$PWD/$output"
    [[ ! -L "$output" ]] || ovpn_die "拒绝覆盖符号链接：$output"
    ovpn_audit_file A "$output"
    temporary="$(mktemp -d)"
    ovpn_register_temp "$temporary"
    # grep BRE 需要字面 $6$：单引号保留反斜杠，使 $ 不作为行尾锚点。
    # shellcheck disable=SC2016,SC2100
    grep -q "^${name}:"'\$6\$' "$OVPN_STATE_DIR/auth-db" && auth_line=auth-user-pass
    ovpn_inline_block ca "$OVPN_STATE_DIR/pki/ca-chain.crt" >"$temporary/ca"
    ovpn_certificate_to_pem "$OVPN_STATE_DIR/pki/issued/$name.crt" "$temporary/client.crt"
    ovpn_inline_block cert "$temporary/client.crt" >"$temporary/cert"
    ovpn_inline_block key "$OVPN_STATE_DIR/pki/private/$name.key" >"$temporary/key"
    ovpn_inline_block tls-crypt-v2 "$client_dir/tls-crypt-v2.key" >"$temporary/tls"
    rendered="$temporary/$name.ovpn"
    ovpn_render_client "$template" "$rendered" "$temporary/ca" "$temporary/cert" "$temporary/key" "$temporary/tls" "$auth_line" extra_configs
    ovpn_apply_env "$rendered" env_values
    if grep -Eq '\{\{[A-Z0-9_]+\}\}' "$rendered"; then
        ovpn_die "客户端模板包含未定义环境变量：$template"
    fi
    ovpn_core_test_file "$rendered"
    [[ "$OVPN_DRY_RUN" != 1 ]] || { rm -rf -- "$temporary"; ovpn_print_audit "检查成功"; ovpn_dry_run_result; return; }
    if [[ -e "$output" && $force == 0 ]] && ! cmp -s -- "$rendered" "$output"; then ovpn_die "目标已存在；使用 --force 覆盖：$output"; fi
    ovpn_atomic_install "$rendered" "$output" 0600 "$user" "$user"
    rm -rf -- "$temporary"
    ovpn_print_audit
    ovpn_result "客户端 $name 已导出到 $output（模板：$template_name）。"
}

ovpn_client_revoke() {
    local name="${1:-}"
    (( $# == 1 )) || ovpn_die "用法：ovpn revoke NAME"
    ovpn_validate_name "$name" || ovpn_die "客户端名称格式无效：$name"
    [[ -s "$OVPN_STATE_DIR/pki/issued/$name.crt" && -d "$OVPN_STATE_DIR/clients/$name" ]] || ovpn_die "客户端不存在：$name"
    ovpn_require_root
    ovpn_audit_file D "$OVPN_STATE_DIR/clients/$name"
    [[ "$OVPN_DRY_RUN" != 1 ]] || { ovpn_print_audit "检查成功"; ovpn_dry_run_result; return; }
    ovpn_lock
    ovpn_pki_revoke_client "$name"
    ovpn_auth_update "$name"
    rm -rf -- "$OVPN_STATE_DIR/clients/$name"
    ovpn_apply_internal 1
    ovpn_print_audit
    ovpn_result "客户端 $name 已吊销，CRL 和运行配置已更新。"
}

ovpn_client_ls() {
    (( $# == 0 )) || ovpn_die "ls 不接受参数"
    local dir name password expiry
    printf '%-24s %-6s %-8s %s\n' NAME CERT PASSWORD EXPIRES
    [[ -d "$OVPN_STATE_DIR/clients" ]] || { ovpn_print_audit; return; }
    while IFS= read -r -d '' dir; do
        name="$(basename -- "$dir")"
        if ! ovpn_validate_name "$name" || [[ -L "$dir" ]]; then printf '%-24s %s\n' "$name" 异常; continue; fi
        password=否
        # grep BRE 需要字面 $6$：单引号保留反斜杠，使 $ 不作为行尾锚点。
        # shellcheck disable=SC2016,SC2100
        grep -q "^${name}:"'\$6\$' "$OVPN_STATE_DIR/auth-db" 2>/dev/null && password=是
        expiry="$(ovpn_cert_expiry "$OVPN_STATE_DIR/pki/issued/$name.crt")"
        printf '%-24s %-6s %-8s %s\n' "$name" "$([[ -s "$OVPN_STATE_DIR/pki/issued/$name.crt" ]] && printf 有效 || printf 异常)" "$password" "$expiry"
    done < <(find "$OVPN_STATE_DIR/clients" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    ovpn_print_audit
}
