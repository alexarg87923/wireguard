#!/bin/bash

if ! docker start wireguard 2>/dev/null; then
    if [ -f "./config/endpoint" ]; then
        echo "Detected client mode (endpoint found)"
        docker run \
            --cap-add=NET_ADMIN \
            --cap-add=SYS_MODULE \
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