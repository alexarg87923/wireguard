#!/bin/bash

if [ -z "$PROFILE" ]; then
  echo "Error: PROFILE is not set"
  exit 1
fi

if [ "$PROFILE" = "client" ] && [ -z "$ALLOWEDIPS" ]; then
  echo "Error: ALLOWEDIPS is not set (required for client profile)"
  exit 1
fi

# Auto-detect HOST_PUBLIC_IP if not set (for client profile)
if [ "$PROFILE" = "client" ] && [ -z "$HOST_PUBLIC_IP" ]; then
  echo "Detecting host public IP..."
  HOST_PUBLIC_IP=$(ip route get 8.8.8.8 2>/dev/null | awk -F'src ' '{print $2}' | awk '{print $1; exit}' || echo "")
  if [ -z "$HOST_PUBLIC_IP" ] || [[ ! "$HOST_PUBLIC_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "Warning: Could not auto-detect HOST_PUBLIC_IP. Please set it manually"
    echo "You can find it with: ip route get 8.8.8.8 | grep -oP 'src \\K[^ ]+'"
    exit 1
  fi
  export HOST_PUBLIC_IP
  echo "Detected HOST_PUBLIC_IP: $HOST_PUBLIC_IP"
fi

# Always use docker compose to ensure containers are managed by compose
echo "Starting container..."
docker compose --profile ${PROFILE} up -d

# Wait for container to be running (especially important for host routing setup)
CONTAINER_NAME="wireguard-${PROFILE}"
echo "Waiting for container to be ready..."
max_attempts=30
attempt=0
while [ $attempt -lt $max_attempts ]; do
  if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    # Check if container has an IP address
    CONTAINER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CONTAINER_NAME}" 2>/dev/null)
    if [ -n "$CONTAINER_IP" ]; then
      echo "Container ${CONTAINER_NAME} is running with IP: $CONTAINER_IP"
      break
    fi
  fi
  attempt=$((attempt + 1))
  sleep 1
done

if [ $attempt -eq $max_attempts ]; then
  echo "Warning: Container ${CONTAINER_NAME} may not be fully ready yet"
fi
