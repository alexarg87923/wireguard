#!/bin/bash

CONTAINER_NAME=wireguard
ENDPOINT_FILE=./config/endpoint

if ! docker start $CONTAINER_NAME 2>/dev/null; then
    if [ -f "./config/endpoint" ]; then
        echo "Detected client mode (endpoint found)"
        docker run \
            --cap-add=NET_ADMIN \
            --sysctl="net.ipv4.conf.all.src_valid_mark=1" \
            --name=$CONTAINER_NAME \
            -d \
            -e ALLOWEDIPS="$(cat ./config/allowed_ips)" \
            -v ./keys:/config/server \
            -v ./config:/config/wg_confs \
            $CONTAINER_NAME \
            -c "/config/wireguard-entrypoint.sh"
    else
        echo "Detected server mode (endpoint not found)"
        docker run \
            --cap-add=NET_ADMIN \
            --name=$CONTAINER_NAME \
            -d \
            -p 51821:51821/udp \
            -e PEERS=0 \
            -e ALLOWEDIPS="$(cat ./config/allowed_ips)" \
            -v ./keys:/config/server \
            -v ./config:/config/wg_confs \
            $CONTAINER_NAME \
            -c "/config/wireguard-entrypoint.sh"
    fi
fi

if [ -f "$ENDPOINT_FILE" ]; then
  CONTAINER_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $CONTAINER_NAME)
  sudo iptables -t nat -A POSTROUTING -s $CONTAINER_IP -j MASQUERADE
  sudo iptables -t nat -A PREROUTING -j DNAT --to-destination $CONTAINER_IP
fi
