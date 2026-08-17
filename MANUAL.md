# OpenVPN 原生部署手册

本文说明在没有`ovpn`项目、源码、入口、模块和项目模板的情况下，只使用 Debian 13 软件包、Easy-RSA、OpenSSL、OpenVPN、systemd、sysctl 和 nftables 实现同等的单实例 OpenVPN 能力。
示例使用独立的`/etc/openvpn/manual`保存 PKI 和客户端状态，使用`/etc/openvpn/server`保存服务运行材料；执行前应按实际环境修改公网端点、VPN 网段、推送策略和证书主题。
私钥、密码和完整客户端配置不得进入仓库、命令参数、日志或不安全的临时目录。

## 安装依赖

```bash
# 不隐式执行 apt update，也不自动启动服务。
sudo apt-get install -y openvpn easy-rsa openssl nftables util-linux
```

## 建立状态目录

```bash
state=/etc/openvpn/manual
sudo install -d -o root -g root -m 0755 "$state"
sudo install -d -o root -g root -m 0700 "$state/pki" "$state/clients" "$state/backup"
```

## 初始化自签 CA

```bash
state=/etc/openvpn/manual
sudo env EASYRSA_PKI="$state/pki" EASYRSA_BATCH=1 /usr/share/easy-rsa/easyrsa init-pki
sudo env EASYRSA_PKI="$state/pki" EASYRSA_BATCH=1 EASYRSA_CA_EXPIRE=3650 EASYRSA_REQ_CN='OpenVPN local CA' /usr/share/easy-rsa/easyrsa build-ca nopass
sudo install -o root -g root -m 0644 "$state/pki/ca.crt" "$state/pki/ca-chain.crt"
sudo env EASYRSA_PKI="$state/pki" EASYRSA_BATCH=1 /usr/share/easy-rsa/easyrsa gen-crl
```

## 使用外部签发中间 CA

```bash
# 用本节完整替代“初始化自签 CA”；它最终产生相同的 Easy-RSA PKI 接口。
state=/etc/openvpn/manual
sudo env EASYRSA_PKI="$state/pki" EASYRSA_BATCH=1 /usr/share/easy-rsa/easyrsa init-pki
sudo env EASYRSA_PKI="$state/pki" EASYRSA_BATCH=1 EASYRSA_REQ_CN='OpenVPN intermediate CA' /usr/share/easy-rsa/easyrsa build-ca nopass subca
# 把 root-only 的 pki/reqs/ca.req 安全复制出去，交给上级 CA 按 CA:TRUE、keyCertSign、cRLSign 和合适的 pathlen 签发。
install -m 0600 /dev/null "$HOME/openvpn-intermediate.req"
sudo sh -c 'cat "$1"' _ "$state/pki/reqs/ca.req" >"$HOME/openvpn-intermediate.req"

# 上级 CA 返回中间证书和从其直接签发者到根 CA 的有序 PEM 链后，先验证再安装；不得复制根 CA 私钥。
signed_ca=/secure/openvpn-intermediate.crt
upstream_chain=/secure/upstream-chain.crt
openssl x509 -in "$signed_ca" -noout -checkend 0 -text
cert_pub="$(openssl x509 -in "$signed_ca" -pubkey -noout | openssl sha256)"
key_pub="$(sudo openssl pkey -in "$state/pki/private/ca.key" -pubout | openssl sha256)"
test "$cert_pub" = "$key_pub"
openssl verify -CAfile "$upstream_chain" -untrusted "$upstream_chain" "$signed_ca"
sudo install -o root -g root -m 0644 "$signed_ca" "$state/pki/ca.crt"
sudo install -o root -g root -m 0644 "$upstream_chain" "$state/pki/upstream-chain.crt"
sudo sh -c 'cat "$1" "$2" >"$3"' _ "$state/pki/ca.crt" "$state/pki/upstream-chain.crt" "$state/pki/ca-chain.crt"
sudo env EASYRSA_PKI="$state/pki" EASYRSA_BATCH=1 /usr/share/easy-rsa/easyrsa gen-crl
```

## 签发服务端证书和运行密钥

```bash
state=/etc/openvpn/manual
sudo env EASYRSA_PKI="$state/pki" EASYRSA_BATCH=1 EASYRSA_CERT_EXPIRE=3650 /usr/share/easy-rsa/easyrsa build-server-full server nopass
sudo openvpn --genkey tls-crypt-v2-server "$state/pki/tls-crypt-v2-server.key"
sudo chmod 0600 "$state/pki/private/server.key" "$state/pki/tls-crypt-v2-server.key"
# 自签 CA 执行第一条；外部签发中间 CA 执行第二条。
sudo cp "$state/pki/issued/server.crt" "$state/pki/issued/server-chain.crt"
sudo sh -c 'cat "$1" "$2" "$3" >"$4"' _ "$state/pki/issued/server.crt" "$state/pki/ca.crt" "$state/pki/upstream-chain.crt" "$state/pki/issued/server-chain.crt"
```

## 创建可选密码认证脚本

```bash
state=/etc/openvpn/manual
sudo touch "$state/auth-db"
sudo chown root:nogroup "$state/auth-db"
sudo chmod 0640 "$state/auth-db"
sudo install -d -o root -g root -m 0755 /etc/openvpn/server
sudo tee /etc/openvpn/server/auth-verify.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
credentials=${1:-}
database=${OVPN_AUTH_DB:-/etc/openvpn/manual/auth-db}
dispatcher=/etc/openvpn/server/event-dispatch.sh
reject() {
    if ! OVPN_COMMON_NAME="${common_name:-}" OVPN_REMOTE_IP="${untrusted_ip:-${untrusted_ip6:-}}" OVPN_REMOTE_PORT="${untrusted_port:-}" "$dispatcher" authentication-failed; then printf 'OpenVPN 认证失败通知分发异常\n' >&2; fi
    exit 1
}
[[ -f "$database" && ! -L "$database" ]] || reject
name=${common_name:-}
[[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || reject
stored=$(awk -F: -v name="$name" '$1 == name { count++; if (NF != 2) invalid=1; value=$2 } END { if (count != 1 || invalid) exit 1; print value }' "$database") || reject
[[ "$stored" == '!' ]] && exit 0
[[ "$stored" == '$6$'* && -f "$credentials" && ! -L "$credentials" ]] || reject
IFS= read -r username <"$credentials" || reject
IFS= read -r password < <(sed -n '2p' "$credentials") || reject
[[ "$username" == "$name" ]] || reject
salt=$(awk -F'$' '{ print $3 }' <<<"$stored")
calculated=$(printf '%s\n' "$password" | openssl passwd -6 -salt "$salt" -stdin)
[[ "$calculated" == "$stored" ]] || reject
EOF
sudo chmod 0755 /etc/openvpn/server/auth-verify.sh
```

## 创建连接事件和通知回调

以下分发器只允许三个固定事件，把字段限制为单行并从空环境调用用户回调。
回调最多运行十秒，失败或超时不改变 OpenVPN 的认证和连接结果。

```bash
sudo install -d -o root -g nogroup -m 0750 /etc/openvpn/server/hooks
sudo tee /etc/openvpn/server/event-dispatch.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
event=${1:-}
case "$event" in authentication-failed|client-connected|client-disconnected) ;; *) exit 0 ;; esac
hook="/etc/openvpn/server/hooks/$event"
[[ -f "$hook" && ! -L "$hook" && -x "$hook" ]] || exit 0
sanitize() { local value=${1:-}; value=${value//$'\n'/}; value=${value//$'\r'/}; printf '%s' "${value:0:512}"; }
if ! timeout --signal=TERM --kill-after=2s 10s env -i \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    OVPN_EVENT="$event" \
    OVPN_COMMON_NAME="$(sanitize "${OVPN_COMMON_NAME:-}")" \
    OVPN_REMOTE_IP="$(sanitize "${OVPN_REMOTE_IP:-}")" \
    OVPN_REMOTE_PORT="$(sanitize "${OVPN_REMOTE_PORT:-}")" \
    OVPN_IFCONFIG_POOL_REMOTE_IP="$(sanitize "${OVPN_IFCONFIG_POOL_REMOTE_IP:-}")" \
    OVPN_CONNECTED_AT="$(sanitize "${OVPN_CONNECTED_AT:-}")" \
    OVPN_DURATION_SECONDS="$(sanitize "${OVPN_DURATION_SECONDS:-}")" \
    OVPN_BYTES_RECEIVED="$(sanitize "${OVPN_BYTES_RECEIVED:-}")" \
    OVPN_BYTES_SENT="$(sanitize "${OVPN_BYTES_SENT:-}")" \
    "$hook" "$event"; then exit 0; fi
EOF
sudo chmod 0755 /etc/openvpn/server/event-dispatch.sh

sudo tee /etc/openvpn/server/client-event.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in connect) event=client-connected ;; disconnect) event=client-disconnected ;; *) exit 0 ;; esac
export OVPN_COMMON_NAME="${common_name:-}"
export OVPN_REMOTE_IP="${trusted_ip:-${trusted_ip6:-}}"
export OVPN_REMOTE_PORT="${trusted_port:-}"
export OVPN_IFCONFIG_POOL_REMOTE_IP="${ifconfig_pool_remote_ip:-}"
export OVPN_CONNECTED_AT="${time_ascii:-}"
export OVPN_DURATION_SECONDS="${time_duration:-}"
export OVPN_BYTES_RECEIVED="${bytes_received:-}"
export OVPN_BYTES_SENT="${bytes_sent:-}"
if ! /etc/openvpn/server/event-dispatch.sh "$event"; then printf 'OpenVPN 连接事件通知分发异常：%s\n' "$event" >&2; fi
exit 0
EOF
sudo chmod 0755 /etc/openvpn/server/client-event.sh
```

按需创建以下任意回调，文件必须为`root:nogroup`、mode `0750`：`authentication-failed`、`client-connected`和`client-disconnected`。
事件名同时作为第一个参数和`OVPN_EVENT`环境变量传入；脚本可以读取来源地址、CN、虚拟地址和断开流量等白名单字段，但不得输出通知 Token 或其他秘密。
口令认证失败使用尚未完成身份认证的`untrusted_ip`来源字段；证书无效或吊销、TLS 和 tls-crypt-v2 失败以及达到`max-clients`不会触发这些回调，只能通过 OpenVPN 日志观察。

## 部署服务端配置

管理器的`ovpn edit env`、`ovpn edit server`和`ovpn edit client`只是使用`${OVPN_EDITOR:-vi}`打开对应的已有文件，服务端或客户端省略模板名时使用`default`，也可通过`server:NAME`或`client:NAME`打开其他模板。
在原生部署中直接用编辑器打开本手册建立的环境记录、服务端配置或客户端配置草稿即可；保存服务端修改后仍须执行后文的验证与重启步骤。

```bash
state=/etc/openvpn/manual
sudo install -d -o root -g root -m 0755 /etc/openvpn/server
sudo install -o root -g root -m 0644 "$state/pki/ca-chain.crt" /etc/openvpn/server/ca.crt
sudo install -o root -g root -m 0644 "$state/pki/issued/server-chain.crt" /etc/openvpn/server/server.crt
sudo install -o root -g root -m 0600 "$state/pki/private/server.key" /etc/openvpn/server/server.key
sudo install -o root -g root -m 0644 "$state/pki/crl.pem" /etc/openvpn/server/crl.pem
sudo install -o root -g root -m 0600 "$state/pki/tls-crypt-v2-server.key" /etc/openvpn/server/tls-crypt-v2.key
sudo tee /etc/openvpn/server/server.conf >/dev/null <<'EOF'
port 1194
proto udp4
dev tun
server 10.8.0.0 255.255.255.0
topology subnet
ca /etc/openvpn/server/ca.crt
cert /etc/openvpn/server/server.crt
key /etc/openvpn/server/server.key
dh none
crl-verify /etc/openvpn/server/crl.pem
tls-crypt-v2 /etc/openvpn/server/tls-crypt-v2.key
verify-client-cert require
remote-cert-tls client
auth SHA256
cipher AES-256-GCM
data-ciphers AES-256-GCM:AES-128-GCM
script-security 2
auth-user-pass-verify /etc/openvpn/server/auth-verify.sh via-file
auth-user-pass-optional
setenv OVPN_AUTH_DB /etc/openvpn/manual/auth-db
client-connect /etc/openvpn/server/client-event.sh connect
client-disconnect /etc/openvpn/server/client-event.sh disconnect
max-clients 100
keepalive 10 120
persist-key
persist-tun
user nobody
group nogroup
verb 3
EOF
sudo chmod 0600 /etc/openvpn/server/server.conf
# 如需 gateway、DNS 或内部路由，在启动前自行加入相应 push 指令。
sudo cat /etc/openvpn/server/server.conf
```

## 配置 systemd 运行边界

```bash
sudo install -d -o root -g root -m 0755 /etc/systemd/system/openvpn-server@server.service.d
sudo tee /etc/systemd/system/openvpn-server@server.service.d/manual.conf >/dev/null <<'EOF'
[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SETGID CAP_SETUID CAP_DAC_OVERRIDE
LimitNPROC=100
ProtectHome=true
PrivateTmp=true
EOF
sudo systemctl daemon-reload
```

## 管理 IPv4 转发和客户端 NAT

```bash
# 转发与 OpenVPN 服务彼此独立；删除文件后重新加载不会强制覆盖其他 sysctl 对转发的要求。
printf 'net.ipv4.ip_forward = 1\n' | sudo tee /etc/sysctl.d/99-openvpn-manual.conf >/dev/null
sudo sysctl --system

# 规则只匹配 VPN 源网段，不猜测出口接口；先检查再加载。
sudo tee /etc/openvpn/server/openvpn-manual-nat.nft >/dev/null <<'EOF'
destroy table inet openvpn_manual_nat
table inet openvpn_manual_nat {
    chain forward {
        type filter hook forward priority filter; policy accept;
        ip saddr 10.8.0.0/24 accept
        ip daddr 10.8.0.0/24 ct state established,related accept
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr 10.8.0.0/24 masquerade
    }
}
EOF
sudo nft -c -f /etc/openvpn/server/openvpn-manual-nat.nft
sudo tee /etc/systemd/system/openvpn-manual-nat.service >/dev/null <<'EOF'
[Unit]
Description=OpenVPN manual client NAT
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/openvpn/server/openvpn-manual-nat.nft
ExecStop=-/usr/sbin/nft delete table inet openvpn_manual_nat

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now openvpn-manual-nat.service
```

## 启动、验证和恢复服务

```bash
sudo test -s /etc/openvpn/server/server.conf
if sudo grep -Eq '\{\{[A-Z0-9_]+\}\}' /etc/openvpn/server/server.conf; then exit 1; fi
sudo systemctl enable --now openvpn-server@server.service
sudo systemctl status openvpn-server@server.service
sudo journalctl -u openvpn-server@server.service -n 100 --no-pager
# 持续跟随新日志，对应 ovpn core logs -f。
sudo journalctl -u openvpn-server@server.service -n 100 --no-pager -f
# OpenVPN 2.6 没有覆盖 TLS 和运行权限的无副作用完整检查，真实启动是最终本机验证。
# 变更前复制 server.conf、CRL、hook 和 drop-in；restart 失败时恢复副本、daemon-reload 后重新启动。
```

## 新增客户端身份

```bash
name=client1
state=/etc/openvpn/manual
sudo install -d -o root -g root -m 0700 "$state/clients/$name"
sudo env EASYRSA_PKI="$state/pki" EASYRSA_BATCH=1 EASYRSA_CERT_EXPIRE=1095 /usr/share/easy-rsa/easyrsa build-client-full "$name" nopass
sudo openvpn --tls-crypt-v2 "$state/pki/tls-crypt-v2-server.key" --genkey tls-crypt-v2-client "$state/clients/$name/tls-crypt-v2.key"
sudo chmod 0600 "$state/clients/$name/tls-crypt-v2.key"
```

## 设置客户端密码

```bash
name=client1
state=/etc/openvpn/manual
read -r -s -p '客户端密码：' password
printf '\n' >&2
hash=$(printf '%s\n' "$password" | openssl passwd -6 -stdin)
unset password
temporary=$(sudo mktemp --tmpdir="$state" .auth.XXXXXX)
sudo awk -F: -v name="$name" '$1 != name' "$state/auth-db" | sudo tee "$temporary" >/dev/null
printf '%s:%s\n' "$name" "$hash" | sudo tee -a "$temporary" >/dev/null
unset hash
sudo install -o root -g nogroup -m 0640 "$temporary" "$state/auth-db"
sudo rm -f -- "$temporary"
```

不设置密码时使用相同的原子写入流程，把该客户端记录写为`NAME:!`；删除客户端时才删除整条记录。认证数据库没有对应 CN、存在重复 CN 或包含未知值时，认证脚本一律拒绝。

## 导出客户端配置

```bash
# 在 root-only 临时目录创建完整配置，把公网地址和策略改成实际值；有密码时保留 auth-user-pass，无密码时删除该行。
name=client1
state=/etc/openvpn/manual
temporary=$(sudo mktemp -d)
sudo tee "$temporary/$name.ovpn" >/dev/null <<'EOF'
client
dev tun
proto udp4
remote vpn.example.com 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name server name
auth SHA256
cipher AES-256-GCM
data-ciphers AES-256-GCM:AES-128-GCM
auth-user-pass
verb 3
EOF
sudo sh -c 'printf "<ca>\n" >>"$1"; cat "$2" >>"$1"; printf "</ca>\n<cert>\n" >>"$1"; cat "$3" >>"$1"; printf "</cert>\n<key>\n" >>"$1"; cat "$4" >>"$1"; printf "</key>\n<tls-crypt-v2>\n" >>"$1"; cat "$5" >>"$1"; printf "</tls-crypt-v2>\n" >>"$1"' _ "$temporary/$name.ovpn" "$state/pki/ca-chain.crt" "$state/pki/issued/$name.crt" "$state/pki/private/$name.key" "$state/clients/$name/tls-crypt-v2.key"
sudo install -o "$USER" -g "$(id -gn)" -m 0600 "$temporary/$name.ovpn" "$PWD/$name.ovpn"
sudo rm -rf -- "$temporary"
```

## 吊销客户端（ovpn revoke）

```bash
name=client1
state=/etc/openvpn/manual
sudo env EASYRSA_PKI="$state/pki" EASYRSA_BATCH=1 /usr/share/easy-rsa/easyrsa revoke-issued "$name"
sudo env EASYRSA_PKI="$state/pki" EASYRSA_BATCH=1 /usr/share/easy-rsa/easyrsa gen-crl
sudo install -o root -g root -m 0644 "$state/pki/crl.pem" /etc/openvpn/server/crl.pem
sudo systemctl restart openvpn-server@server.service
sudo rm -f -- "$state/pki/private/$name.key" "$state/pki/reqs/$name.req"
sudo rm -rf -- "$state/clients/$name"
# 还要用临时文件原子删除 auth-db 中 NAME 对应的一整行；已经分发的配置无需回收，CRL 会拒绝其证书。
```

## 重签服务端证书和替换 CA

```bash
# 重签前备份整个 pki，依次运行 Easy-RSA 的 renew server、revoke-renewed server 和 gen-crl，再重建 server-chain.crt；restart 失败时恢复整个 pki 和原服务状态。
# 替换 CA 会让全部客户端失效，必须先停止服务并完整备份 pki、clients 和 auth-db，再重建 CA、服务端证书、CRL、DH 和 tls-crypt-v2 服务端密钥。
state=/etc/openvpn/manual
backup="$state/backup/ca-$(date +%Y%m%d-%H%M%S)"
sudo install -d -o root -g root -m 0700 "$backup"
sudo cp -a "$state/pki" "$state/clients" "$state/auth-db" "$backup/"
```

## 卸载和恢复

```bash
sudo systemctl disable --now openvpn-server@server.service
sudo systemctl disable --now openvpn-manual-nat.service
sudo nft delete table inet openvpn_manual_nat || true
sudo rm -f -- /etc/sysctl.d/99-openvpn-manual.conf /etc/openvpn/server/openvpn-manual-nat.nft /etc/openvpn/server/server.conf /etc/openvpn/server/ca.crt /etc/openvpn/server/server.crt /etc/openvpn/server/server.key /etc/openvpn/server/crl.pem /etc/openvpn/server/tls-crypt-v2.key /etc/openvpn/server/auth-verify.sh /etc/openvpn/server/client-event.sh /etc/openvpn/server/event-dispatch.sh /etc/openvpn/server/hooks/authentication-failed /etc/openvpn/server/hooks/client-connected /etc/openvpn/server/hooks/client-disconnected /etc/systemd/system/openvpn-server@server.service.d/manual.conf /etc/systemd/system/openvpn-manual-nat.service
sudo rmdir --ignore-fail-on-non-empty /etc/openvpn/server/hooks
sudo systemctl daemon-reload
sudo sysctl --system
# 默认保留 /etc/openvpn/manual。确认不再需要 CA 和客户端后，先把它复制到 root-only 备份目录，再删除该明确目录。
# 恢复时停止服务、原样恢复状态和运行文件、检查权限、daemon-reload，然后重新启动并查看 journal。
```
