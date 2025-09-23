#!/bin/bash

echo "Starting transparent proxy..."

echo "Starting redsocks..."
redsocks -c /etc/redsocks/redsocks.conf &

sleep 2

echo "Transparent proxy ready on port 3128"
echo "Container will route traffic through VPN via shared network"

wait