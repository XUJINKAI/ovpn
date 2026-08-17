#!/usr/bin/env bash
# OpenVPN 客户端连接与断开事件适配器；由 OpenVPN 调用。

set -Eeuo pipefail

readonly DISPATCHER="/etc/openvpn/server/event-dispatch.sh"
readonly MODE="${1:-}"

case "$MODE" in
    connect) event=client-connected ;;
    disconnect) event=client-disconnected ;;
    *) exit 0 ;;
esac

export OVPN_COMMON_NAME="${common_name:-}"
export OVPN_REMOTE_IP="${trusted_ip:-${trusted_ip6:-}}"
export OVPN_REMOTE_PORT="${trusted_port:-}"
export OVPN_IFCONFIG_POOL_REMOTE_IP="${ifconfig_pool_remote_ip:-}"
export OVPN_CONNECTED_AT="${time_ascii:-}"
export OVPN_DURATION_SECONDS="${time_duration:-}"
export OVPN_BYTES_RECEIVED="${bytes_received:-}"
export OVPN_BYTES_SENT="${bytes_sent:-}"

if [[ -x "$DISPATCHER" && ! -L "$DISPATCHER" ]]; then
    if ! "$DISPATCHER" "$event"; then
        printf 'OpenVPN 连接事件通知分发异常：%s\n' "$event" >&2
    fi
fi
exit 0
