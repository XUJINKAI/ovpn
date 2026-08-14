# OpenVPN 2.5 兼容客户端模板
client

dev {{CLIENT_DEV}}
proto {{CLIENT_PROTO}}
remote {{ENDPOINT}} {{CLIENT_PORT}}

resolv-retry infinite
nobind

persist-key
persist-tun

remote-cert-tls server
verify-x509-name server name

tls-version-min 1.2

auth SHA256
data-ciphers AES-256-GCM:AES-128-GCM:AES-256-CBC
data-ciphers-fallback AES-256-CBC
ncp-ciphers AES-256-GCM:AES-128-GCM:AES-256-CBC
cipher AES-256-CBC

verb {{CLIENT_VERB}}

{{AUTH_USER_PASS}}
{{APPEND_CONFIG}}

{{CA_INLINE}}
{{CLIENT_CERT_INLINE}}
{{CLIENT_KEY_INLINE}}
{{TLS_CRYPT_V2_CLIENT_INLINE}}
