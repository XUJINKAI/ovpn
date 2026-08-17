#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_DIR
OVPN="$PROJECT_DIR/ovpn.sh"
readonly OVPN
export OVPN_NO_AUTO_SUDO=1

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "缺少文本：$2"; }
assert_fails() { if "$@" >/dev/null 2>&1; then fail "命令应失败：$*"; fi; }

output="$($OVPN --help)"
assert_contains "$output" 'ovpn core install|start|stop|restart|test'
assert_contains "$output" 'ovpn core logs [-f]'
assert_contains "$output" 'ovpn ca init [--force] [--days DAYS]'
assert_contains "$output" 'ovpn edit env|server[:NAME]|client[:NAME]'
assert_contains "$output" 'ovpn apply [--template NAME]'
assert_contains "$output" 'ovpn add NAME [--no-passwd] [--days DAYS]'
assert_contains "$output" 'ovpn revoke NAME'
assert_contains "$output" 'ovpn export NAME [--template NAME]'
assert_contains "$output" 'ovpn network ipv4_forward enable|disable'
assert_contains "$output" 'ovpn network nat_client enable|disable'
assert_contains "$output" '[--env KEY=VALUE]... [--add-config LINE]...'
[[ "$output" != *'ovpn client '* ]] || fail "仍包含旧 client 命令组"
[[ "$output" != *'ovpn server '* ]] || fail "仍包含 server 命令组"
[[ "$output" != *'ovpn cert regenerate'* ]] || fail "仍包含旧 cert regenerate 命令"
[[ "$output" != *'ovpn remove '* ]] || fail "仍包含旧 remove 命令"
[[ "$output" != *'--no-auth'* ]] || fail "仍包含旧 --no-auth 参数"
[[ "$output" != *'--cert-only'* ]] || fail "仍包含旧 --cert-only 参数"

output="$($OVPN --dry-run install --copy)"
assert_contains "$output" '模式：dry-run'
assert_contains "$output" '/usr/local/lib/ovpn'
assert_contains "$output" 'dry-run 检查完成，未执行系统变更。'
[[ "$output" != *$'\033['* ]] || fail "非终端结果不应包含 ANSI 颜色"
[[ -x "$PROJECT_DIR/scripts/auth-verify.sh" ]] || fail "OpenVPN 认证脚本缺失或不可执行"
[[ -x "$PROJECT_DIR/scripts/client-event.sh" && -x "$PROJECT_DIR/scripts/event-dispatch.sh" ]] || fail "OpenVPN 事件脚本缺失或不可执行"
for hook_name in authentication-failed client-connected client-disconnected; do
    [[ -x "$PROJECT_DIR/config/hooks/$hook_name" ]] || fail "事件回调示例缺失或不可执行：$hook_name"
    for variable in OVPN_EVENT OVPN_COMMON_NAME OVPN_REMOTE_IP OVPN_REMOTE_PORT OVPN_IFCONFIG_POOL_REMOTE_IP \
        OVPN_CONNECTED_AT OVPN_DURATION_SECONDS OVPN_BYTES_RECEIVED OVPN_BYTES_SENT; do
        assert_contains "$(<"$PROJECT_DIR/config/hooks/$hook_name")" "$variable"
    done
done
[[ -s "$PROJECT_DIR/network/nat-client.nft.tpl" && -s "$PROJECT_DIR/network/sysctl.conf" ]] || fail "网络资源布局不完整"
[[ -s "$PROJECT_DIR/systemd/ovpn-nat.service" && -s "$PROJECT_DIR/systemd/ovpn.conf" ]] || fail "systemd 资源布局不完整"
[[ ! -e "$PROJECT_DIR/config/scripts" && ! -e "$PROJECT_DIR/config/network" && ! -e "$PROJECT_DIR/config/systemd.conf" ]] || fail "旧资源布局仍然存在"
[[ ! -e "$PROJECT_DIR/lib/auth-verify.sh" ]] || fail "OpenVPN 认证脚本不应位于 lib"
[[ "$(<"$PROJECT_DIR/lib/install.sh")" != *'(( no_backup == 0 && -e'* ]] || fail "uninstall 备份条件把文件测试写进了算术表达式"

output="$($OVPN --dry-run core install)"
assert_contains "$output" 'apt-get install -y openvpn'
assert_contains "$output" 'easy-rsa'
[[ "$output" != *'apt-get update'* ]] || fail "core install 不得运行 apt update"

output="$($OVPN --dry-run core logs -f)"
assert_contains "$output" 'journalctl'
assert_contains "$output" '-f'

test_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_dir"' EXIT
event_hooks="$test_dir/event-hooks"
event_log="$test_dir/event.log"
mkdir -p "$event_hooks"
sed "s|/etc/openvpn/server/hooks|$event_hooks|" "$PROJECT_DIR/scripts/event-dispatch.sh" >"$test_dir/event-dispatch.sh"
sed "s|/etc/openvpn/server/event-dispatch.sh|$test_dir/event-dispatch.sh|" "$PROJECT_DIR/scripts/auth-verify.sh" >"$test_dir/auth-verify.sh"
sed "s|/etc/openvpn/server/event-dispatch.sh|$test_dir/event-dispatch.sh|" "$PROJECT_DIR/scripts/client-event.sh" >"$test_dir/client-event.sh"
chmod 0755 "$test_dir/event-dispatch.sh" "$test_dir/auth-verify.sh" "$test_dir/client-event.sh"
printf '#!/usr/bin/env bash\nenv | sort >%q\nprintf "ARG=%%s\\n" "$1" >>%q\n' "$event_log" "$event_log" >"$event_hooks/authentication-failed"
chmod 0755 "$event_hooks/authentication-failed"
env OVPN_COMMON_NAME=client1 OVPN_REMOTE_IP=203.0.113.10 OVPN_REMOTE_PORT=54321 OVPN_SECRET=must-not-leak \
    "$test_dir/event-dispatch.sh" authentication-failed
assert_contains "$(<"$event_log")" 'OVPN_EVENT=authentication-failed'
assert_contains "$(<"$event_log")" 'OVPN_REMOTE_IP=203.0.113.10'
assert_contains "$(<"$event_log")" 'ARG=authentication-failed'
[[ "$(<"$event_log")" != *must-not-leak* ]] || fail "事件分发器泄漏了非白名单环境变量"

printf 'client1\nunused\n' >"$test_dir/credentials"
: >"$test_dir/auth-db"
auth_hook="$test_dir/auth-verify.sh"
assert_fails env common_name=client1 OVPN_AUTH_DB="$test_dir/auth-db" "$auth_hook" "$test_dir/credentials"
printf 'client1:!\n' >"$test_dir/auth-db"
output="$(common_name=client1 OVPN_AUTH_DB="$test_dir/auth-db" "$auth_hook" "$test_dir/missing-credentials" 2>&1)"
[[ -z "$output" ]] || fail "认证钩子不应输出日志：$output"
printf 'client1:!\nclient1:!\n' >"$test_dir/auth-db"
assert_fails env common_name=client1 OVPN_AUTH_DB="$test_dir/auth-db" "$auth_hook" "$test_dir/credentials"
printf 'client1:unknown\n' >"$test_dir/auth-db"
assert_fails env common_name=client1 OVPN_AUTH_DB="$test_dir/auth-db" "$auth_hook" "$test_dir/credentials"
# 写入认证数据库的字面 $6$ 前缀。
# shellcheck disable=SC2016
printf 'client1:$6$invalid-salt!$hash\n' >"$test_dir/auth-db"
assert_fails env common_name=client1 OVPN_AUTH_DB="$test_dir/auth-db" "$auth_hook" "$test_dir/credentials"
hash="$(printf '%s\n' secret | openssl passwd -6 -stdin)"
printf 'client1:%s\n' "$hash" >"$test_dir/auth-db"
printf 'client1\nsecret\n' >"$test_dir/credentials"
env common_name=client1 OVPN_AUTH_DB="$test_dir/auth-db" "$auth_hook" "$test_dir/credentials"
printf 'client2\nsecret\n' >"$test_dir/credentials"
assert_fails env common_name=client1 OVPN_AUTH_DB="$test_dir/auth-db" "$auth_hook" "$test_dir/credentials"
printf 'client1\nwrong\n' >"$test_dir/credentials"
assert_fails env common_name=client1 untrusted_ip=198.51.100.20 untrusted_port=45678 OVPN_AUTH_DB="$test_dir/auth-db" \
    "$auth_hook" "$test_dir/credentials"
assert_contains "$(<"$event_log")" 'OVPN_REMOTE_IP=198.51.100.20'
assert_contains "$(<"$event_log")" 'OVPN_REMOTE_PORT=45678'
assert_fails env common_name=invalid/name OVPN_AUTH_DB="$test_dir/auth-db" "$auth_hook" "$test_dir/credentials"
unset hash

cp -- "$event_hooks/authentication-failed" "$event_hooks/client-connected"
env script_type=client-connect common_name=client1 trusted_ip=192.0.2.30 trusted_port=1194 ifconfig_pool_remote_ip=10.8.0.2 \
    "$test_dir/client-event.sh" "$test_dir/client-config"
assert_contains "$(<"$event_log")" 'OVPN_EVENT=client-connected'
assert_contains "$(<"$event_log")" 'OVPN_REMOTE_IP=192.0.2.30'
assert_contains "$(<"$event_log")" 'OVPN_IFCONFIG_POOL_REMOTE_IP=10.8.0.2'

auth_state="$test_dir/auth-state"
mkdir -p "$auth_state"
# 写入认证数据库的字面 $6$ 前缀。
# shellcheck disable=SC2016
printf 'client1:$6$old$hash\nclient1:$6$duplicate$hash\n' >"$auth_state/auth-db"
export INSTALL_LOG="$test_dir/auth-install.log"
# 嵌套 bash -c 字符串内 printf 的 \n，shellcheck 无法解析嵌套引号。
# shellcheck disable=SC1012
bash -Eeuo pipefail -c '
    source "$1/lib/common.sh"
    source "$1/lib/client.sh"
    OVPN_STATE_DIR="$2"
    install() {
        local prev="" arg mode="" source target
        for arg in "$@"; do
            [[ "$prev" == -m ]] && mode="$arg"
            prev="$arg"
        done
        source="${@: -2:1}"; target="${@: -1}"
        printf '%s\n' "$*" >>"$INSTALL_LOG"
        cp -- "$source" "$target"
        chmod "$mode" -- "$target"
    }
    ovpn_auth_update client1 "!"
' _ "$PROJECT_DIR" "$auth_state"
[[ "$(<"$auth_state/auth-db")" == 'client1:!' ]] || fail "cert-only 状态未写为显式记录"
[[ "$(stat -c '%a' "$auth_state/auth-db")" == 640 ]] || fail "认证数据库权限错误"
[[ "$(<"$INSTALL_LOG")" == *'-o root -g nogroup -m 0640'* ]] || fail "认证数据库属主应为 root:nogroup 0640"
bash -Eeuo pipefail -c '
    source "$1/lib/common.sh"
    source "$1/lib/client.sh"
    OVPN_STATE_DIR="$2"
    install() {
        local prev="" arg mode="" source target
        for arg in "$@"; do
            [[ "$prev" == -m ]] && mode="$arg"
            prev="$arg"
        done
        source="${@: -2:1}"; target="${@: -1}"
        cp -- "$source" "$target"
        chmod "$mode" -- "$target"
    }
    ovpn_auth_update client1
' _ "$PROJECT_DIR" "$auth_state"
[[ ! -s "$auth_state/auth-db" ]] || fail "撤销身份时未删除认证记录"
unset INSTALL_LOG

mock_easyrsa="$test_dir/easyrsa"
cat >"$mock_easyrsa" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'pki=%s batch=%s ca_days=%s cert_days=%s command=%s\n' "$EASYRSA_PKI" "${EASYRSA_BATCH:-}" "${EASYRSA_CA_EXPIRE:-}" "${EASYRSA_CERT_EXPIRE:-}" "$*" >>"$MOCK_LOG"
case "$1" in
    init-pki) mkdir -p "$EASYRSA_PKI/private" "$EASYRSA_PKI/issued" "$EASYRSA_PKI/reqs"; : >"$EASYRSA_PKI/index.txt" ;;
    build-ca) printf ca >"$EASYRSA_PKI/ca.crt"; printf key >"$EASYRSA_PKI/private/ca.key" ;;
    gen-crl) printf crl >"$EASYRSA_PKI/crl.pem" ;;
    build-server-full) printf server >"$EASYRSA_PKI/issued/server.crt"; printf key >"$EASYRSA_PKI/private/server.key" ;;
    build-client-full) printf client >"$EASYRSA_PKI/issued/$2.crt"; printf key >"$EASYRSA_PKI/private/$2.key" ;;
    renew) printf renewed >"$EASYRSA_PKI/issued/server.crt" ;;
    revoke-renewed) : ;;
esac
EOF
chmod 0755 "$mock_easyrsa"
mock_state="$test_dir/mock-state"
MOCK_LOG="$test_dir/easyrsa.log" OVPN_EASYRSA="$mock_easyrsa" OVPN_STATE_DIR="$mock_state" bash -Eeuo pipefail -c '
    export MOCK_LOG
    source "$1/lib/pki.sh"
    ovpn_pki_init 4000
    ovpn_pki_sign_server 4000
    EASYRSA_CERT_EXPIRE=1200 ovpn_easyrsa build-client-full client1 nopass
    ovpn_pki_sign_server
    install() { mkdir -p -- "${@: -1}"; }
    openvpn() { printf key >"${@: -1}"; }
    ovpn_pki_sign_client client2
' _ "$PROJECT_DIR"
assert_contains "$(<"$test_dir/easyrsa.log")" 'command=init-pki'
assert_contains "$(<"$test_dir/easyrsa.log")" 'ca_days=4000 cert_days= command=build-ca nopass'
assert_contains "$(<"$test_dir/easyrsa.log")" 'ca_days= cert_days=4000 command=build-server-full server nopass'
assert_contains "$(<"$test_dir/easyrsa.log")" 'ca_days= cert_days=1200 command=build-client-full client1 nopass'
assert_contains "$(<"$test_dir/easyrsa.log")" 'ca_days= cert_days=3650 command=build-server-full server nopass'
assert_contains "$(<"$test_dir/easyrsa.log")" 'ca_days= cert_days=1095 command=build-client-full client2 nopass'
[[ "$(<"$mock_state/pki/issued/server-chain.crt")" == server ]] || fail "Easy-RSA 服务端证书链未生成"

printf 'test config\n' >"$test_dir/core-test.conf"
output="$(bash -Eeuo pipefail -c '
    source "$1/lib/common.sh"
    source "$1/lib/core.sh"
    openvpn() { return 0; }
    ovpn_core_test_file "$2"
' _ "$PROJECT_DIR" "$test_dir/core-test.conf" 2>&1)"
[[ -z "$output" ]] || fail "静态配置检查产生意外输出：$output"
printf 'ca {{CA_CERT}}\n' >"$test_dir/core-test.conf"
# 嵌套 bash -c 的位置参数 $1/$2。
# shellcheck disable=SC2016
assert_fails bash -Eeuo pipefail -c '
    source "$1/lib/common.sh"
    source "$1/lib/core.sh"
    openvpn() { return 0; }
    ovpn_core_test_file "$2"
' _ "$PROJECT_DIR" "$test_dir/core-test.conf"
output="$($OVPN --dir "$test_dir/state" --dry-run ca init)"
assert_contains "$output" "$test_dir/state"
[[ "$output" != *'systemctl'* && "$output" != *'/etc/openvpn/server/server.conf'* ]] || fail "ca init dry-run 不应部署配置或操作服务"
[[ ! -e "$test_dir/state" ]] || fail "init dry-run 写入了文件"

assert_fails "$OVPN" --dry-run install
assert_fails "$OVPN" --dry-run edit
assert_fails "$OVPN" --dry-run edit invalid
assert_fails env OVPN_EDITOR='vi -f' "$OVPN" --dir "$test_dir/editor-state" --dry-run edit env
assert_fails "$OVPN" --dir relative status
assert_fails "$OVPN" server status
assert_fails "$OVPN" server show-conf
assert_fails "$OVPN" client ls
assert_fails "$OVPN" cert regenerate
assert_fails "$OVPN" remove client1
assert_fails "$OVPN" --dry-run add client1 --no-auth
assert_fails "$OVPN" --dry-run add client1 --cert-only
assert_fails "$OVPN" --dry-run init
assert_fails "$OVPN" --dry-run ca init --generated
assert_fails "$OVPN" --dry-run ca init --cert cert.pem
assert_fails "$OVPN" --dry-run ca init --chain chain.pem
assert_fails "$OVPN" --dry-run ca init --days 0
assert_fails "$OVPN" --dry-run ca init --days invalid
assert_fails "$OVPN" --dry-run ca reset
assert_fails "$OVPN" --dry-run network ipv4_forward
assert_fails "$OVPN" --dry-run network nat_client maybe
assert_fails "$OVPN" --dir "$test_dir/state" --dry-run ca init --force

mkdir -p "$test_dir/existing/pki/private" "$test_dir/existing/pki/issued" "$test_dir/existing/pki/reqs" "$test_dir/existing/clients"
printf cert >"$test_dir/existing/pki/ca.crt"
printf cert >"$test_dir/existing/pki/ca-chain.crt"
printf key >"$test_dir/existing/pki/private/ca.key"
: >"$test_dir/existing/pki/index.txt"
: >"$test_dir/existing/auth-db"
output="$($OVPN --dir "$test_dir/existing" --dry-run ca init --force)"
assert_contains "$output" 'ca-init-<时间>'
assert_contains "$output" "$test_dir/existing/clients"

mkdir -p "$test_dir/legacy/pki"
printf legacy >"$test_dir/legacy/pki/unknown-old-state"
output="$($OVPN --dir "$test_dir/legacy" --dry-run ca init --force)"
assert_contains "$output" 'ca-init-<时间>'
[[ "$output" != *'尚未初始化'* && "$output" != *'状态不完整'* ]] || fail "--force 错误校验了旧版 PKI 布局"

editor_state="$test_dir/editor-state"
mkdir -p "$editor_state/config/server" "$editor_state/config/client"
printf 'SERVER_PORT=1194\n' >"$editor_state/config/ovpn.env"
printf 'server template\n' >"$editor_state/config/server/default.conf.tpl"
printf 'client template\n' >"$editor_state/config/client/default.conf.tpl"
printf 'test client template\n' >"$editor_state/config/client/test.conf.tpl"
fake_editor="$test_dir/fake-editor"
# 写入 fake-editor 脚本正文的字面 $1。
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >>"$EDITOR_LOG"\n' >"$fake_editor"
chmod 0755 "$fake_editor"
output="$(OVPN_EDITOR="$fake_editor" "$OVPN" --dir "$editor_state" --dry-run edit server:default)"
assert_contains "$output" "$fake_editor $editor_state/config/server/default.conf.tpl"
output="$(OVPN_EDITOR="$fake_editor" "$OVPN" --dir "$editor_state" --dry-run edit server)"
assert_contains "$output" "$fake_editor $editor_state/config/server/default.conf.tpl"
output="$(OVPN_EDITOR="$fake_editor" "$OVPN" --dir "$editor_state" --dry-run edit client)"
assert_contains "$output" "$fake_editor $editor_state/config/client/default.conf.tpl"
output="$(OVPN_EDITOR="$fake_editor" "$OVPN" --dir "$editor_state" --dry-run edit client:test)"
assert_contains "$output" "$fake_editor $editor_state/config/client/test.conf.tpl"
[[ ! -e "$test_dir/editor.log" ]] || fail "edit dry-run 启动了编辑器"
output="$(EDITOR_LOG="$test_dir/editor.log" OVPN_EDITOR="$fake_editor" "$OVPN" --dir "$editor_state" --no-audit edit env)"
[[ "$(<"$test_dir/editor.log")" == "$editor_state/config/ovpn.env" ]] || fail "edit env 没有打开环境文件"
[[ -z "$output" ]] || fail "edit --no-audit 产生意外输出：$output"
[[ "$output" != *'审计：'* && "$output" != *'执行审计：'* ]] || fail "--no-audit 仍显示审计摘要"
assert_fails "$OVPN" --dir "$editor_state" --dry-run edit server:missing
assert_fails "$OVPN" --dir "$editor_state" --dry-run edit 'client:../default'

assert_contains "$(<"$PROJECT_DIR/config/ovpn.env")" 'CLIENT_PROTO=udp4'
assert_contains "$(<"$PROJECT_DIR/config/ovpn.env")" 'SERVER_PROTO=udp4'
assert_contains "$(<"$PROJECT_DIR/config/ovpn.env")" 'DATA_CIPHERS=AES-256-GCM:AES-128-GCM'
assert_contains "$(<"$PROJECT_DIR/config/client/default.conf.tpl")" 'dev {{CLIENT_DEV}}'
assert_contains "$(<"$PROJECT_DIR/config/client/default.conf.tpl")" 'auth {{AUTH_DIGEST}}'
assert_contains "$(<"$PROJECT_DIR/config/server/default.conf.tpl")" 'keepalive {{KEEPALIVE}}'

env_file="$test_dir/ovpn.env"
rendered="$test_dir/client.conf.tpl"
printf 'ENDPOINT=vpn.example.com\nCLIENT_PORT=49999\n' >"$env_file"
printf 'remote {{ENDPOINT}} {{CLIENT_PORT}}\n' >"$rendered"
bash -Eeuo pipefail -c '
    source "$1/lib/common.sh"
    source "$1/lib/client.sh"
    declare -A values=()
    ovpn_load_env "$2" values
    values[CLIENT_PORT]=50000
    ovpn_apply_env "$3" values
' _ "$PROJECT_DIR" "$env_file" "$rendered"
assert_contains "$(<"$rendered")" 'remote vpn.example.com 50000'
[[ "$(<"$rendered")" != *'{{ENDPOINT}}'* ]] || fail "endpoint 环境变量未替换"
printf 'verb {{TEST}}\nmute {{TEST}}\n' >"$rendered"
output="$(bash -Eeuo pipefail -c '
    source "$1/lib/common.sh"
    declare -A values=([TEST]=1)
    ovpn_apply_env "$2" values
' _ "$PROJECT_DIR" "$rendered" 2>&1)"
assert_contains "$output" '模板变量 {{TEST}} 出现 2 次'
assert_contains "$(<"$rendered")" $'verb 1\nmute 1'
printf 'verb 1\n' >"$rendered"
output="$(bash -Eeuo pipefail -c '
    source "$1/lib/common.sh"
    declare -A values=([TEST]=1)
    ovpn_apply_env "$2" values
' _ "$PROJECT_DIR" "$rendered" 2>&1)"
assert_contains "$output" '模板变量 {{TEST}} 出现 0 次'
printf 'v {{WEIRD}}\n' >"$rendered"
bash -Eeuo pipefail -c '
    source "$1/lib/common.sh"
    declare -A values=([WEIRD]="C:\\Users\\bob&x|y/etc")
    ovpn_apply_env "$2" values
' _ "$PROJECT_DIR" "$rendered"
assert_contains "$(<"$rendered")" 'v C:\Users\bob&x|y/etc'
printf 'ca {{CA_CERT}}\n' >"$rendered"
bash -Eeuo pipefail -c '
    source "$1/lib/common.sh"
    ovpn_template_replace "$2" "$3" CA_CERT "/etc/openvpn/server/ca.crt"
' _ "$PROJECT_DIR" "$rendered" "$test_dir/paths.conf"
assert_contains "$(<"$test_dir/paths.conf")" 'ca /etc/openvpn/server/ca.crt'
[[ "$(<"$test_dir/paths.conf")" != *'{{'* ]] || fail "路径占位符未替换"

client_template="$test_dir/client-template.conf.tpl"
printf 'auth-user-pass\n{{APPEND_CONFIG}}\n# comments\n{{CA_INLINE}}\n{{CLIENT_CERT_INLINE}}\n{{CLIENT_KEY_INLINE}}\n{{TLS_CRYPT_V2_CLIENT_INLINE}}\n' >"$client_template"
for block in ca cert key tls; do printf '%s-block\n' "$block" >"$test_dir/$block"; done
bash -Eeuo pipefail -c '
    source "$1/lib/common.sh"
    source "$1/lib/client.sh"
    configs=("route-nopull" "verb 4")
    ovpn_render_client "$2" "$3" "$4/ca" "$4/cert" "$4/key" "$4/tls" "" configs
' _ "$PROJECT_DIR" "$client_template" "$rendered" "$test_dir"
assert_contains "$(<"$rendered")" $'auth-user-pass\nroute-nopull\nverb 4\n# comments'
[[ "$(<"$rendered")" != *'{{APPEND_CONFIG}}'* ]] || fail "追加配置占位符未移除"
[[ "$(grep -n '^route-nopull$' "$rendered" | cut -d: -f1)" -lt "$(grep -n '^ca-block$' "$rendered" | cut -d: -f1)" ]] || fail "追加配置没有位于证书材料之前"

printf 'Certificate:\n    text prefix\n-----BEGIN CERTIFICATE-----\npayload\n-----END CERTIFICATE-----\n' >"$test_dir/easyrsa-client.crt"
bash -Eeuo pipefail -c '
    source "$1/lib/common.sh"
    source "$1/lib/client.sh"
    openssl() {
        [[ "$1" == x509 && "$2" == -in && "$4" == -outform && "$5" == PEM && "$6" == -out ]]
        sed -n "/^-----BEGIN CERTIFICATE-----$/,/^-----END CERTIFICATE-----$/p" "$3" >"$7"
    }
    ovpn_certificate_to_pem "$2" "$3"
' _ "$PROJECT_DIR" "$test_dir/easyrsa-client.crt" "$test_dir/client.pem"
[[ "$(<"$test_dir/client.pem")" == $'-----BEGIN CERTIFICATE-----\npayload\n-----END CERTIFICATE-----' ]] || fail "导出客户端证书仍包含 Easy-RSA 文字说明"

bash -Eeuo pipefail -c '
    source "$1/lib/common.sh"
    source "$1/lib/client.sh"
    configs=()
    ovpn_render_client "$2" "$3" "$4/ca" "$4/cert" "$4/key" "$4/tls" "" configs
' _ "$PROJECT_DIR" "$client_template" "$rendered" "$test_dir"
[[ "$(<"$rendered")" != *'{{APPEND_CONFIG}}'* ]] || fail "空追加配置没有移除占位符"
printf '{{CA_INLINE}}\n' >"$client_template"
output="$(bash -Eeuo pipefail -c '
    source "$1/lib/common.sh"
    source "$1/lib/client.sh"
    configs=("verb 4")
    ovpn_render_client "$2" "$3" "$4/ca" "$4/cert" "$4/key" "$4/tls" "" configs
' _ "$PROJECT_DIR" "$client_template" "$rendered" "$test_dir" 2>&1)"
assert_contains "$output" '模板变量 {{APPEND_CONFIG}} 出现 0 次'
assert_contains "$(<"$rendered")" $'ca-block\nverb 4'
printf '{{APPEND_CONFIG}}\n{{APPEND_CONFIG}}\n' >"$client_template"
output="$(bash -Eeuo pipefail -c '
    source "$1/lib/common.sh"
    source "$1/lib/client.sh"
    configs=("verb 4")
    ovpn_render_client "$2" "$3" "$4/ca" "$4/cert" "$4/key" "$4/tls" "" configs
' _ "$PROJECT_DIR" "$client_template" "$rendered" "$test_dir" 2>&1)"
assert_contains "$output" '模板变量 {{APPEND_CONFIG}} 出现 2 次'
[[ "$(<"$rendered")" == 'verb 4' ]] || fail "多个追加配置占位符未按宽进规则处理"

server_state="$test_dir/server-state"
mkdir -p "$server_state/config/server" "$server_state/config/client" "$server_state/network" "$server_state/systemd" "$server_state/scripts"
cp -- "$PROJECT_DIR/config/client/default.conf.tpl" "$server_state/config/client/default.conf.tpl"
cp -- "$PROJECT_DIR/network/"* "$server_state/network/"
cp -- "$PROJECT_DIR/systemd/"* "$server_state/systemd/"
cp -- "$PROJECT_DIR/scripts/"* "$server_state/scripts/"
printf 'SERVER_PORT=49999\nSERVER=10.9.0.0 255.255.255.0\nENDPOINT=vpn.example.com\nCLIENT_PORT=49999\nCLIENT_PROTO=udp4\nCLIENT_DEV=tun\nCLIENT_VERB=3\nAUTH_DIGEST=SHA256\nDATA_CIPHERS=AES-256-GCM\nKEEPALIVE=10 120\nMAX_CLIENTS=100\n' >"$server_state/config/ovpn.env"
printf 'port {{SERVER_PORT}}\nserver {{SERVER}}\nca {{CA_CERT}}\ncert {{SERVER_CERT}}\nkey {{SERVER_KEY}}\ndh none\ncrl-verify {{CRL_FILE}}\ntls-crypt-v2 {{TLS_CRYPT_V2_SERVER_KEY}}\nauth-user-pass-verify {{AUTH_VERIFY_SCRIPT}} via-file\nsetenv OVPN_AUTH_DB {{AUTH_DB}}\n{{APPEND_CONFIG}}\n' >"$server_state/config/server/default.conf.tpl"
bash -Eeuo pipefail -c '
    source "$1/lib/common.sh"
    source "$1/lib/server.sh"
    OVPN_STATE_DIR="$2"
    OVPN_RESOURCE_DIR="$2"
    ovpn_render_server "$3"
' _ "$PROJECT_DIR" "$server_state" "$test_dir/server.conf"
assert_contains "$(<"$test_dir/server.conf")" 'port 49999'
assert_contains "$(<"$test_dir/server.conf")" 'server 10.9.0.0 255.255.255.0'
assert_contains "$(<"$test_dir/server.conf")" 'ca /etc/openvpn/server/ca.crt'
assert_contains "$(<"$test_dir/server.conf")" 'cert /etc/openvpn/server/server.crt'
assert_contains "$(<"$test_dir/server.conf")" 'key /etc/openvpn/server/server.key'
assert_contains "$(<"$test_dir/server.conf")" 'crl-verify /etc/openvpn/server/crl.pem'
assert_contains "$(<"$test_dir/server.conf")" 'tls-crypt-v2 /etc/openvpn/server/tls-crypt-v2.key'
assert_contains "$(<"$test_dir/server.conf")" 'auth-user-pass-verify /etc/openvpn/server/auth-verify.sh via-file'
assert_contains "$(<"$PROJECT_DIR/config/server/default.conf.tpl")" 'max-clients {{MAX_CLIENTS}}'
assert_contains "$(<"$PROJECT_DIR/config/server/default.conf.tpl")" 'client-connect {{CLIENT_EVENT_SCRIPT}}'
assert_fails bash -Eeuo pipefail -c '
    source "$1/lib/common.sh"
    source "$1/lib/server.sh"
    OVPN_STATE_DIR="$2"
    OVPN_RESOURCE_DIR="$2"
    assignments=("MAX_CLIENTS=0")
    ovpn_render_server "$3" default assignments
' _ "$PROJECT_DIR" "$server_state" "$test_dir/server-max-invalid.conf"
printf 'port {{SERVER_PORT}}\nserver {{SERVER}}\n{{APPEND_CONFIG}}\nca {{CA_CERT}}\ncert {{SERVER_CERT}}\nkey {{SERVER_KEY}}\ndh none\ncrl-verify {{CRL_FILE}}\ntls-crypt-v2 {{TLS_CRYPT_V2_SERVER_KEY}}\nauth-user-pass-verify {{AUTH_VERIFY_SCRIPT}} via-file\nsetenv OVPN_AUTH_DB {{AUTH_DB}}\n' >"$server_state/config/server/example.conf.tpl"
bash -Eeuo pipefail -c '
    source "$1/lib/common.sh"
    source "$1/lib/server.sh"
    OVPN_STATE_DIR="$2"
    OVPN_RESOURCE_DIR="$2"
    assignments=("SERVER_PORT=50000")
    configs=("client-to-client" "verb 4")
    ovpn_render_server "$3" example assignments configs
' _ "$PROJECT_DIR" "$server_state" "$test_dir/server-example.conf"
assert_contains "$(<"$test_dir/server-example.conf")" 'port 50000'
assert_contains "$(<"$test_dir/server-example.conf")" $'server 10.9.0.0 255.255.255.0\nclient-to-client\nverb 4\nca '
[[ "$(<"$test_dir/server-example.conf")" != *'{{APPEND_CONFIG}}'* ]] || fail "服务端追加配置占位符未移除"
output="$(bash -Eeuo pipefail -c '
    source "$1/lib/common.sh"
    source "$1/lib/server.sh"
    OVPN_STATE_DIR="$2"
    OVPN_RESOURCE_DIR="$2"
    sed -i "/APPEND_CONFIG/d" "$2/config/server/example.conf.tpl"
    ovpn_render_server "$3" example
' _ "$PROJECT_DIR" "$server_state" "$test_dir/server-invalid.conf" 2>&1)"
[[ "$output" != *'出现 0 次'* ]] || fail "服务端渲染不应警告未使用的模板变量：$output"
assert_contains "$(<"$PROJECT_DIR/config/server/default.conf.tpl")" 'script-security 2'
assert_contains "$(<"$PROJECT_DIR/config/server/default.conf.tpl")" 'auth-user-pass-optional'
[[ -s "$PROJECT_DIR/config/server/example.conf.tpl" && -s "$PROJECT_DIR/config/client/example.conf.tpl" ]] || fail "示例模板缺失"

cidr="$(bash -Eeuo pipefail -c 'source "$1/lib/common.sh"; source "$1/lib/network.sh"; ovpn_server_ipv4_cidr "$2"' _ "$PROJECT_DIR" "$test_dir/server.conf")"
[[ "$cidr" == 10.9.0.0/24 ]] || fail "server 网段解析错误：$cidr"
mkdir -p "$server_state/pki/private" "$server_state/pki/issued" "$server_state/pki/reqs"
printf cert >"$server_state/pki/ca.crt"
printf cert >"$server_state/pki/ca-chain.crt"
printf key >"$server_state/pki/private/ca.key"
: >"$server_state/pki/index.txt"
mkdir -p "$server_state/clients/client1"
printf key >"$server_state/clients/client1/tls-crypt-v2.key"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$server_state/pki/private/client1.key" -out "$server_state/pki/issued/client1.crt" -days 3650 -subj "/CN=client1" >/dev/null 2>&1
: >"$server_state/auth-db"
output="$($OVPN --dir "$server_state" ls)"
assert_contains "$output" 'EXPIRES'
assert_contains "$output" 'client1'
printf cert >"$test_dir/expiry.crt"
output="$(bash -Eeuo pipefail -c '
    source "$1/lib/common.sh"
    source "$1/lib/pki.sh"
    openssl() { printf "notAfter=Jan 01 00:00:00 2030 GMT\n"; }
    ovpn_cert_expiry "$2"
' _ "$PROJECT_DIR" "$test_dir/expiry.crt")"
[[ "$output" == 'Jan 01 00:00:00 2030 GMT' ]] || fail "证书过期时间解析错误：$output"
output="$(bash -Eeuo pipefail -c '
    source "$1/lib/common.sh"
    source "$1/lib/pki.sh"
    source "$1/lib/server.sh"
    OVPN_STATE_DIR="$2"
    OVPN_RESOURCE_DIR="$2"
    ovpn_ca_summary() { printf "CA 过期时间：Jan 01 00:00:00 2035 GMT\n"; }
    ovpn_cert_expiry() { printf "Jan 01 00:00:00 2035 GMT\n"; }
    systemctl() { return 1; }
    ovpn_network_summary() { :; }
    ovpn_status
' _ "$PROJECT_DIR" "$server_state")"
assert_contains "$output" 'CA 过期时间：Jan 01 00:00:00 2035 GMT'
assert_contains "$output" '服务端证书过期时间：Jan 01 00:00:00 2035 GMT'
output="$($OVPN --dir "$server_state" --dry-run add client2 --no-passwd --days 1200)"
assert_contains "$output" "$server_state/clients/client2"
assert_fails "$OVPN" --dir "$server_state" --dry-run add client2 --days 0
export OVPN_ORDER_LOG="$test_dir/order.log"
bash -Eeuo pipefail -c '
    source "$1/lib/common.sh"
    source "$1/lib/client.sh"
    OVPN_STATE_DIR="$2"
    ovpn_require_root() { :; }
    ovpn_require_initialized() { :; }
    ovpn_lock() { :; }
    ovpn_password_hash() { printf "HASH\n" >>"$OVPN_ORDER_LOG"; printf "!\n"; }
    ovpn_pki_sign_client() { printf "SIGNED\n" >>"$OVPN_ORDER_LOG"; }
    ovpn_auth_update() { printf "AUTH\n" >>"$OVPN_ORDER_LOG"; }
    ovpn_print_audit() { :; }
    ovpn_client_add clientorder
' _ "$PROJECT_DIR" "$test_dir/order-state" 2>&1
[[ "$(<"$OVPN_ORDER_LOG")" == $'HASH\nSIGNED\nAUTH' ]] || fail "密码摘要应先于证书签发与认证库写入：$(<"$OVPN_ORDER_LOG")"
rm -f -- "$OVPN_ORDER_LOG"
unset OVPN_ORDER_LOG
if [[ ! -r /dev/tty ]]; then
    output="$(bash -Eeuo pipefail -c '
        source "$1/lib/common.sh"
        source "$1/lib/client.sh"
        OVPN_STATE_DIR="$2"
        ovpn_require_root() { :; }
        ovpn_require_initialized() { :; }
        ovpn_lock() { :; }
        ovpn_pki_sign_client() { printf "SIGNED\n"; }
        ovpn_auth_update() { printf "AUTH\n"; }
        ovpn_print_audit() { :; }
        ovpn_client_add clienttty
    ' _ "$PROJECT_DIR" "$test_dir/tty-state" 2>&1)"
    assert_contains "$output" '交互终端'
    [[ "$output" != *SIGNED* ]] || fail "无终端时不应先签发证书"
    [[ "$output" != *AUTH* ]] || fail "无终端时不应写入认证数据库"
fi
output="$($OVPN --dir "$server_state" --dry-run passwd client1 --no-passwd)"
assert_contains "$output" "$server_state/auth-db"
mkdir -p "$test_dir/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$test_dir/bin/openvpn"
chmod 0755 "$test_dir/bin/openvpn"
printf crl >"$server_state/pki/crl.pem"
output="$(PATH="$test_dir/bin:$PATH" "$OVPN" --dir "$server_state" --dry-run apply)"
assert_contains "$output" '/etc/openvpn/server/client-event.sh'
assert_contains "$output" '/etc/openvpn/server/event-dispatch.sh'
assert_contains "$output" '/etc/openvpn/server/hooks'
output="$(cd "$test_dir" && PATH="$test_dir/bin:$PATH" "$OVPN" --dir "$server_state" --dry-run export client1 2>&1)"
assert_contains "$output" "$test_dir/client1.ovpn"
[[ "$output" != *'{{SERVER_PORT}} 出现 0 次'* && "$output" != *'{{SERVER_DEV}} 出现 0 次'* ]] || fail "客户端导出不应警告服务端分区变量"
if [[ -e "$test_dir/client1.ovpn" ]]; then fail "export dry-run 写入了目标文件"; fi
output="$($OVPN --dir "$server_state" --dry-run revoke client1)"
assert_contains "$output" "$server_state/clients/client1"
output="$($OVPN --dir "$server_state" --dry-run network nat_client enable)"
assert_contains "$output" 'dry-run 检查完成，未执行系统变更。'

old_state="$test_dir/old-state"
old_tmp="$test_dir/old-tmp"
mkdir -p "$old_state/config/server" "$old_state/pki/private" "$old_state/pki/issued" "$old_state/pki/reqs" "$old_tmp"
cp -- "$server_state/config/ovpn.env" "$old_state/config/ovpn.env"
printf cert >"$old_state/pki/ca.crt"
printf cert >"$old_state/pki/ca-chain.crt"
printf key >"$old_state/pki/private/ca.key"
: >"$old_state/pki/index.txt"
printf 'server {{SERVER}}\nca {{CA_CERT}}\nup {{UP_SCRIPT}}\ndown {{DOWN_SCRIPT}}\n{{APPEND_CONFIG}}\n' >"$old_state/config/server/default.conf.tpl"
assert_fails env TMPDIR="$old_tmp" "$OVPN" --dir "$old_state" --dry-run apply
[[ -z "$(find "$old_tmp" -mindepth 1 -print -quit)" ]] || fail "apply 失败后遗留临时文件"

printf 'PASS: CLI 静态与 dry-run 测试\n'
