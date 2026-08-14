# OpenVPN 2.5 兼容服务端模板
port {{SERVER_PORT}}
proto {{SERVER_PROTO}}
dev {{SERVER_DEV}}

topology subnet
server {{SERVER}}

ca {{CA_CERT}}
cert {{SERVER_CERT}}
key {{SERVER_KEY}}
dh none
crl-verify {{CRL_FILE}}

tls-crypt-v2 {{TLS_CRYPT_V2_SERVER_KEY}}
tls-version-min 1.2

verify-client-cert require
remote-cert-tls client

auth SHA256
data-ciphers AES-256-GCM:AES-128-GCM:AES-256-CBC
data-ciphers-fallback AES-256-CBC
ncp-ciphers AES-256-GCM:AES-128-GCM:AES-256-CBC
cipher AES-256-CBC

script-security 2
auth-user-pass-verify {{AUTH_VERIFY_SCRIPT}} via-file
auth-user-pass-optional
setenv OVPN_AUTH_DB {{AUTH_DB}}

keepalive {{KEEPALIVE}}
persist-key
persist-tun

user nobody
group nogroup

verb {{SERVER_VERB}}
explicit-exit-notify 1

{{APPEND_CONFIG}}
