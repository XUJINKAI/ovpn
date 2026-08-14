# OpenVPN 2.6+ 现代客户端模板
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
tls-cert-profile preferred

auth {{AUTH_DIGEST}}
data-ciphers {{DATA_CIPHERS}}

verb {{CLIENT_VERB}}

{{AUTH_USER_PASS}}
{{APPEND_CONFIG}}

{{CA_INLINE}}
{{CLIENT_CERT_INLINE}}
{{CLIENT_KEY_INLINE}}
{{TLS_CRYPT_V2_CLIENT_INLINE}}
