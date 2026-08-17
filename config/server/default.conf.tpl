# OpenVPN 2.6+ 现代服务端模板
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

tls-crypt-v2 {{TLS_CRYPT_V2_SERVER_KEY}} force-cookie
tls-version-min 1.2
tls-cert-profile preferred

verify-client-cert require
remote-cert-tls client

auth {{AUTH_DIGEST}}
data-ciphers {{DATA_CIPHERS}}

script-security 2
auth-user-pass-verify {{AUTH_VERIFY_SCRIPT}} via-file
auth-user-pass-optional
setenv OVPN_AUTH_DB {{AUTH_DB}}
client-connect {{CLIENT_EVENT_SCRIPT}}
client-disconnect {{CLIENT_EVENT_SCRIPT}}

max-clients {{MAX_CLIENTS}}

keepalive {{KEEPALIVE}}
persist-key
persist-tun

user nobody
group nogroup

verb {{SERVER_VERB}}
explicit-exit-notify 1

{{APPEND_CONFIG}}
