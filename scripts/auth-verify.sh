#!/usr/bin/env bash
# ovpn 的用户名密码认证钩子；由 OpenVPN 调用，不供用户直接执行。

set -Eeuo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

CREDENTIAL_FILE="${1:-}"
AUTH_DB="${OVPN_AUTH_DB:-/etc/openvpn/ovpn/auth-db}"
readonly DISPATCHER="/etc/openvpn/server/event-dispatch.sh"

reject() {
    export OVPN_COMMON_NAME="${common_name:-}"
    export OVPN_REMOTE_IP="${untrusted_ip:-${untrusted_ip6:-}}"
    export OVPN_REMOTE_PORT="${untrusted_port:-}"
    export OVPN_IFCONFIG_POOL_REMOTE_IP=""
    export OVPN_CONNECTED_AT=""
    export OVPN_DURATION_SECONDS=""
    export OVPN_BYTES_RECEIVED=""
    export OVPN_BYTES_SENT=""
    if [[ -x "$DISPATCHER" && ! -L "$DISPATCHER" ]]; then
        if ! "$DISPATCHER" authentication-failed; then
            printf 'OpenVPN 认证失败通知分发异常\n' >&2
        fi
    fi
    exit 1
}

[[ -f "$AUTH_DB" && ! -L "$AUTH_DB" ]] || reject
[[ "${common_name:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || reject

stored_value="$(
    awk -F: -v common_name="$common_name" '
        $1 == common_name {
            count++
            if (NF != 2) invalid = 1
            value = $2
        }
        END {
            if (count != 1 || invalid) exit 1
            print value
        }
    ' "$AUTH_DB"
)" || reject

# cert-only 必须由认证数据库显式授权；无记录和未知状态都拒绝。
if [[ "$stored_value" == '!' ]]; then
    exit 0
fi

[[ "$stored_value" == "\$6\$"* ]] || reject
[[ -f "$CREDENTIAL_FILE" && ! -L "$CREDENTIAL_FILE" ]] || reject
IFS= read -r user_name <"$CREDENTIAL_FILE" || reject
IFS= read -r password < <(sed -n '2p' "$CREDENTIAL_FILE") || reject

[[ "$user_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || reject
[[ -n "$password" ]] || reject
[[ "$common_name" == "$user_name" ]] || reject

salt="${stored_value#\$6\$}"
salt="${salt%%\$*}"
[[ "$salt" =~ ^[./A-Za-z0-9]{1,16}$ ]] || reject

if ! calculated_hash="$(printf '%s\n' "$password" | openssl passwd -6 -stdin -salt "$salt" 2>/dev/null)"; then
    unset password
    reject
fi
unset password

[[ "$calculated_hash" == "$stored_value" ]] || reject
exit 0
