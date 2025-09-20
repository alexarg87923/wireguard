#!/bin/bash

CONTAINER_NAME=wireguard
CONTAINER_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $CONTAINER_NAME)
ENDPOINT_FILE=./config/endpoint

if [ -f "$ENDPOINT_FILE" ]; then
  if [ -n "$CONTAINER_IP" ]; then
      echo "Removing NAT rules for $CONTAINER_IP"
      sudo iptables -t mangle -D OUTPUT -s $CONTAINER_IP -j MARK --set-mark 100
      sudo iptables -t nat -D OUTPUT -m mark ! --mark 100 -j DNAT --to-destination $CONTAINER_IP
  fi
fi

docker stop $CONTAINER_NAME 2>/dev/null