destroy table inet ovpn_nat_client
table inet ovpn_nat_client {
    chain forward {
        type filter hook forward priority filter; policy accept;
        ip saddr {{VPN_CIDR}} accept
        ip daddr {{VPN_CIDR}} ct state established,related accept
    }
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr {{VPN_CIDR}} masquerade
    }
}
