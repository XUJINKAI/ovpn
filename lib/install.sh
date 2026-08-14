#!/usr/bin/env bash
# ovpn 管理器安装与卸载。

ovpn_install() {
    local mode="" source target relative resource_target resource_dir config_user config_group
    while (( $# > 0 )); do
        case "$1" in
            --ln|--copy)
                [[ -z "$mode" ]] || ovpn_die "--ln 与 --copy 只能指定一个"
                mode="$1"
                ;;
            *) ovpn_die "install 未知参数：$1" ;;
        esac
        shift
    done
    [[ -n "$mode" ]] || ovpn_die "用法：ovpn install (--ln | --copy)"
    if [[ "$mode" == --ln && "$(readlink -f -- "$OVPN_SOURCE_LIB_DIR")" == "$OVPN_LIB_INSTALL_DIR" ]]; then
        ovpn_die "--ln 必须从源码目录的 ovpn.sh 执行"
    fi
    ovpn_require_root
    ovpn_audit_file A "$OVPN_INSTALL_PATH"
    ovpn_audit_file A "$OVPN_LIB_INSTALL_DIR"
    ovpn_audit_file A "$OVPN_STATE_DIR/config"
    ovpn_audit_file A "$OVPN_STATE_DIR/scripts"
    ovpn_audit_file A "$OVPN_STATE_DIR/network"
    ovpn_audit_file A "$OVPN_STATE_DIR/systemd"
    [[ "$OVPN_DRY_RUN" != 1 ]] || { ovpn_print_audit "检查成功"; return; }

    config_user="$(ovpn_invoking_user)"
    config_group="$(id -gn "$config_user")"

    if [[ "$mode" == --ln ]]; then
        ln -sfn -- "$OVPN_ENTRYPOINT" "$OVPN_INSTALL_PATH"
        rm -rf -- "$OVPN_LIB_INSTALL_DIR"
        install -d -o root -g root -m 0755 -- "$OVPN_LIB_INSTALL_DIR"
        for source in "$OVPN_SOURCE_LIB_DIR"/*.sh; do
            target="$OVPN_LIB_INSTALL_DIR/$(basename -- "$source")"
            ln -s -- "$source" "$target"
        done
    else
        if [[ "$(readlink -f -- "$OVPN_SOURCE_LIB_DIR")" == "$OVPN_LIB_INSTALL_DIR" ]]; then
            chmod 0755 -- "$OVPN_INSTALL_PATH" "$OVPN_LIB_INSTALL_DIR"/*.sh
        else
            rm -rf -- "$OVPN_LIB_INSTALL_DIR"
            install -d -o root -g root -m 0755 -- "$OVPN_LIB_INSTALL_DIR"
            install -o root -g root -m 0755 -- "$OVPN_ENTRYPOINT" "$OVPN_INSTALL_PATH"
            for source in "$OVPN_SOURCE_LIB_DIR"/*.sh; do
                target="$OVPN_LIB_INSTALL_DIR/$(basename -- "$source")"
                install -o root -g root -m 0755 -- "$source" "$target"
            done
        fi
    fi
    install -d -o root -g root -m 0755 -- "$OVPN_STATE_DIR"
    install -d -o "$config_user" -g "$config_group" -m 0700 -- "$OVPN_STATE_DIR/config"
    chown -R -- "$config_user:$config_group" "$OVPN_STATE_DIR/config"
    find "$OVPN_STATE_DIR/config" -type d -exec chmod 0700 -- {} +
    find "$OVPN_STATE_DIR/config" -type f -exec chmod 0600 -- {} +
    while IFS= read -r -d '' source; do
        relative="${source#"$OVPN_SOURCE_RESOURCE_DIR/config/"}"
        resource_target="$OVPN_STATE_DIR/config/$relative"
        if [[ -d "$source" ]]; then
            install -d -o "$config_user" -g "$config_group" -m 0700 -- "$resource_target"
        elif [[ ! -e "$resource_target" ]]; then
            install -o "$config_user" -g "$config_group" -m 0600 -- "$source" "$resource_target"
        fi
    done < <(find "$OVPN_SOURCE_RESOURCE_DIR/config" -mindepth 1 -print0)
    for resource_dir in scripts network systemd; do
        install -d -o root -g root -m 0755 -- "$OVPN_STATE_DIR/$resource_dir"
        while IFS= read -r -d '' source; do
            relative="${source#"$OVPN_SOURCE_RESOURCE_DIR/$resource_dir/"}"
            resource_target="$OVPN_STATE_DIR/$resource_dir/$relative"
            if [[ -d "$source" ]]; then
                install -d -o root -g root -m 0755 -- "$resource_target"
            elif [[ ! -e "$resource_target" ]]; then
                install -o root -g root -m 0644 -- "$source" "$resource_target"
            fi
        done < <(find "$OVPN_SOURCE_RESOURCE_DIR/$resource_dir" -mindepth 1 -print0)
    done
    chmod 0755 -- "$OVPN_STATE_DIR/scripts/auth-verify.sh"
    ovpn_print_audit
    printf '管理器安装完成。下一步：sudo ovpn core install\n'
}

ovpn_uninstall() {
    local purge=0 no_backup=0 backup_dir="" timestamp
    while (( $# > 0 )); do
        case "$1" in
            --purge) purge=1 ;;
            --no-backup) no_backup=1 ;;
            *) ovpn_die "uninstall 未知参数：$1" ;;
        esac
        shift
    done
    (( no_backup == 0 || purge == 1 )) || ovpn_die "--no-backup 只能与 --purge 同用"
    ovpn_require_root
    ovpn_audit_command systemctl disable --now "$OVPN_SERVICE"
    ovpn_audit_command systemctl disable --now "$OVPN_NAT_SERVICE"
    ovpn_audit_file D "$OVPN_INSTALL_PATH"
    ovpn_audit_file D "$OVPN_LIB_INSTALL_DIR"
    ovpn_audit_file D "$OVPN_SERVER_CONF"
    ovpn_audit_file D "$OVPN_RUNTIME_CA"
    ovpn_audit_file D "$OVPN_RUNTIME_SERVER_CERT"
    ovpn_audit_file D "$OVPN_RUNTIME_SERVER_KEY"
    ovpn_audit_file D "$OVPN_RUNTIME_CRL"
    ovpn_audit_file D "$OVPN_RUNTIME_TLS_CRYPT_V2"
    ovpn_audit_file D "$OVPN_AUTH_VERIFY_SCRIPT"
    ovpn_audit_file D "$OVPN_DROPIN"
    ovpn_audit_file D "$OVPN_SYSCTL_FILE"
    ovpn_audit_file D "$OVPN_NAT_UNIT"
    ovpn_audit_file D "$OVPN_NAT_RULES"
    if (( purge == 1 )); then
        ovpn_audit_file D "$OVPN_STATE_DIR"
        (( no_backup == 1 )) || ovpn_audit_file A "$OVPN_PURGE_BACKUP_ROOT/purge-<时间>"
    fi
    [[ "$OVPN_DRY_RUN" != 1 ]] || { ovpn_print_audit "检查成功"; return; }

    if (( purge == 1 )); then
        ovpn_confirm PURGE "警告：这会删除 CA、私钥、客户端状态和用户模板。"
        if (( no_backup == 0 && -e "$OVPN_STATE_DIR" )); then
            timestamp="$(date +%Y%m%d-%H%M%S)"
            backup_dir="$OVPN_PURGE_BACKUP_ROOT/purge-$timestamp"
            install -d -o root -g root -m 0700 -- "$backup_dir"
            cp -a -- "$OVPN_STATE_DIR" "$backup_dir/ovpn"
            ovpn_cleanup_backups "$OVPN_PURGE_BACKUP_ROOT"
        fi
    fi
    systemctl disable --now "$OVPN_SERVICE" >/dev/null 2>&1 || true
    systemctl disable --now "$OVPN_NAT_SERVICE" >/dev/null 2>&1 || true
    rm -f -- "$OVPN_SERVER_CONF" "$OVPN_RUNTIME_CA" "$OVPN_RUNTIME_SERVER_CERT" "$OVPN_RUNTIME_SERVER_KEY" "$OVPN_RUNTIME_CRL" "$OVPN_RUNTIME_TLS_CRYPT_V2" "$OVPN_AUTH_VERIFY_SCRIPT" "$OVPN_NAT_RULES" "$OVPN_DROPIN" "$OVPN_SYSCTL_FILE" "$OVPN_NAT_UNIT"
    rmdir --ignore-fail-on-non-empty -- "$(dirname -- "$OVPN_AUTH_VERIFY_SCRIPT")" "$(dirname -- "$OVPN_DROPIN")" "$OVPN_SERVER_DIR" 2>/dev/null || true
    systemctl daemon-reload
    (( purge == 0 )) || rm -rf -- "$OVPN_STATE_DIR"
    rm -f -- "$OVPN_INSTALL_PATH"
    rm -rf -- "$OVPN_LIB_INSTALL_DIR"
    ovpn_print_audit
    [[ -z "$backup_dir" ]] || printf '恢复副本：%s\n' "$backup_dir"
}
