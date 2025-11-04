#!/bin/bash

# Script to remove iptables rules set up by setup_host_routing.sh

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
  echo "Error: This script must be run as root (use sudo)"
  exit 1
fi

echo "Removing host routing rules..."

# Load .env to get container subnet if available
ENV_FILE=./.env
CONTAINER_SUBNET=""
MAIN_IF=""

if [ -f "$ENV_FILE" ]; then
  set -o allexport
  source "$ENV_FILE"
  set +o allexport
  
  # Try to detect if container is running to get subnet
  if docker ps --format '{{.Names}}' | grep -q "^wireguard-client$"; then
    NETWORK_NAME=$(docker inspect -f '{{range $key, $value := .NetworkSettings.Networks}}{{$key}}{{end}}' "wireguard-client" 2>/dev/null | head -n1)
    if [ -n "$NETWORK_NAME" ]; then
      CONTAINER_SUBNET=$(docker network inspect "${NETWORK_NAME}" 2>/dev/null | grep -i '"Subnet"' | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | head -n1)
    fi
  fi
  
  MAIN_IF=$(ip route show default | awk '/default/ {print $5}' | head -n1)
fi

# Remove VPN subnet route
ip route del 10.0.2.0/24 2>/dev/null || true

# Remove FORWARD rules
if [ -n "$CONTAINER_SUBNET" ]; then
  iptables -D FORWARD -d "$CONTAINER_SUBNET" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -s "$CONTAINER_SUBNET" -j ACCEPT 2>/dev/null || true
else
  # Try common Docker subnets
  for subnet in "172.18.0.0/16" "172.17.0.0/16" "192.168.0.0/16"; do
    iptables -D FORWARD -d "$subnet" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -s "$subnet" -j ACCEPT 2>/dev/null || true
  done
fi

# Remove NAT rule
if [ -n "$CONTAINER_SUBNET" ] && [ -n "$MAIN_IF" ]; then
  iptables -t nat -D POSTROUTING -s "$CONTAINER_SUBNET" -o "$MAIN_IF" -j MASQUERADE 2>/dev/null || true
else
  # Try to remove NAT rules matching common patterns
  if [ -n "$MAIN_IF" ]; then
    iptables -t nat -S POSTROUTING | grep "MASQUERADE.*$MAIN_IF" | sed 's/-A/-D/' | while read line; do
      if echo "$line" | grep -q "172\."; then
        eval "iptables $line" 2>/dev/null || true
      fi
    done
  fi
fi

# Remove UFW rules
echo "Removing UFW rules..."
if command -v ufw >/dev/null 2>&1; then
  # Remove UFW rule for VPN SSH access (always 10.0.2.0/24)
  # Try deleting by rule syntax first, then by rule number if that fails
  if ! echo "y" | ufw delete allow from 10.0.2.0/24 to any port 22 2>/dev/null; then
    # Fallback: find rule by comment and delete by number
    ufw status numbered 2>/dev/null | grep -i "WireGuard VPN SSH access" | awk -F'[][]' '{print $2}' | sort -rn | while read num; do
      echo "y" | ufw delete "$num" 2>/dev/null || true
    done || true
  fi
  
  # Remove UFW route rule for container forwarding
  if [ -n "$CONTAINER_SUBNET" ]; then
    # Try deleting route rule by syntax
    if ! echo "y" | ufw route delete allow from "$CONTAINER_SUBNET" to any port 22 2>/dev/null; then
      # Fallback: find route rule by comment in route status
      ufw status numbered 2>/dev/null | grep -i "WireGuard container forwarding" | awk -F'[][]' '{print $2}' | sort -rn | while read num; do
        echo "y" | ufw delete "$num" 2>/dev/null || true
      done || true
    fi
  else
    # Try to remove by comment if subnet not available
    ufw status numbered 2>/dev/null | grep -i "WireGuard container forwarding" | awk -F'[][]' '{print $2}' | sort -rn | while read num; do
      echo "y" | ufw delete "$num" 2>/dev/null || true
    done || true
  fi
  
  # Reload UFW to apply changes
  ufw --force reload >/dev/null 2>&1 || true
else
  echo "UFW not found, skipping UFW rule removal"
fi

echo "Host routing rules removed!"
