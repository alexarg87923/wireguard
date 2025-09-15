#!/bin/bash

if ! docker start wireguard 2>/dev/null; then
    if [ -f "./config/endpoint" ]; then
        echo "Detected client mode (endpoint found)"

        CONFIG_DIR="./config"
        KEY_DIR="./keys"

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

[Peer]
PublicKey = $(cat ${CONFIG_DIR}/peer1.pub)
$( [ -f "${CONFIG_DIR}/peer1.psk" ] && echo "PresharedKey = $(cat ${CONFIG_DIR}/peer1.psk)" )
Endpoint = $(cat ${CONFIG_DIR}/endpoint):$(cat ${CONFIG_DIR}/port)
AllowedIPs = $(cat ${CONFIG_DIR}/allowed_ips)
EOF
        echo "Generated client wg0.conf"

        docker run \
            --cap-add=NET_ADMIN \
            --name=wireguard \
            -d \
            -e ALLOWEDIPS="$(cat ./config/allowed_ips)" \
            -v ./keys:/config/server \
            -v ./config:/config/wg_confs \
            wireguard \
            -c "/config/wireguard-entrypoint.sh"
    else
        echo "Detected server mode (endpoint not found)"
        docker run \
            --cap-add=NET_ADMIN \
            --name=wireguard \
            -d \
            -p 51821:51821/udp \
            -e PEERS=0 \
            -e ALLOWEDIPS="$(cat ./config/allowed_ips)" \
            -v ./keys:/config/server \
            -v ./config:/config/wg_confs \
            wireguard \
            -c "/config/wireguard-entrypoint.sh"
    fi
fi