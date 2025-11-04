#!/bin/bash

ENV_FILE=./.env

# Load .env to check PROFILE if available
if [ -f "$ENV_FILE" ]; then
  set -o allexport
  source "$ENV_FILE"
  set +o allexport
fi

# Remove host routing rules for client profile (requires root/sudo)
if [ "${PROFILE:-}" = "client" ] && [ -f "./remove_host_routing.sh" ]; then
  echo "Removing host routing rules..."
  if [ "$EUID" -ne 0 ]; then
    sudo ./remove_host_routing.sh
  else
    ./remove_host_routing.sh
  fi
fi

# Stop containers using the same profile that was used to start them
if [ -z "${PROFILE:-}" ]; then
  echo "Warning: PROFILE not set in .env, stopping all containers..."
  docker compose down --remove-orphans
else
  docker compose --profile ${PROFILE} down --remove-orphans
  
  # Fallback: explicitly stop by container name if compose down didn't work
  CONTAINER_NAME="wireguard-${PROFILE}"
  if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Container ${CONTAINER_NAME} still running, stopping directly..."
    docker stop "${CONTAINER_NAME}" 2>/dev/null || true
    docker rm "${CONTAINER_NAME}" 2>/dev/null || true
  fi
fi
