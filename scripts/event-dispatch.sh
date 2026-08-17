#!/usr/bin/env bash
# 安全调用用户维护的 OpenVPN 事件回调；由受管 hook 调用。

set -Eeuo pipefail

readonly PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
readonly HOOK_DIR="/etc/openvpn/server/hooks"
readonly EVENT="${1:-}"

case "$EVENT" in
    authentication-failed|client-connected|client-disconnected) ;;
    *) exit 0 ;;
esac

hook="$HOOK_DIR/$EVENT"
[[ -f "$hook" && ! -L "$hook" && -x "$hook" ]] || exit 0

sanitize() {
    local value="${1:-}"
    value="${value//$'\n'/}"
    value="${value//$'\r'/}"
    printf '%s' "${value:0:512}"
}

common_name="$(sanitize "${OVPN_COMMON_NAME:-}")"
remote_ip="$(sanitize "${OVPN_REMOTE_IP:-}")"
remote_port="$(sanitize "${OVPN_REMOTE_PORT:-}")"
virtual_ip="$(sanitize "${OVPN_IFCONFIG_POOL_REMOTE_IP:-}")"
connected_at="$(sanitize "${OVPN_CONNECTED_AT:-}")"
duration="$(sanitize "${OVPN_DURATION_SECONDS:-}")"
bytes_received="$(sanitize "${OVPN_BYTES_RECEIVED:-}")"
bytes_sent="$(sanitize "${OVPN_BYTES_SENT:-}")"

if ! timeout --signal=TERM --kill-after=2s 10s env -i \
    PATH="$PATH" \
    OVPN_EVENT="$EVENT" \
    OVPN_COMMON_NAME="$common_name" \
    OVPN_REMOTE_IP="$remote_ip" \
    OVPN_REMOTE_PORT="$remote_port" \
    OVPN_IFCONFIG_POOL_REMOTE_IP="$virtual_ip" \
    OVPN_CONNECTED_AT="$connected_at" \
    OVPN_DURATION_SECONDS="$duration" \
    OVPN_BYTES_RECEIVED="$bytes_received" \
    OVPN_BYTES_SENT="$bytes_sent" \
    "$hook" "$EVENT"; then
    exit 0
fi

exit 0
