#!/bin/bash

echo "Removing commands if they exist"

rm ./start_container.sh
rm ./stop_container.sh
rm ./reset_container.sh
rm ./gen_psk.sh
rm ./gen_keys.sh
rm ./setup_host_routing.sh
rm ./remove_host_routing.sh

echo "Installing WireGuard container management scripts..."

# set umask so all created files/dirs are owner-only
umask 077

# create directories
mkdir -p wireguard/config wireguard/keys

# create start_container.sh
cat > start_container.sh << 'EOF'
#!/bin/bash

ENV_FILE=./.env

if [ ! -f "$ENV_FILE" ]; then
  echo "Error: .env file not found. Create it (e.g. copy .env.EXAMPLE) and configure."
  exit 1
fi

# Load environment variables from .env
set -o allexport
source "$ENV_FILE"
set +o allexport

if [ -z "$PROFILE" ]; then
  echo "Error: PROFILE is not set in .env"
  exit 1
fi

if [ "$PROFILE" = "client" ] && [ -z "$ALLOWEDIPS" ]; then
  echo "Error: ALLOWEDIPS is not set in .env (required for client profile)"
  exit 1
fi

# Auto-detect HOST_PUBLIC_IP if not set (for client profile)
if [ "$PROFILE" = "client" ] && [ -z "$HOST_PUBLIC_IP" ]; then
  echo "Detecting host public IP..."
  HOST_PUBLIC_IP=$(curl -s --max-time 3 ifconfig.me 2>/dev/null || curl -s --max-time 3 ip.pi 2>/dev/null || curl -s --max-time 3 ipinfo.io/ip 2>/dev/null || echo "")
  if [ -z "$HOST_PUBLIC_IP" ] || [[ ! "$HOST_PUBLIC_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "Warning: Could not auto-detect HOST_PUBLIC_IP. Please set it manually in .env"
    echo "You can find it with: curl ifconfig.me"
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

# Setup host routing rules for client profile (requires root/sudo)
# Do this AFTER container is running so we can detect its IP and network
if [ "$PROFILE" = "client" ]; then
  echo "Detected client profile, removing emergency access rule if it exists..."
  iptables -D INPUT -p tcp --dport 22 -s ${CLIENT_ENDPOINT} -j ACCEPT -m comment --comment "Emergency Access"

  if [ -f "./setup_host_routing.sh" ]; then
    echo "Invoking setup_host_routing.sh..."
    if [ "$EUID" -ne 0 ]; then
      sudo ./setup_host_routing.sh
    else
      ./setup_host_routing.sh
    fi
  fi
fi
EOF

# create stop_container.sh
cat > stop_container.sh << 'EOF'
#!/bin/bash

ENV_FILE=./.env

# Load .env to check PROFILE if available
if [ -f "$ENV_FILE" ]; then
  set -o allexport
  source "$ENV_FILE"
  set +o allexport
fi

if [ "${PROFILE:-}" = "client" ]; then
  echo "Detected client profile, adding emergency access rule..."
  iptables -A INPUT -p tcp --dport 22 -s ${CLIENT_ENDPOINT} -j ACCEPT -m comment --comment "Emergency Access"

  if [ -f "./remove_host_routing.sh" ]; then
    echo "Invoking remove_host_routing.sh..."
    if [ "$EUID" -ne 0 ]; then
      sudo ./remove_host_routing.sh
    else
      ./remove_host_routing.sh
    fi
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
EOF

# create reset_container.sh
cat > reset_container.sh << 'EOF'
#!/bin/bash
echo "Resetting container..."

echo "Checking if stop_container.sh exists..."
if [ -f "./stop_container.sh" ]; then
  echo "Executing stop_container.sh..."
  ./stop_container.sh
fi

echo "Pruning containers and volumes..."
docker container prune -f || true
docker volume prune -f || true

echo "Removing all images..."
docker images | awk '{print $3}' | grep -v IMAGE | xargs docker image rm || true
EOF

# create gen_psk.sh
cat > gen_psk.sh << 'EOF'
#!/bin/bash

# Usage: ./gen_psk.sh 1            # generates PSK for peer 1 and writes PEER1_PRESHARED_KEY in .env

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <peer_index>" >&2
  exit 1
fi

PEER_INDEX="$1"

if ! [[ "$PEER_INDEX" =~ ^[0-9]+$ ]] || [ "$PEER_INDEX" -le 0 ]; then
  echo "Error: peer_index must be a positive integer" >&2
  exit 1
fi

if [ ! -f ./.env ]; then
  echo "Error: .env not found in project root" >&2
  exit 1
fi

echo "Generating preshared key using Alpine (no special caps required)..."
PSK=$(docker run --rm alpine:3 sh -c 'head -c 32 /dev/urandom | base64' | tr -d '\r')

KEY="PEER${PEER_INDEX}_PRESHARED_KEY"

# Update or append KEY in .env safely (portable):
TMP_FILE=".env.tmp.$$"
FOUND=0
while IFS= read -r line; do
  if [ "$FOUND" -eq 0 ] && echo "$line" | grep -E -q "^${KEY}="; then
    echo "${KEY}=${PSK}" >> "$TMP_FILE"
    FOUND=1
  else
    echo "$line" >> "$TMP_FILE"
  fi
done < ./.env

if [ "$FOUND" -eq 0 ]; then
  echo "${KEY}=${PSK}" >> "$TMP_FILE"
fi

mv "$TMP_FILE" ./.env

echo "Wrote ${KEY} to .env"
echo "$PSK"
EOF

# create gen_keys.sh
cat > gen_keys.sh << 'EOF'
#!/bin/bash

# Usage:
#   ./gen_keys.sh server   # sets SERVER_PRIVATE_KEY and SERVER_PUBLIC_KEY in .env
#   ./gen_keys.sh client   # sets CLIENT_PRIVATE_KEY and CLIENT_PUBLIC_KEY in .env

set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <server|client>" >&2
  exit 1
fi

ROLE="$1"
case "$ROLE" in
  server|client) ;;
  *) echo "Error: role must be 'server' or 'client'" >&2; exit 1;;
esac

if [ ! -f ./.env ]; then
  echo "Error: .env not found in project root" >&2
  exit 1
fi

echo "Generating ${ROLE} keypair using Alpine (no special caps required)..."
read -r PRIV PUB <<EOF2
$(docker run --rm alpine:3 sh -c 'apk add --no-cache wireguard-tools >/dev/null 2>&1 && umask 077 && PRIV=$(wg genkey) && PUB=$(printf "%s" "$PRIV" | wg pubkey) && printf "%s %s" "$PRIV" "$PUB"')
EOF2

if [ -z "${PRIV:-}" ] || [ -z "${PUB:-}" ]; then
  echo "Error: failed to generate keypair" >&2
  exit 1
fi

if [ "$ROLE" = "server" ]; then
  PRIV_KEY="SERVER_PRIVATE_KEY"
  PUB_KEY="SERVER_PUBLIC_KEY"
else
  PRIV_KEY="CLIENT_PRIVATE_KEY"
  PUB_KEY="CLIENT_PUBLIC_KEY"
fi

TMP_FILE=".env.tmp.$$"
PRIV_DONE=0
PUB_DONE=0
while IFS= read -r line; do
  if [ $PRIV_DONE -eq 0 ] && echo "$line" | grep -E -q "^${PRIV_KEY}="; then
    echo "${PRIV_KEY}=${PRIV}" >> "$TMP_FILE"; PRIV_DONE=1
  elif [ $PUB_DONE -eq 0 ] && echo "$line" | grep -E -q "^${PUB_KEY}="; then
    echo "${PUB_KEY}=${PUB}" >> "$TMP_FILE"; PUB_DONE=1
  else
    echo "$line" >> "$TMP_FILE"
  fi
done < ./.env

[ $PRIV_DONE -eq 1 ] || echo "${PRIV_KEY}=${PRIV}" >> "$TMP_FILE"
[ $PUB_DONE -eq 1 ] || echo "${PUB_KEY}=${PUB}" >> "$TMP_FILE"

mv "$TMP_FILE" ./.env

echo "Wrote ${PRIV_KEY} and ${PUB_KEY} to .env"
echo "Private: $PRIV"
echo "Public:  $PUB"
EOF

# create setup_host_routing.sh
cat > setup_host_routing.sh << 'EOF'
#!/bin/bash

# Script to set up iptables rules on host to route traffic through WireGuard container
# This is only needed for client profile

set -euo pipefail

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
  echo "Error: This script must be run as root (use sudo)"
  exit 1
fi

# Load .env to get PROFILE
ENV_FILE=./.env
if [ -f "$ENV_FILE" ]; then
  set -o allexport
  source "$ENV_FILE"
  set +o allexport
fi

if [ "$PROFILE" != "client" ]; then
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

# Clean up any existing rules first (idempotent)
./remove_host_routing.sh 2>/dev/null || true

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
echo "Adding iptables rules..."
iptables -A INPUT -s ${CLIENT_SUBNET} -p tcp --dport 22 -j ACCEPT -m comment --comment "SSH"
iptables -A INPUT -s ${CLIENT_SUBNET} -p tcp --dport 8080 -j ACCEPT -m comment --comment "Web"
iptables -A INPUT -s ${CLIENT_SUBNET} -p tcp --dport 4020 -j ACCEPT -m comment --comment "Backend"

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
EOF

# create remove_host_routing.sh
cat > remove_host_routing.sh << 'EOF'
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

# Remove VPN iptables rules
echo "Removing VPN iptables rules..."

# Remove iptables rules by comment (SSH, Web, Backend)
# Remove rules by trying to delete them directly if CLIENT_SUBNET is available
if [ -n "${CLIENT_SUBNET:-}" ]; then
  # Remove SSH rule (port 22)
  iptables -D INPUT -s "${CLIENT_SUBNET}" -p tcp --dport 22 -j ACCEPT -m comment --comment "SSH" 2>/dev/null || true
  
  # Remove Web rule (port 8080)
  iptables -D INPUT -s "${CLIENT_SUBNET}" -p tcp --dport 8080 -j ACCEPT -m comment --comment "Web" 2>/dev/null || true
  
  # Remove Backend rule (port 4020)
  iptables -D INPUT -s "${CLIENT_SUBNET}" -p tcp --dport 4020 -j ACCEPT -m comment --comment "Backend" 2>/dev/null || true
fi

# Fallback: Remove rules by finding them via comment using iptables -S
# This handles cases where CLIENT_SUBNET is not available or rules don't match exactly
for comment in "SSH" "Web" "Backend"; do
  # Use iptables -S to find rules with matching comments and delete them
  # iptables -S outputs rules in a format that can be converted to delete commands
  iptables -S INPUT 2>/dev/null | grep -- "--comment \"${comment}\"" | while read rule; do
    if [ -n "$rule" ]; then
      # Convert -A to -D and execute
      delete_rule=$(echo "$rule" | sed 's/^-A/-D/')
      eval "iptables $delete_rule" 2>/dev/null || true
    fi
  done || true
done

echo "Host routing rules removed!"
EOF

# only need to add execute permission
chmod +x start_container.sh stop_container.sh reset_container.sh gen_psk.sh gen_keys.sh setup_host_routing.sh remove_host_routing.sh

echo "Installation complete!"
echo "Available commands:"
echo "  ./start_container.sh           - Start the container"
echo "  ./stop_container.sh            - Stop the container"
echo "  ./reset_container.sh           - Complete reset"
echo "  ./gen_psk.sh <n>               - Generate PSK for peer n and update .env"
echo "  ./gen_keys.sh <role>           - Generate keypair for 'server' or 'client' and update .env"
echo "  sudo ./setup_host_routing.sh   - Set up host routing rules (client only, requires root)"
echo "  sudo ./remove_host_routing.sh  - Remove host routing rules (requires root)"

# self distruct to remove attack vectors
rm -- "$0"