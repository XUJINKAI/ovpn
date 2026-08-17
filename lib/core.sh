#!/usr/bin/env bash
# OpenVPN 核心程序安装、控制和校验。

ovpn_core() {
    local command="${1:-}"
    shift || true
    case "$command" in
        install)
            (( $# == 0 )) || ovpn_die "core install 不接受参数"
            ovpn_require_root
            local -a packages=(openvpn easy-rsa openssl nftables acl util-linux)
            ovpn_audit_command apt-get install -y "${packages[@]}"
            [[ "$OVPN_DRY_RUN" != 1 ]] || { ovpn_print_audit "检查成功"; ovpn_dry_run_result; return; }
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
            ovpn_print_audit
            ovpn_result "OpenVPN 及运行依赖已安装完成。"
            ;;
        test)
            (( $# == 0 )) || ovpn_die "core test 不接受参数"
            ovpn_core_test
            ovpn_print_audit
            ;;
        start|restart)
            (( $# == 0 )) || ovpn_die "core $command 不接受参数"
            ovpn_require_root
            ovpn_core_test
            ovpn_audit_command systemctl "$command" "$OVPN_SERVICE"
            [[ "$OVPN_DRY_RUN" != 1 ]] || { ovpn_print_audit "检查成功"; ovpn_dry_run_result; return; }
            if ! systemctl "$command" "$OVPN_SERVICE"; then
                ovpn_audit_command systemctl stop "$OVPN_SERVICE"
                systemctl stop "$OVPN_SERVICE" >/dev/null 2>&1 || true
                printf '\nOpenVPN 最近日志：\n' >&2
                journalctl -u "$OVPN_SERVICE" -n 100 --no-pager >&2 || true
                ovpn_print_audit "失败"
                ovpn_die "OpenVPN $command 失败；已停止自动重试，请根据以上日志修正配置后重新运行 ovpn apply"
            fi
            ovpn_print_audit
            if [[ "$command" == start ]]; then
                ovpn_result "OpenVPN 服务已启动。"
            else
                ovpn_result "OpenVPN 服务已重启。"
            fi
            ;;
        stop)
            (( $# == 0 )) || ovpn_die "core stop 不接受参数"
            ovpn_require_root
            ovpn_audit_command systemctl stop "$OVPN_SERVICE"
            [[ "$OVPN_DRY_RUN" != 1 ]] || { ovpn_print_audit "检查成功"; ovpn_dry_run_result; return; }
            systemctl stop "$OVPN_SERVICE"
            ovpn_print_audit
            ovpn_result "OpenVPN 服务已停止。"
            ;;
        logs)
            local follow=0
            while (( $# > 0 )); do
                case "$1" in
                    -f) follow=1 ;;
                    *) ovpn_die "用法：ovpn core logs [-f]" ;;
                esac
                shift
            done
            local -a journal_args=(-u "$OVPN_SERVICE" -n 100 --no-pager)
            (( follow == 0 )) || journal_args+=(-f)
            ovpn_audit_command journalctl "${journal_args[@]}"
            [[ "$OVPN_DRY_RUN" != 1 ]] || { ovpn_print_audit "检查成功"; ovpn_dry_run_result; return; }
            if (( follow == 1 )); then
                ovpn_print_audit
                journalctl "${journal_args[@]}"
                return
            fi
            journalctl "${journal_args[@]}"
            ovpn_print_audit
            ;;
        *) ovpn_die "core 子命令可用：install、start、stop、restart、test、logs" ;;
    esac
}

ovpn_core_test_file() {
    local config="$1" auth_candidate="${2:-}" client_candidate="${3:-}" dispatcher_candidate="${4:-}" hooks_candidate="${5:-}"
    local name hook needs_dispatcher=0
    ovpn_require_command openvpn
    ovpn_safe_regular_file "$config"
    ovpn_audit_command test -s "$config"
    ovpn_audit_command grep -Eq '\{\{[A-Z0-9_]+\}\}' "$config"
    [[ -s "$config" ]] || ovpn_die "OpenVPN 配置为空：$config"
    if grep -Eq '\{\{[A-Z0-9_]+\}\}' "$config"; then
        ovpn_die "OpenVPN 配置仍包含未替换占位符：$config"
    fi
    if grep -Fq "auth-user-pass-verify $OVPN_AUTH_VERIFY_SCRIPT " "$config"; then
        needs_dispatcher=1
        ovpn_audit_command test -x "$OVPN_AUTH_VERIFY_SCRIPT"
        if [[ -n "$auth_candidate" ]]; then
            [[ -x "$auth_candidate" && ! -L "$auth_candidate" ]] ||
                ovpn_die "OpenVPN 认证脚本候选文件缺失、不可执行或是符号链接：$auth_candidate"
        elif [[ ! -x "$OVPN_AUTH_VERIFY_SCRIPT" || -L "$OVPN_AUTH_VERIFY_SCRIPT" ]]; then
            ovpn_die "OpenVPN 认证脚本缺失、不可执行或错误地安装为符号链接；请重新运行 ovpn apply"
        elif [[ "$(stat -c '%U:%G:%a' "$OVPN_AUTH_VERIFY_SCRIPT")" != root:root:755 ]]; then
            ovpn_die "OpenVPN 认证脚本权限错误；请重新运行 ovpn apply"
        fi
    fi
    if grep -Fq "client-connect $OVPN_CLIENT_EVENT_SCRIPT" "$config" ||
        grep -Fq "client-disconnect $OVPN_CLIENT_EVENT_SCRIPT" "$config"; then
        needs_dispatcher=1
        ovpn_audit_command test -x "$OVPN_CLIENT_EVENT_SCRIPT"
        hook="${client_candidate:-$OVPN_CLIENT_EVENT_SCRIPT}"
        [[ -x "$hook" && ! -L "$hook" ]] ||
            ovpn_die "OpenVPN 连接事件脚本缺失、不可执行或是符号链接：$hook"
        if [[ -z "$client_candidate" && "$(stat -c '%U:%G:%a' "$hook")" != root:root:755 ]]; then
            ovpn_die "OpenVPN 连接事件脚本权限错误；请重新运行 ovpn apply"
        fi
    fi
    if (( needs_dispatcher == 1 )); then
        hook="${dispatcher_candidate:-$OVPN_EVENT_DISPATCH_SCRIPT}"
        ovpn_audit_command test -x "$OVPN_EVENT_DISPATCH_SCRIPT"
        [[ -x "$hook" && ! -L "$hook" ]] || ovpn_die "OpenVPN 事件分发脚本缺失、不可执行或是符号链接：$hook"
        if [[ -z "$dispatcher_candidate" && "$(stat -c '%U:%G:%a' "$hook")" != root:root:755 ]]; then
            ovpn_die "OpenVPN 事件分发脚本权限错误；请重新运行 ovpn apply"
        fi
    fi
    hooks_candidate="${hooks_candidate:-$OVPN_RUNTIME_HOOK_DIR}"
    if (( needs_dispatcher == 1 )) && [[ "$hooks_candidate" == "$OVPN_RUNTIME_HOOK_DIR" ]]; then
        [[ -d "$hooks_candidate" && ! -L "$hooks_candidate" &&
            "$(stat -c '%U:%G:%a' "$hooks_candidate")" == root:nogroup:750 ]] ||
            ovpn_die "OpenVPN 运行回调目录缺失或权限错误；请重新运行 ovpn apply"
    fi
    for name in authentication-failed client-connected client-disconnected; do
        hook="$hooks_candidate/$name"
        [[ ! -e "$hook" && ! -L "$hook" ]] ||
            [[ -f "$hook" && ! -L "$hook" && -x "$hook" ]] ||
            ovpn_die "OpenVPN 运行回调不是安全的普通可执行文件：$hook"
        if [[ "$hooks_candidate" == "$OVPN_RUNTIME_HOOK_DIR" && -e "$hook" &&
            "$(stat -c '%U:%G:%a' "$hook")" != root:nogroup:750 ]]; then
            ovpn_die "OpenVPN 运行回调权限错误；请重新运行 ovpn apply：$hook"
        fi
    done
}

ovpn_core_test() {
    [[ -s "$OVPN_SERVER_CONF" ]] || ovpn_die "运行配置不存在，请先运行 ovpn apply"
    ovpn_core_test_file "$OVPN_SERVER_CONF"
    printf 'OpenVPN 配置静态检查通过；OpenVPN 2.6 不提供 TLS 配置的无副作用完整校验，启动或重启结果为最终验证。\n'
}
