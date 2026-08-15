#!/usr/bin/env bash
# OpenVPN 客户端网络转发和 NAT 的显式管理。

ovpn_netmask_prefix() {
    local mask="$1" octet prefix=0 seen_zero=0 octet_bits
    IFS=. read -r -a octets <<<"$mask"
    (( ${#octets[@]} == 4 )) || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] && (( 10#$octet <= 255 )) || return 1
        case "10#$octet" in
            10#255) octet_bits=8 ;; 10#254) octet_bits=7 ;; 10#252) octet_bits=6 ;; 10#248) octet_bits=5 ;;
            10#240) octet_bits=4 ;; 10#224) octet_bits=3 ;; 10#192) octet_bits=2 ;; 10#128) octet_bits=1 ;;
            10#0) octet_bits=0 ;; *) return 1 ;;
        esac
        (( seen_zero == 0 || octet_bits == 0 )) || return 1
        (( octet_bits == 8 )) || seen_zero=1
        (( prefix += octet_bits ))
    done
    printf '%s\n' "$prefix"
}

ovpn_network_summary() {
    local effective="未知" configured="禁用" nat="禁用" nat_runtime="未运行" current_cidr="无法解析" installed_cidr="无"
    [[ ! -r /proc/sys/net/ipv4/ip_forward ]] || effective="$(< /proc/sys/net/ipv4/ip_forward)"
    [[ ! -f "$OVPN_SYSCTL_FILE" ]] || configured="启用"
    if [[ -f "$OVPN_NAT_RULES" ]]; then
        nat="已配置"
        installed_cidr="$(sed -nE 's/^[[:space:]]*ip saddr ([^ ]+) masquerade$/\1/p' "$OVPN_NAT_RULES" | head -n 1)"
        [[ -n "$installed_cidr" ]] || installed_cidr="无法识别"
    fi
    systemctl is-active --quiet "$OVPN_NAT_SERVICE" 2>/dev/null && nat_runtime="运行中"
    if [[ -s "$OVPN_RESOURCE_DIR/config/server/default.conf.tpl" && -s "$OVPN_RESOURCE_DIR/config/ovpn.env" ]]; then
        current_cidr="$(ovpn_current_server_cidr 2>/dev/null || printf '无法解析')"
    fi
    printf 'IPv4 转发：配置%s，当前值 %s\n' "$configured" "$effective"
    printf '客户端 NAT：%s，服务%s，已安装网段 %s，当前配置网段 %s\n' "$nat" "$nat_runtime" "$installed_cidr" "$current_cidr"
    if [[ "$nat" == 已配置 && "$installed_cidr" != "$current_cidr" ]]; then
        printf '客户端 NAT：配置漂移，请重新运行 ovpn network nat_client enable\n'
    fi
}

ovpn_server_ipv4_cidr() {
    local config="$1" line address mask prefix octet
    local -a matches=()
    local -a address_octets=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        read -r -a fields <<<"$line"
        [[ "${fields[0]:-}" == server ]] || continue
        (( ${#fields[@]} == 3 )) || ovpn_die "server 指令必须使用：server IPv4 NETMASK"
        matches+=("${fields[1]} ${fields[2]}")
    done <"$config"
    (( ${#matches[@]} == 1 )) || ovpn_die "NAT 要求配置中恰好存在一个标准 IPv4 server 指令"
    read -r address mask <<<"${matches[0]}"
    [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || ovpn_die "server IPv4 地址无效：$address"
    IFS=. read -r -a address_octets <<<"$address"
    for octet in "${address_octets[@]}"; do (( 10#$octet <= 255 )) || ovpn_die "server IPv4 地址无效：$address"; done
    prefix="$(ovpn_netmask_prefix "$mask")" || ovpn_die "server IPv4 掩码无效：$mask"
    printf '%s/%s\n' "$address" "$prefix"
}

ovpn_current_server_cidr() {
    local temporary
    temporary="$(mktemp)"
    ovpn_register_temp "$temporary"
    ovpn_render_server "$temporary"
    ovpn_server_ipv4_cidr "$temporary"
    rm -f -- "$temporary"
}

ovpn_validate_network_resources() {
    ovpn_safe_regular_file "$OVPN_RESOURCE_DIR/network/sysctl.conf"
    grep -Eq '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1[[:space:]]*$' "$OVPN_RESOURCE_DIR/network/sysctl.conf" ||
        ovpn_die "IPv4 转发资源缺少 net.ipv4.ip_forward = 1：$OVPN_RESOURCE_DIR/network/sysctl.conf"
}

ovpn_render_nat_rules() {
    local cidr="$1" output="$2"
    ovpn_safe_regular_file "$OVPN_RESOURCE_DIR/network/nat-client.nft.tpl"
    ovpn_safe_regular_file "$OVPN_RESOURCE_DIR/systemd/ovpn-nat.service"
    cp -- "$OVPN_RESOURCE_DIR/network/nat-client.nft.tpl" "$output"
    sed -i "s|{{VPN_CIDR}}|$cidr|g" "$output"
    if grep -Fq '{{' "$output"; then
        ovpn_die "NAT 模板包含未知或未替换占位符：$OVPN_RESOURCE_DIR/network/nat-client.nft.tpl"
    fi
}

ovpn_network_ipv4_forward() {
    local action="$1" temporary had_old=0 effective="无法读取"
    ovpn_require_root
    ovpn_require_command sysctl
    case "$action" in
        enable)
            ovpn_validate_network_resources
            ovpn_audit_file A "$OVPN_SYSCTL_FILE"
            ovpn_audit_command sysctl --system
            if [[ "$OVPN_DRY_RUN" != 1 ]]; then
                temporary="$(mktemp -d)"
                ovpn_register_temp "$temporary"
                [[ ! -e "$OVPN_SYSCTL_FILE" ]] || { cp -a -- "$OVPN_SYSCTL_FILE" "$temporary/old-sysctl"; had_old=1; }
                install -o root -g root -m 0644 -- "$OVPN_RESOURCE_DIR/network/sysctl.conf" "$OVPN_SYSCTL_FILE"
                if ! sysctl --system >/dev/null; then
                    rm -f -- "$OVPN_SYSCTL_FILE"
                    (( had_old == 0 )) || cp -a -- "$temporary/old-sysctl" "$OVPN_SYSCTL_FILE"
                    sysctl --system >/dev/null 2>&1 || true
                    ovpn_die "IPv4 转发启用失败；原 sysctl 配置已恢复"
                fi
            fi
            ;;
        disable)
            ovpn_audit_file D "$OVPN_SYSCTL_FILE"
            ovpn_audit_command sysctl --system
            if [[ "$OVPN_DRY_RUN" != 1 ]]; then
                temporary="$(mktemp -d)"
                ovpn_register_temp "$temporary"
                [[ ! -e "$OVPN_SYSCTL_FILE" ]] || { cp -a -- "$OVPN_SYSCTL_FILE" "$temporary/old-sysctl"; had_old=1; }
                rm -f -- "$OVPN_SYSCTL_FILE"
                if ! sysctl --system >/dev/null; then
                    (( had_old == 0 )) || cp -a -- "$temporary/old-sysctl" "$OVPN_SYSCTL_FILE"
                    sysctl --system >/dev/null 2>&1 || true
                    ovpn_die "IPv4 转发禁用失败；原 sysctl 配置已恢复"
                fi
            fi
            ;;
        *) ovpn_die "用法：ovpn network ipv4_forward enable|disable" ;;
    esac
    ovpn_print_audit
    if [[ "$OVPN_DRY_RUN" == 1 ]]; then
        ovpn_dry_run_result
        return
    fi
    [[ ! -r /proc/sys/net/ipv4/ip_forward ]] || effective="$(< /proc/sys/net/ipv4/ip_forward)"
    if [[ "$action" == enable ]]; then
        ovpn_result "已开启 IPv4 转发；cat /proc/sys/net/ipv4/ip_forward 输出：$effective"
    else
        ovpn_result "已移除 ovpn 的 IPv4 转发配置；cat /proc/sys/net/ipv4/ip_forward 输出：$effective"
    fi
}

ovpn_network_nat_client() {
    local action="$1" cidr temporary was_enabled=0 was_active=0
    ovpn_require_root
    case "$action" in
        enable)
            ovpn_require_initialized
            cidr="$(ovpn_current_server_cidr)"
            temporary="$(mktemp -d)"
            ovpn_register_temp "$temporary"
            ovpn_render_nat_rules "$cidr" "$temporary/ovpn-nat.nft"
            ovpn_audit_file A "$OVPN_NAT_RULES"
            ovpn_audit_file A "$OVPN_NAT_UNIT"
            ovpn_audit_command systemctl enable "$OVPN_NAT_SERVICE"
            ovpn_audit_command systemctl restart "$OVPN_NAT_SERVICE"
            if [[ "$OVPN_DRY_RUN" != 1 ]]; then
                ovpn_require_command nft
                nft -c -f "$temporary/ovpn-nat.nft"
                [[ ! -e "$OVPN_NAT_RULES" ]] || cp -a -- "$OVPN_NAT_RULES" "$temporary/old-rules"
                [[ ! -e "$OVPN_NAT_UNIT" ]] || cp -a -- "$OVPN_NAT_UNIT" "$temporary/old-unit"
                systemctl is-enabled --quiet "$OVPN_NAT_SERVICE" 2>/dev/null && was_enabled=1
                systemctl is-active --quiet "$OVPN_NAT_SERVICE" 2>/dev/null && was_active=1
                install -d -o root -g root -m 0755 -- "$OVPN_SERVER_DIR"
                install -o root -g root -m 0644 -- "$temporary/ovpn-nat.nft" "$OVPN_NAT_RULES"
                install -o root -g root -m 0644 -- "$OVPN_RESOURCE_DIR/systemd/ovpn-nat.service" "$OVPN_NAT_UNIT"
                systemctl daemon-reload
                if ! systemctl enable "$OVPN_NAT_SERVICE" || ! systemctl restart "$OVPN_NAT_SERVICE"; then
                    systemctl disable --now "$OVPN_NAT_SERVICE" >/dev/null 2>&1 || true
                    nft delete table inet ovpn_nat_client >/dev/null 2>&1 || true
                    rm -f -- "$OVPN_NAT_RULES" "$OVPN_NAT_UNIT"
                    [[ ! -e "$temporary/old-rules" ]] || cp -a -- "$temporary/old-rules" "$OVPN_NAT_RULES"
                    [[ ! -e "$temporary/old-unit" ]] || cp -a -- "$temporary/old-unit" "$OVPN_NAT_UNIT"
                    systemctl daemon-reload
                    if (( was_enabled == 1 )); then
                        systemctl enable "$OVPN_NAT_SERVICE" >/dev/null 2>&1 || true
                    fi
                    (( was_active == 0 )) || systemctl restart "$OVPN_NAT_SERVICE" >/dev/null 2>&1 || true
                    ovpn_die "客户端 NAT 启用失败；规则文件和 unit 已恢复，请检查 journalctl -u $OVPN_NAT_SERVICE"
                fi
                rm -rf -- "$temporary"
            fi
            ;;
        disable)
            ovpn_audit_command systemctl disable --now "$OVPN_NAT_SERVICE"
            ovpn_audit_file D "$OVPN_NAT_RULES"
            ovpn_audit_file D "$OVPN_NAT_UNIT"
            if [[ "$OVPN_DRY_RUN" != 1 ]]; then
                if [[ -e "$OVPN_NAT_UNIT" ]] && ! systemctl disable --now "$OVPN_NAT_SERVICE"; then
                    ovpn_die "客户端 NAT 服务停止失败；未删除规则文件和 unit，请检查 journalctl -u $OVPN_NAT_SERVICE"
                fi
                if ovpn_have nft; then nft delete table inet ovpn_nat_client >/dev/null 2>&1 || true; fi
                rm -f -- "$OVPN_NAT_RULES" "$OVPN_NAT_UNIT"
                systemctl daemon-reload
            fi
            ;;
        *) ovpn_die "用法：ovpn network nat_client enable|disable" ;;
    esac
    ovpn_print_audit
    if [[ "$OVPN_DRY_RUN" == 1 ]]; then
        ovpn_dry_run_result
    elif [[ "$action" == enable ]]; then
        ovpn_result "已启用客户端 NAT，VPN 网段为 $cidr。"
    else
        ovpn_result "已禁用客户端 NAT。"
    fi
}

ovpn_network() {
    local feature="${1:-}" action="${2:-}"
    (( $# == 2 )) || ovpn_die "用法：ovpn network ipv4_forward|nat_client enable|disable"
    case "$feature" in
        ipv4_forward) ovpn_network_ipv4_forward "$action" ;;
        nat_client) ovpn_network_nat_client "$action" ;;
        *) ovpn_die "network 功能可用：ipv4_forward、nat_client" ;;
    esac
}
