#!/bin/bash
CONTAINER_NAME=wireguard

CONTAINER_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $CONTAINER_NAME)

if [-n "$CONTAINER_IP"]; then
    echo "Removing NAT rules for $CONTAINER_IP"
    sudo iptables -t nat -D POSTROUTING -s $CONTAINER_IP -j MASQUERADE 2>/dev/null
    sudo iptables -t nat -D PREROUTING -j DNAT --to-destination $CONTAINER_NAME 2>/dev/null
fi

docker stop $CONTAINER_NAME 2>/dev/null