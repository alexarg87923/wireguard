#!/bin/bash

set -euo pipefail

if [ "$EUID" -ne 0 ]; then 
  echo "Error: This script must be run as root (use sudo)"
  exit 1
fi

if [ "${PROFILE:-}" != "client" ]; then
  echo "Error: Host routing is only needed for client profile. Current PROFILE: ${PROFILE:-not set}"
  exit 1
fi

CONTAINER_NAME="wireguard-client"

# Check if container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  echo "Error: Container ${CONTAINER_NAME} is not running. Start it first with ./start_container.sh"
  exit 1
fi

echo "Detecting network configuration..."

# 1. Get container IP address
CONTAINER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CONTAINER_NAME}" 2>/dev/null)
if [ -z "$CONTAINER_IP" ]; then
  echo "Error: Could not get container IP address"
  exit 1
fi
echo "Container IP: $CONTAINER_IP"

# 2. Get Docker network name
NETWORK_NAME=$(docker inspect -f '{{range $key, $value := .NetworkSettings.Networks}}{{$key}}{{end}}' "${CONTAINER_NAME}" 2>/dev/null | head -n1)
if [ -z "$NETWORK_NAME" ]; then
  echo "Error: Could not get Docker network name"
  exit 1
fi

# 3. Get Docker bridge interface name
NETWORK_ID=$(docker network inspect "${NETWORK_NAME}" -f '{{.Id}}' 2>/dev/null)
if [ -z "$NETWORK_ID" ]; then
  echo "Error: Could not get Docker network ID"
  exit 1
fi

BRIDGE_IF="br-${NETWORK_ID:0:12}"

# Verify bridge exists
if ! ip link show "$BRIDGE_IF" &>/dev/null; then
  echo "Error: Bridge interface $BRIDGE_IF does not exist"
  exit 1
fi

echo "Docker bridge: $BRIDGE_IF"

# 4. Get main internet interface (default route)
MAIN_IF=$(ip route show default | awk '/default/ {print $5}' | head -n1)
if [ -z "$MAIN_IF" ]; then
  MAIN_IF=$(route -n 2>/dev/null | grep '^0.0.0.0' | awk '{print $8}' | head -n1)
fi
if [ -z "$MAIN_IF" ]; then
  echo "Error: Could not detect main internet interface"
  exit 1
fi
echo "Main interface: $MAIN_IF"

# 5. Get container network subnet
CONTAINER_SUBNET=$(docker network inspect "${NETWORK_NAME}" 2>/dev/null | grep -i '"Subnet"' | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | head -n1)
if [ -z "$CONTAINER_SUBNET" ]; then
  # Fallback: extract from container IP
  CONTAINER_SUBNET=$(echo "$CONTAINER_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')
fi
echo "Container subnet: $CONTAINER_SUBNET"

echo ""
echo "Setting up iptables rules..."

if [ -f "./remove_host_routing.sh" ]; then
  ./remove_host_routing.sh 2>/dev/null || true
fi

# 1. Allow container traffic forwarding
iptables -I FORWARD 1 -d "$CONTAINER_SUBNET" -j ACCEPT
iptables -I FORWARD 1 -s "$CONTAINER_SUBNET" -j ACCEPT

# 2. NAT for container's internet access
iptables -t nat -A POSTROUTING -s "$CONTAINER_SUBNET" -o "$MAIN_IF" -j MASQUERADE

# 3. Add route for VPN subnet to allow SSH replies back to VPN clients
echo "Adding route for VPN subnet (10.0.2.0/24) via container..."
ip route add 10.0.2.0/24 via "$CONTAINER_IP" 2>/dev/null || \
  ip route replace 10.0.2.0/24 via "$CONTAINER_IP"

# 4. Add UFW rules for VPN access
echo "Adding UFW rules..."
ufw allow from 10.0.2.0/24 to any port 22 comment "WireGuard VPN SSH access"
ufw allow from 10.0.2.0/24 to any port 8080 comment "Web"
ufw route allow from "$CONTAINER_SUBNET" to any port 22 comment "WireGuard container forwarding"
ufw --force reload > /dev/null

echo "Host routing rules configured successfully!"
echo ""
echo "Configuration summary:"
echo "  Container IP: $CONTAINER_IP"
echo "  Docker bridge: $BRIDGE_IF"
echo "  Main interface: $MAIN_IF"
echo "  Container subnet: $CONTAINER_SUBNET"
echo "  VPN subnet route: 10.0.2.0/24 via $CONTAINER_IP"
echo "  UFW rules: SSH access from VPN and container forwarding"
echo ""
echo "To remove these rules, run: sudo ./remove_host_routing.sh"
