#!/usr/bin/env bash
# Easy-RSA CA、证书和 CRL 管理。

ovpn_easyrsa() {
    EASYRSA_PKI="$OVPN_STATE_DIR/pki" EASYRSA_BATCH=1 "$OVPN_EASYRSA" "$@"
}

ovpn_pki_init() {
    local days="${1:-3650}" pki="$OVPN_STATE_DIR/pki"
    ovpn_easyrsa init-pki
    EASYRSA_PKI="$pki" EASYRSA_BATCH=1 EASYRSA_REQ_CN='ovpn local CA' EASYRSA_CA_EXPIRE="$days" "$OVPN_EASYRSA" build-ca nopass
    cp -- "$pki/ca.crt" "$pki/ca-chain.crt"
    chmod 0644 -- "$pki/ca-chain.crt"
    ovpn_pki_generate_crl
}

ovpn_pki_build_server_chain() {
    local pki="$OVPN_STATE_DIR/pki" output="$OVPN_STATE_DIR/pki/issued/server-chain.crt"
    if [[ -s "$pki/upstream-chain.crt" ]]; then
        { cat -- "$pki/issued/server.crt" "$pki/ca.crt" "$pki/upstream-chain.crt"; } >"$output"
    else
        cp -- "$pki/issued/server.crt" "$output"
    fi
    chmod 0644 -- "$output"
}

ovpn_pki_sign_server() {
    local days="${1:-3650}"
    EASYRSA_CERT_EXPIRE="$days" ovpn_easyrsa build-server-full server nopass
    ovpn_pki_build_server_chain
}

ovpn_pki_sign_client() {
    local name="$1" days="${2:-1095}" client_dir pki="$OVPN_STATE_DIR/pki"
    client_dir="$OVPN_STATE_DIR/clients/$name"
    install -d -o root -g root -m 0700 -- "$client_dir"
    EASYRSA_CERT_EXPIRE="$days" ovpn_easyrsa build-client-full "$name" nopass
    openvpn --tls-crypt-v2 "$pki/tls-crypt-v2-server.key" --genkey tls-crypt-v2-client "$client_dir/tls-crypt-v2.key"
    chmod 0600 -- "$client_dir/tls-crypt-v2.key"
}

ovpn_pki_generate_crl() {
    ovpn_easyrsa gen-crl
    chmod 0644 -- "$OVPN_STATE_DIR/pki/crl.pem"
}

ovpn_pki_revoke_client() {
    local name="$1" pki="$OVPN_STATE_DIR/pki"
    ovpn_easyrsa revoke-issued "$name"
    ovpn_pki_generate_crl
    rm -f -- "$pki/private/$name.key" "$pki/reqs/$name.req"
}

ovpn_ca_summary() {
    local pki="$OVPN_STATE_DIR/pki" subject issuer source='Easy-RSA CA'
    [[ -s "$pki/ca.crt" ]] || { printf 'CA：未初始化\n'; return; }
    if ovpn_have openssl; then
        subject="$(openssl x509 -in "$pki/ca.crt" -noout -subject 2>/dev/null || true)"
        issuer="$(openssl x509 -in "$pki/ca.crt" -noout -issuer 2>/dev/null || true)"
        [[ "${subject#subject=}" != "${issuer#issuer=}" ]] || source='Easy-RSA 自签 CA'
        [[ ! -s "$pki/upstream-chain.crt" ]] || source='Easy-RSA 外部签发中间 CA'
        printf 'CA 来源：%s\n' "$source"
        openssl x509 -in "$pki/ca.crt" -noout -subject -issuer -serial -fingerprint -sha256 2>/dev/null || printf 'CA 证书：无法解析\n'
        printf 'CA 过期时间：%s\n' "$(ovpn_cert_expiry "$pki/ca.crt")"
    else
        printf 'CA 来源：%s\nCA 证书：未检查（缺少 openssl）\nCA 过期时间：未检查\n' "$source"
    fi
}

ovpn_cert_expiry() {
    local expiry
    [[ -s "$1" ]] || { printf '%s\n' 缺失; return; }
    ovpn_have openssl || { printf '%s\n' 未检查; return; }
    expiry="$(openssl x509 -in "$1" -noout -enddate 2>/dev/null)" || { printf '%s\n' 无法解析; return; }
    printf '%s\n' "${expiry#notAfter=}"
}
