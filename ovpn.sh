#!/usr/bin/env bash
# ovpn - Debian 13 OpenVPN Community 管理器。

set -Eeuo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

OVPN_ENTRYPOINT="$(readlink -f -- "$0")"
OVPN_SOURCE_DIR="$(dirname -- "$OVPN_ENTRYPOINT")"
if [[ "$OVPN_ENTRYPOINT" == "/usr/local/bin/ovpn" ]]; then
    OVPN_LIB_DIR="/usr/local/lib/ovpn"
    OVPN_SOURCE_LIB_DIR="$OVPN_LIB_DIR"
    OVPN_SOURCE_RESOURCE_DIR="/etc/openvpn/ovpn"
else
    OVPN_LIB_DIR="$OVPN_SOURCE_DIR/lib"
    OVPN_SOURCE_LIB_DIR="$OVPN_LIB_DIR"
    OVPN_SOURCE_RESOURCE_DIR="$OVPN_SOURCE_DIR"
fi
OVPN_RESOURCE_DIR="${OVPN_STATE_DIR:-/etc/openvpn/ovpn}"

for module in common install core pki server client network; do
    [[ -r "$OVPN_LIB_DIR/$module.sh" ]] || { printf '错误：缺少模块：%s\n' "$OVPN_LIB_DIR/$module.sh" >&2; exit 1; }
    # shellcheck disable=SC1090
    source "$OVPN_LIB_DIR/$module.sh"
done

trap ovpn_cleanup_temporaries EXIT

ovpn_short_help() {
    cat <<'EOF'
ovpn - OpenVPN Community 管理器

安装与维护：
  ovpn install (--ln | --copy)
  ovpn core install|start|stop|restart|test
  ovpn core logs [-f]
  ovpn uninstall [--purge] [--no-backup]

服务端：
  ovpn ca init [--force] [--days DAYS]
  ovpn edit env|server[:NAME]|client[:NAME]
  ovpn apply [--template NAME] [--env KEY=VALUE]... [--add-config LINE]...
  ovpn status

网络：
  ovpn network ipv4_forward enable|disable
  ovpn network nat_client enable|disable

客户端：
  ovpn add NAME [--no-passwd] [--days DAYS]
  ovpn passwd NAME [--no-passwd]
  ovpn revoke NAME
  ovpn ls
  ovpn export NAME [--template NAME] [--env KEY=VALUE]... [--add-config LINE]... [--output FILE] [--force]

全局参数：
  --dir DIR    管理目录，默认 /etc/openvpn/ovpn
  --dry-run    验证并显示计划，不修改系统
  --no-audit   不显示操作列表

运行 ovpn help 查看详细说明。
EOF
}

ovpn_full_help() {
    ovpn_short_help
    cat <<'EOF'

install 只安装管理器；core install 使用 apt 安装 OpenVPN 和运行依赖，不执行 apt update。
除帮助外的命令会在需要时自动使用 sudo 重新执行，不需要手写 sudo。
install 总是按目录布局复制源码中缺失的配置、脚本、网络和systemd资源，不受 --ln 或 --copy 影响。
ca init 使用 Easy-RSA 创建本地 CA 和服务端凭据，CA 与服务端证书默认有效 3650 天，可用 --days 同时调整；已有 CA 时拒绝操作，--force 会先备份并替换 CA、客户端及密码状态。
edit 原样打开公共环境文件或指定模板，server 和 client 省略模板名时使用 default；命令不校验、不应用配置，默认使用 vi，可通过 OVPN_EDITOR 指定其他单个编辑器命令。
apply 默认使用 config/server/default.conf.tpl，可用 --template 选择其他模板；--env 覆盖变量，--add-config 在 {{APPEND_CONFIG}} 位置插入配置行，两个参数均可重复。
apply 校验候选配置、部署运行文件并启用和启动服务；命令行覆盖只影响本次生成的运行配置，不修改模板或 ovpn.env。
core test 只静态检查当前运行配置；OpenVPN 2.6 没有 TLS 配置的无副作用完整校验，start 和 restart 是最终验证。
core logs 显示服务端实例最近 100 行 journal，-f 持续显示新日志；start 或 restart 失败时会自动显示这些日志并停止自动重试。
network ipv4_forward 只管理 /etc/sysctl.d/99-ovpn.conf；disable 不强制写入 0，以免覆盖其他转发配置。
network nat_client 从服务端 server 指令推导 IPv4 源网段，并通过 ovpn-nat.service 管理 ovpn 独占的 nftables 表。
两个网络开关彼此独立；disable 只删除 ovpn 拥有的配置，出现连接问题时可分别 disable 回滚。
add 只签发身份，客户端证书默认有效 1095 天，可用 --days 调整；export 默认使用 config/client/default.conf.tpl，可用 --template 选择其他模板。
export 从 config/ovpn.env 读取模板变量；--env 覆盖单个变量，--add-config 在模板的 {{APPEND_CONFIG}} 位置按顺序插入配置行，两个参数均可重复；未提供时删除该占位符。
export 默认写入当前目录的 ./NAME.ovpn；已存在的不同文件需要 --force 才能覆盖。
uninstall 保留管理目录；--purge 要求输入 PURGE，默认先备份到 /var/backups/ovpn。
EOF
}

ovpn_parse_global() {
    OVPN_ARGS=()
    while (( $# > 0 )); do
        case "$1" in
            --dry-run) OVPN_DRY_RUN=1; shift ;;
            --no-audit) OVPN_NO_AUDIT=1; shift ;;
            --dir) (( $# >= 2 )) || ovpn_die "--dir 缺少路径"; OVPN_STATE_DIR="$2"; shift 2 ;;
            *) OVPN_ARGS+=("$1"); shift ;;
        esac
    done
    ovpn_validate_state_dir
}

main() {
    local -a original_args=("$@")
    ovpn_parse_global "$@"
    OVPN_RESOURCE_DIR="$OVPN_STATE_DIR"
    set -- "${OVPN_ARGS[@]}"
    local command="${1:-}"
    [[ -n "$command" ]] || { ovpn_short_help; return; }
    shift
    case "$command" in
        -h|--help|help|install|uninstall|core|edit|apply|network|status|s|ca|add|passwd|revoke|ls|export) ;;
        *) ovpn_die "未知命令：$command；运行 ovpn help 查看帮助" ;;
    esac
    case "$command" in
        -h|--help|help|edit) ;;
        *)
            if (( EUID != 0 )) && [[ "${OVPN_NO_AUTO_SUDO:-0}" != 1 ]]; then
                ovpn_have sudo || ovpn_die "此命令需要 root 权限，但系统未安装 sudo"
                exec sudo -- "$OVPN_ENTRYPOINT" "${original_args[@]}"
            fi
            ;;
    esac
    case "$command" in
        -h|--help) (( $# == 0 )) || ovpn_die "$command 不接受参数"; ovpn_short_help ;;
        help) (( $# == 0 )) || ovpn_die "help 不接受参数"; ovpn_full_help ;;
        install) ovpn_install "$@" ;;
        uninstall) ovpn_uninstall "$@" ;;
        core) ovpn_core "$@" ;;
        edit) ovpn_edit "$@" ;;
        apply) ovpn_apply "$@" ;;
        network) ovpn_network "$@" ;;
        status|s) ovpn_status "$@" ;;
        ca) [[ "${1:-}" == init ]] || ovpn_die "用法：ovpn ca init [--force] [--days DAYS]"; shift; ovpn_ca_init "$@" ;;
        add) ovpn_client_add "$@" ;;
        passwd) ovpn_client_passwd "$@" ;;
        revoke) ovpn_client_revoke "$@" ;;
        ls) ovpn_client_ls "$@" ;;
        export) ovpn_client_export "$@" ;;
        *) ovpn_die "未知命令：$command；运行 ovpn help 查看帮助" ;;
    esac
}

main "$@"
