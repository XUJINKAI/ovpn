# OpenVPN 2.6 客户端参考模板。默认生效项与 default.conf.tpl 接近，其余选项按需取消注释。
# 官方完整参数说明：https://openvpn.net/community-docs/community-articles/openvpn-2-6-manual.html

# client 等价于 tls-client 与 pull，会接受服务端允许推送的路由等选项。
client
dev {{CLIENT_DEV}}
# dev-node tun-name
proto {{CLIENT_PROTO}}
# proto tcp4-client

# 可重复 remote 实现故障转移；remote-random 随机起点，remote-random-hostname 可绕过部分 DNS 缓存。
remote {{ENDPOINT}} {{CLIENT_PORT}}
# remote vpn-backup.example.com 1194 udp4
# remote-random
# remote-random-hostname
resolv-retry infinite
nobind
# connect-retry 1 300
# connect-retry-max infinite
# connect-timeout 120
# server-poll-timeout 10

# TLS 服务端身份校验。verify-x509-name 应匹配服务端证书名称。
remote-cert-tls server
verify-x509-name server name
# tls-version-min 1.2
# tls-cipher TLS-ECDHE-ECDSA-WITH-AES-256-GCM-SHA384:TLS-ECDHE-RSA-WITH-AES-256-GCM-SHA384
# tls-ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
# verify-x509-name vpn.example.com name
# peer-fingerprint AA:BB:CC:DD:EE:FF

# 数据通道算法必须与服务端有交集。
auth {{AUTH_DIGEST}}
cipher AES-256-GCM
data-ciphers {{DATA_CIPHERS}}
# data-ciphers-fallback AES-256-CBC

# 私钥和接口在重连时保持，适合长期运行客户端。
persist-key
persist-tun
# persist-local-ip
# persist-remote-ip

# 路由控制。client 隐含 pull；不信任服务端路由时用 pull-filter 或 route-nopull 收窄。
# redirect-gateway def1
# redirect-gateway ipv6
# pull-filter ignore "redirect-gateway"
# pull-filter reject "route 0.0.0.0"
# route-nopull
# route 192.0.2.0 255.255.255.0
# route 203.0.113.10 255.255.255.255 net_gateway
# route-ipv6 2001:db8:200::/64
# allow-pull-fqdn

# DNS 支持取决于客户端平台与实现；Linux OpenVPN 2.x 通常还需要系统 DNS 集成脚本。
# dhcp-option DNS 192.0.2.53
# dhcp-option DOMAIN internal.example.com
# dns server 0 address 192.0.2.53
# dns server 0 resolve-domains internal.example.com
# dns server 0 dnssec optional

# 代理。HTTP 代理认证文件和 SOCKS 凭据属于秘密，不要放进 --env 或 --add-config。
# http-proxy proxy.example.com 8080
# http-proxy-user-pass /secure/proxy-auth.txt
# http-proxy-option VERSION 1.1
# socks-proxy proxy.example.com 1080

# 链路探测与 MTU。服务端 keepalive 通常会推送 ping 设置，只有需要覆盖时才在客户端配置。
# ping 10
# ping-restart 120
# ping-timer-rem
# tun-mtu 1500
# mssfix 1450
# fragment 1300
# explicit-exit-notify 1

# 用户名密码由 {{AUTH_USER_PASS}} 根据客户端状态生成；auth-nocache 可减少凭据驻留内存时间。
{{AUTH_USER_PASS}}
# auth-retry interact
# auth-nocache

# 日志、脚本及管理接口。脚本需要 script-security 2；管理 TCP 端口不要无密码暴露。
verb {{CLIENT_VERB}}
# mute 20
# log-append /var/log/openvpn/client.log
# status /run/openvpn-client/status.log 60
# script-security 2
# up /etc/openvpn/client/scripts/up.sh
# down /etc/openvpn/client/scripts/down.sh
# down-pre
# management /run/openvpn/client-management.sock unix /secure/management-password

# export --add-config 的行在此按命令行顺序展开；不用时必须仍保留这个独占整行占位符。
{{APPEND_CONFIG}}

# 内联材料占位符必须各保留一次，避免把私钥或完整配置提交进仓库。
{{CA_INLINE}}
{{CLIENT_CERT_INLINE}}
{{CLIENT_KEY_INLINE}}
{{TLS_CRYPT_V2_CLIENT_INLINE}}
