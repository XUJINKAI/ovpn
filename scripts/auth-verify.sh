#!/usr/bin/env bash
# ovpn 的用户名密码认证钩子；由 OpenVPN 调用，不供用户直接执行。

set -uo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

CREDENTIAL_FILE="${1:-}"
AUTH_DB="${OVPN_AUTH_DB:-/etc/openvpn/ovpn/auth-db}"

[[ -f "$AUTH_DB" && ! -L "$AUTH_DB" ]] || exit 1
[[ "${common_name:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || exit 1

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
)" || exit 1

# cert-only 必须由认证数据库显式授权；无记录和未知状态都拒绝。
if [[ "$stored_value" == '!' ]]; then
    exit 0
fi

[[ "$stored_value" == '$6$'* ]] || exit 1
[[ -f "$CREDENTIAL_FILE" && ! -L "$CREDENTIAL_FILE" ]] || exit 1
IFS= read -r user_name <"$CREDENTIAL_FILE" || exit 1
IFS= read -r password < <(sed -n '2p' "$CREDENTIAL_FILE") || exit 1

[[ "$user_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || exit 1
[[ -n "$password" ]] || exit 1
[[ "$common_name" == "$user_name" ]] || exit 1

salt="${stored_value#'$6$'}"
salt="${salt%%'$'*}"
[[ "$salt" =~ ^[./A-Za-z0-9]{1,16}$ ]] || exit 1

calculated_hash="$(
    printf '%s\n' "$password" |
        openssl passwd -6 -stdin -salt "$salt" 2>/dev/null
)"
unset password

[[ "$calculated_hash" == "$stored_value" ]] || exit 1
exit 0
