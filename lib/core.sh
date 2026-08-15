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
    local config="$1" hook_candidate="${2:-}"
    ovpn_require_command openvpn
    ovpn_safe_regular_file "$config"
    ovpn_audit_command test -s "$config"
    ovpn_audit_command grep -Eq '\{\{[A-Z0-9_]+\}\}' "$config"
    [[ -s "$config" ]] || ovpn_die "OpenVPN 配置为空：$config"
    if grep -Eq '\{\{[A-Z0-9_]+\}\}' "$config"; then
        ovpn_die "OpenVPN 配置仍包含未替换占位符：$config"
    fi
    if grep -Fq "auth-user-pass-verify $OVPN_AUTH_VERIFY_SCRIPT " "$config"; then
        ovpn_audit_command test -x "$OVPN_AUTH_VERIFY_SCRIPT"
        if [[ -n "$hook_candidate" ]]; then
            [[ -x "$hook_candidate" && ! -L "$hook_candidate" ]] ||
                ovpn_die "OpenVPN 认证脚本候选文件缺失、不可执行或是符号链接：$hook_candidate"
        elif [[ ! -x "$OVPN_AUTH_VERIFY_SCRIPT" || -L "$OVPN_AUTH_VERIFY_SCRIPT" ]]; then
            ovpn_die "OpenVPN 认证脚本缺失、不可执行或错误地安装为符号链接；请重新运行 ovpn apply"
        fi
    fi
}

ovpn_core_test() {
    [[ -s "$OVPN_SERVER_CONF" ]] || ovpn_die "运行配置不存在，请先运行 ovpn apply"
    ovpn_core_test_file "$OVPN_SERVER_CONF"
    printf 'OpenVPN 配置静态检查通过；OpenVPN 2.6 不提供 TLS 配置的无副作用完整校验，启动或重启结果为最终验证。\n'
}
