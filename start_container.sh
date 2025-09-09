#!/bin/bash

if ! docker start wireguard 2>/dev/null; then
    docker run \
        --cap-add=NET_ADMIN \
        --name=wireguard \
        -d \
        -p 51821:51821/udp \
        -v ./keys:/config/server \
        -v ./wireguard:/config/wg_confs \
        wireguard \
        -c "/config/wireguard-entrypoint.sh"
fi