# OpenVPN 2.6 服务端参考模板。默认生效项与 default.conf.tpl 接近，其余选项按需取消注释。
# 官方完整参数说明：https://openvpn.net/community-docs/community-articles/openvpn-2-6-manual.html

# 监听地址、端口和传输协议。tcp 服务端应使用 tcp4-server；同一实例不能同时监听 UDP 和 TCP。
# local 192.0.2.10
port {{SERVER_PORT}}
proto {{SERVER_PROTO}}
# proto tcp4-server

# 三层路由使用 tun；二层桥接改用 tap 和 server-bridge，并自行配置系统网桥。
dev {{SERVER_DEV}}
# dev-type tun
topology subnet
server {{SERVER}}
# server 10.8.0.0 255.255.255.0 nopool
# server-ipv6 2001:db8:100::/64
# ifconfig-pool-persist /var/lib/openvpn/server-ipp.txt 300

# PKI 与控制通道。以下受管占位符必须各保留一次，不要通过 --env 覆盖。
ca {{CA_CERT}}
cert {{SERVER_CERT}}
key {{SERVER_KEY}}
dh none
crl-verify {{CRL_FILE}}
tls-crypt-v2 {{TLS_CRYPT_V2_SERVER_KEY}}
# tls-version-min 1.2
# tls-cipher TLS-ECDHE-ECDSA-WITH-AES-256-GCM-SHA384:TLS-ECDHE-RSA-WITH-AES-256-GCM-SHA384
# tls-ciphersuites TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
# reneg-sec 3600

# 客户端必须同时通过证书校验；remote-cert-tls client 检查证书用途。
verify-client-cert require
remote-cert-tls client
# verify-x509-name expected-client-cn name
# x509-username-field CN
# duplicate-cn

# 数据通道算法。data-ciphers 是 2.6 的协商列表；cipher 主要用于兼容旧端。
auth {{AUTH_DIGEST}}
cipher AES-256-GCM
data-ciphers {{DATA_CIPHERS}}
# data-ciphers-fallback AES-256-CBC

# 推送路由、默认网关和 DNS。服务端必须另有系统路由、转发及防火墙许可。
# push "redirect-gateway def1"
# push "route 192.0.2.0 255.255.255.0"
# push "route-ipv6 2001:db8:200::/64"
# push "dhcp-option DNS 192.0.2.53"
# push "dhcp-option DOMAIN internal.example.com"
# push "dns server 0 address 192.0.2.53"
# push "dns server 0 resolve-domains internal.example.com"
# push-remove "redirect-gateway"
# push-reset 会清除 topology subnet 和 route-gateway 等必要推送，通常优先使用 push-remove。

# 客户端互访、固定地址及客户端后方网段。
# client-to-client
# client-config-dir /etc/openvpn/ovpn/config/server/client-config.d
# ccd-exclusive
# route 192.0.2.0 255.255.255.0
# client-config-dir 中对应 CN 文件可写：ifconfig-push、iroute、push、push-remove。

# 可选用户名密码验证。本项目允许无密码身份，因此保留 auth-user-pass-optional。
script-security 2
auth-user-pass-verify {{AUTH_VERIFY_SCRIPT}} via-file
auth-user-pass-optional
setenv OVPN_AUTH_DB {{AUTH_DB}}
# auth-gen-token 3600 600

# 链路探测、MTU 和队列。keepalive 10 120 等价于服务端 ping 10 与 ping-restart 120，并推送相应值。
keepalive {{KEEPALIVE}}
# tun-mtu 1500
# mssfix 1450
# fragment 1300
# sndbuf 0
# rcvbuf 0
# txqueuelen 1000

# 权限与重启持久性。client-config-dir、脚本和密钥必须在降权后仍可按其读取时机访问。
persist-key
persist-tun
user nobody
group nogroup
# chroot /var/empty

# 并发、连接与闲置限制。
# max-clients 100
# connect-freq 100 10
# connect-freq-initial 100 10
# inactive 3600 1048576
# session-timeout 28800

# UDP 可通知客户端立即退出；TCP 模式不要启用。
explicit-exit-notify 1

# 日志和运行状态。多实例必须使用不同输出文件；避免在常态下启用高详细级别。
verb {{SERVER_VERB}}
# mute 20
# status /run/openvpn-server/status-server.log 60
# status-version 3
# log-append /var/log/openvpn/server.log
# suppress-timestamps

# 脚本钩子会扩大执行面，启用前确认参数、权限、降权后的可访问性和失败行为。
# up /etc/openvpn/server/scripts/up.sh
# down /etc/openvpn/server/scripts/down.sh
# down-pre
# client-connect /etc/openvpn/server/scripts/client-connect.sh
# client-disconnect /etc/openvpn/server/scripts/client-disconnect.sh
# learn-address /etc/openvpn/server/scripts/learn-address.sh

# 管理接口若使用 TCP 且无密码会暴露高权限控制面；优先使用受权限限制的 Unix socket。
# management /run/openvpn/server-management.sock unix /etc/openvpn/server/management-password
# management-client-user root
# management-client-group root

# apply --add-config 的行在此按命令行顺序展开；不用时必须仍保留这个独占整行占位符。
{{APPEND_CONFIG}}
