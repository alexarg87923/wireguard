#!/bin/bash

PEER_PSK="/config/wg_confs/peer1.psk"
CONFIG_DIR="/config/wg_confs"
KEY_DIR="/config/server"

if [ ! -f "$KEY_DIR/privatekey-client" ]; then
    echo "No client keypair found, generating..."
    umask 077
    wg genkey | tee "$KEY_DIR/privatekey-client" | wg pubkey > "$KEY_DIR/publickey-client"
fi

cat > "$CONFIG_DIR/wg0.conf" <<EOF
[Interface]
Address = $(cat ${CONFIG_DIR}/client_ip)
PrivateKey = $(cat ${KEY_DIR}/privatekey-client)
$( [ -f "${CONFIG_DIR}/dns" ] && echo "DNS = $(cat ${CONFIG_DIR}/dns)" )
PostUp = iptables -t nat -A POSTROUTING -o %i -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o %i -j MASQUERADE

[Peer]
PublicKey = $(cat ${CONFIG_DIR}/peer1.pub)
$( [ -f "${CONFIG_DIR}/peer1.psk" ] && echo "PresharedKey = $(cat ${CONFIG_DIR}/peer1.psk)" )
Endpoint = $(cat ${CONFIG_DIR}/endpoint):$(cat ${CONFIG_DIR}/port)
AllowedIPs = $(cat ${CONFIG_DIR}/allowed_ips)
EOF
echo "Generated client wg0.conf"

if [ ! -f "$PEER_PSK" ]; then
    wg genpsk > "$PEER_PSK"
fi

exec /init
