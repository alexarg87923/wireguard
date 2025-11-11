#!/bin/bash

echo "Removing commands if they exist"

rm ./start_container.sh
rm ./stop_container.sh
rm ./reset_container.sh
rm ./gen_psk.sh
rm ./gen_keys.sh
rm ./setup_host_routing.sh
rm ./remove_host_routing.sh
rm ./setup_minio.sh

echo "Installing WireGuard container management scripts..."

# set umask so all created files/dirs are owner-only
umask 077

# create directories
mkdir -p wireguard/config wireguard/keys
mkdir -p bin

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

  # Setup MinIO buckets automatically
  if [ -f "./setup_minio.sh" ]; then
    echo "Setting up MinIO buckets..."
    ./setup_minio.sh
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
sudo docker images | awk '{print $2}' | grep -v "ID" | grep -v "\->" | xargs sudo docker image rm || true
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
iptables -A INPUT -s ${CLIENT_SUBNET} -p tcp --dport ${SSH_PORT:-22} -j ACCEPT -m comment --comment "SSH"
iptables -A INPUT -s ${CLIENT_SUBNET} -p tcp --dport ${MINIO_WEB_PORT:-8080} -j ACCEPT -m comment --comment "MinIO-Web"
iptables -A INPUT -s ${CLIENT_SUBNET} -p tcp --dport ${MINIO_CONSOLE_PORT:-4020} -j ACCEPT -m comment --comment "MinIO-Console"
iptables -A INPUT -s ${CLIENT_SUBNET} -p tcp --dport ${BACKEND_PORT:-3060} -j ACCEPT -m comment --comment "Backend"

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

# Remove iptables rules by comment (SSH, MinIO, Backend)
# Remove rules by trying to delete them directly if CLIENT_SUBNET is available
if [ -n "${CLIENT_SUBNET:-}" ]; then
  # Remove SSH rule (use port from env or default)
  iptables -D INPUT -s "${CLIENT_SUBNET}" -p tcp --dport ${SSH_PORT:-22} -j ACCEPT -m comment --comment "SSH" 2>/dev/null || true

  # Remove MinIO Web rule (use port from env or default)
  iptables -D INPUT -s "${CLIENT_SUBNET}" -p tcp --dport ${MINIO_WEB_PORT:-8080} -j ACCEPT -m comment --comment "MinIO-Web" 2>/dev/null || true

  # Remove MinIO Console rule (use port from env or default)
  iptables -D INPUT -s "${CLIENT_SUBNET}" -p tcp --dport ${MINIO_CONSOLE_PORT:-4020} -j ACCEPT -m comment --comment "MinIO-Console" 2>/dev/null || true

  # Remove Backend rule (use port from env or default)
  iptables -D INPUT -s "${CLIENT_SUBNET}" -p tcp --dport ${BACKEND_PORT:-3060} -j ACCEPT -m comment --comment "Backend" 2>/dev/null || true
fi

# Fallback: Remove rules by finding them via comment using iptables -S
# This handles cases where CLIENT_SUBNET is not available or rules don't match exactly
for comment in "SSH" "MinIO-Web" "MinIO-Console" "Backend"; do
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

# create setup_minio.sh
cat > setup_minio.sh << 'EOF'
#!/bin/bash

# Script to set up MinIO buckets and permissions after container starts
# This script should be run after the MinIO container is up and running

set -euo pipefail

# Load .env to get MinIO credentials and bucket names
ENV_FILE=./.env
if [ -f "$ENV_FILE" ]; then
  set -o allexport
  source "$ENV_FILE"
  set +o allexport
fi

# Set defaults if not specified
MINIO_ROOT_USER="${MINIO_ROOT_USER:-admin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-miniopassword}"
MINIO_PUBLIC_BUCKETS="${MINIO_PUBLIC_BUCKETS:-public}"
MINIO_WEB_PORT="${MINIO_WEB_PORT:-8080}"
MINIO_CONSOLE_PORT="${MINIO_CONSOLE_PORT:-4020}"
MINIO_ENDPOINT="http://localhost:${MINIO_WEB_PORT}"

# Check if MinIO container is running
if ! docker ps --format '{{.Names}}' | grep -q "^minio$"; then
  echo "Error: MinIO container is not running. Start it first with ./start_container.sh"
  exit 1
fi

echo "Waiting for MinIO to be ready..."
max_attempts=30
attempt=0
while [ $attempt -lt $max_attempts ]; do
  if curl -sf "${MINIO_ENDPOINT}/minio/health/live" > /dev/null 2>&1; then
    echo "MinIO is ready!"
    break
  fi
  attempt=$((attempt + 1))
  sleep 1
done

if [ $attempt -eq $max_attempts ]; then
  echo "Error: MinIO did not become ready in time"
  exit 1
fi

echo "Setting up MinIO configuration..."

# Find the network that the MinIO container is connected to
# Docker Compose may prefix the network name, so we need to detect it
MINIO_NETWORK=$(docker inspect minio --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}{{end}}' 2>/dev/null | grep -i wireguard | head -n1)

if [ -z "$MINIO_NETWORK" ]; then
  # Fallback: try to get any network the container is on
  MINIO_NETWORK=$(docker inspect minio --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}{{end}}' 2>/dev/null | head -n1)
fi

if [ -z "$MINIO_NETWORK" ]; then
  echo "Error: Could not detect MinIO container network. Is the MinIO container running?"
  exit 1
fi

echo "Using network: $MINIO_NETWORK"

# Connect to MinIO container via Docker network (cleaner than --network host)
MINIO_INTERNAL_ENDPOINT="http://minio:${MINIO_WEB_PORT}"
docker run --rm --network "${MINIO_NETWORK}" \
  --entrypoint /bin/sh \
  minio/mc:latest \
  -c "
    mc alias set myminio ${MINIO_INTERNAL_ENDPOINT} ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD} && \
    echo 'MinIO alias configured successfully' && \

    # Create and configure each bucket
    IFS=',' read -ra BUCKETS <<< '${MINIO_PUBLIC_BUCKETS}' && \
    for bucket in \"\${BUCKETS[@]}\"; do
      # Remove leading spaces
      while [ \"\${bucket# }\" != \"\$bucket\" ]; do bucket=\${bucket# }; done
      # Remove trailing spaces  
      while [ \"\${bucket% }\" != \"\$bucket\" ]; do bucket=\${bucket% }; done
      if [ -n \"\$bucket\" ]; then
        echo \"Creating bucket: \$bucket\" && \
        mc mb myminio/\$bucket --ignore-existing && \
        echo \"Setting public read policy on bucket: \$bucket\" && \
        mc anonymous set download myminio/\$bucket && \
        echo \"Bucket \$bucket is now publicly accessible for downloads\"
      fi
    done && \

    echo '' && \
    echo 'MinIO setup complete!' && \
    echo 'Created public buckets: ${MINIO_PUBLIC_BUCKETS}' && \
    echo '' && \
    echo 'Access MinIO:' && \
    echo '  Web UI (Console): http://localhost:${MINIO_CONSOLE_PORT}' && \
    echo '  API Endpoint: ${MINIO_ENDPOINT}' && \
    echo '  Username: ${MINIO_ROOT_USER}' && \
    echo '  Password: [hidden]'
  "

if [ $? -eq 0 ]; then
  echo ""
  echo "MinIO buckets configured successfully!"
else
  echo ""
  echo "Error: Failed to configure MinIO buckets"
  exit 1
fi
EOF

# create minio-upload.sh in bin directory
cat > bin/minio-upload.sh << 'EOF'
#!/bin/bash

# Script to upload a file to a MinIO bucket from the host
# Usage: minio-upload.sh <bucket> <local-file> [remote-path]
# Example: minio-upload.sh public myfile.txt uploads/myfile.txt

set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "Usage: $0 <bucket> <local-file> [remote-path]" >&2
  echo "  bucket:      MinIO bucket name" >&2
  echo "  local-file:  Path to local file to upload" >&2
  echo "  remote-path: Optional remote path in bucket (defaults to filename)" >&2
  exit 1
fi

BUCKET="$1"
LOCAL_FILE="$2"
REMOTE_PATH="${3:-$(basename "$LOCAL_FILE")}"

# Get the directory where this script is located (wireguard directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "Error: .env file not found at $ENV_FILE" >&2
  exit 1
fi

# Load environment variables
set -o allexport
source "$ENV_FILE"
set +o allexport

# Set defaults
MINIO_ROOT_USER="${MINIO_ROOT_USER:-admin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-miniopassword}"
MINIO_WEB_PORT="${MINIO_WEB_PORT:-8080}"
MINIO_ENDPOINT="http://localhost:${MINIO_WEB_PORT}"

# Check if MinIO container is running
if ! docker ps --format '{{.Names}}' | grep -q "^minio$"; then
  echo "Error: MinIO container is not running. Start it first with ./start_container.sh" >&2
  exit 1
fi

# Check if local file exists
if [ ! -f "$LOCAL_FILE" ]; then
  echo "Error: Local file not found: $LOCAL_FILE" >&2
  exit 1
fi

# Get absolute path of local file
if [ "$(dirname "$LOCAL_FILE")" = "." ] || [ "$(dirname "$LOCAL_FILE")" = "" ]; then
  # Just a filename, use current directory
  LOCAL_FILE_ABS="$(pwd)/$(basename "$LOCAL_FILE")"
else
  # Has a directory component
  LOCAL_FILE_ABS="$(cd "$(dirname "$LOCAL_FILE")" && pwd)/$(basename "$LOCAL_FILE")"
fi

# Find the network that the MinIO container is connected to
MINIO_NETWORK=$(docker inspect minio --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}{{end}}' 2>/dev/null | grep -i wireguard | head -n1)

if [ -z "$MINIO_NETWORK" ]; then
  MINIO_NETWORK=$(docker inspect minio --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}{{end}}' 2>/dev/null | head -n1)
fi

if [ -z "$MINIO_NETWORK" ]; then
  echo "Error: Could not detect MinIO container network" >&2
  exit 1
fi

# Connect to MinIO container via Docker network
MINIO_INTERNAL_ENDPOINT="http://minio:${MINIO_WEB_PORT}"

echo "Uploading $LOCAL_FILE to bucket '$BUCKET' as '$REMOTE_PATH'..."

docker run --rm --network "${MINIO_NETWORK}" \
  -v "${LOCAL_FILE_ABS}:/tmp/upload_file" \
  --entrypoint /bin/sh \
  minio/mc:latest \
  -c "
    mc alias set myminio ${MINIO_INTERNAL_ENDPOINT} ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD} && \
    mc cp /tmp/upload_file myminio/${BUCKET}/${REMOTE_PATH} && \
    echo 'Upload successful!' && \
    echo "File available at: ${MINIO_ENDPOINT}/${BUCKET}/${REMOTE_PATH}"
  "

if [ $? -eq 0 ]; then
  echo ""
  echo "Upload complete: ${MINIO_ENDPOINT}/${BUCKET}/${REMOTE_PATH}"
else
  echo ""
  echo "Error: Upload failed" >&2
  exit 1
fi
EOF

# create minio-download.sh in bin directory
cat > bin/minio-download.sh << 'EOF'
#!/bin/bash

# Script to download a file from a MinIO bucket to the host
# Usage: minio-download.sh <bucket> <remote-path> [local-file]
# Example: minio-download.sh public uploads/myfile.txt myfile.txt

set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "Usage: $0 <bucket> <remote-path> [local-file]" >&2
  echo "  bucket:      MinIO bucket name" >&2
  echo "  remote-path: Path to file in bucket" >&2
  echo "  local-file:  Optional local destination path (defaults to filename)" >&2
  exit 1
fi

BUCKET="$1"
REMOTE_PATH="$2"
LOCAL_FILE="${3:-$(basename "$REMOTE_PATH")}"

# Get the directory where this script is located (wireguard directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "Error: .env file not found at $ENV_FILE" >&2
  exit 1
fi

# Load environment variables
set -o allexport
source "$ENV_FILE"
set +o allexport

# Set defaults
MINIO_ROOT_USER="${MINIO_ROOT_USER:-admin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-miniopassword}"
MINIO_WEB_PORT="${MINIO_WEB_PORT:-8080}"
MINIO_ENDPOINT="http://localhost:${MINIO_WEB_PORT}"

# Check if MinIO container is running
if ! docker ps --format '{{.Names}}' | grep -q "^minio$"; then
  echo "Error: MinIO container is not running. Start it first with ./start_container.sh" >&2
  exit 1
fi

# Get absolute path of local file (create directory if needed)
if [ "$(dirname "$LOCAL_FILE")" = "." ] || [ "$(dirname "$LOCAL_FILE")" = "" ]; then
  # Just a filename, use current directory
  LOCAL_FILE_ABS="$(pwd)/$(basename "$LOCAL_FILE")"
else
  # Has a directory component
  LOCAL_DIR="$(cd "$(dirname "$LOCAL_FILE")" 2>/dev/null && pwd || pwd)"
  LOCAL_FILE_ABS="${LOCAL_DIR}/$(basename "$LOCAL_FILE")"
  # Create directory if it doesn't exist
  mkdir -p "$(dirname "$LOCAL_FILE_ABS")"
fi

# Find the network that the MinIO container is connected to
MINIO_NETWORK=$(docker inspect minio --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}{{end}}' 2>/dev/null | grep -i wireguard | head -n1)

if [ -z "$MINIO_NETWORK" ]; then
  MINIO_NETWORK=$(docker inspect minio --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}{{end}}' 2>/dev/null | head -n1)
fi

if [ -z "$MINIO_NETWORK" ]; then
  echo "Error: Could not detect MinIO container network" >&2
  exit 1
fi

# Connect to MinIO container via Docker network
MINIO_INTERNAL_ENDPOINT="http://minio:${MINIO_WEB_PORT}"

echo "Downloading from bucket '$BUCKET': '$REMOTE_PATH'..."
echo "Saving to: $LOCAL_FILE_ABS"

docker run --rm --network "${MINIO_NETWORK}" \
  -v "$(dirname "$LOCAL_FILE_ABS"):/tmp/download_dir" \
  --entrypoint /bin/sh \
  minio/mc:latest \
  -c "
    mc alias set myminio ${MINIO_INTERNAL_ENDPOINT} ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD} && \
    mc cp myminio/${BUCKET}/${REMOTE_PATH} /tmp/download_dir/$(basename "$LOCAL_FILE_ABS") && \
    echo 'Download successful!'
  "

if [ $? -eq 0 ]; then
  echo ""
  echo "Download complete: $LOCAL_FILE_ABS"
else
  echo ""
  echo "Error: Download failed" >&2
  exit 1
fi
EOF

# only need to add execute permission
chmod +x start_container.sh stop_container.sh reset_container.sh gen_psk.sh gen_keys.sh setup_host_routing.sh remove_host_routing.sh setup_minio.sh
chmod +x bin/minio-upload.sh bin/minio-download.sh

# Add bin directory to PATH
BIN_DIR="$(pwd)/bin"
SHELL_RC=""

# Detect shell and appropriate rc file
if [ -n "${ZSH_VERSION:-}" ]; then
  SHELL_RC="$HOME/.zshrc"
elif [ -n "${BASH_VERSION:-}" ]; then
  SHELL_RC="$HOME/.bashrc"
else
  # Try to detect from $SHELL
  case "$SHELL" in
    *zsh) SHELL_RC="$HOME/.zshrc" ;;
    *) SHELL_RC="$HOME/.bashrc" ;;
  esac
fi

# Add to PATH if not already present
if [ -f "$SHELL_RC" ]; then
  if ! grep -q "# WireGuard bin directory" "$SHELL_RC" 2>/dev/null; then
    echo "" >> "$SHELL_RC"
    echo "# WireGuard bin directory" >> "$SHELL_RC"
    echo "export PATH=\"\$PATH:${BIN_DIR}\"" >> "$SHELL_RC"
    echo "Added ${BIN_DIR} to PATH in $SHELL_RC"
    echo "Run 'source $SHELL_RC' or restart your terminal to use the commands globally"
  else
    echo "PATH already configured in $SHELL_RC"
  fi
else
  echo "Warning: Could not find shell rc file ($SHELL_RC)"
  echo "Please manually add the following to your shell configuration:"
  echo "  export PATH=\"\$PATH:${BIN_DIR}\""
fi

echo "Installation complete!"
echo "Available commands:"
echo "  ./start_container.sh           - Start the container"
echo "  ./stop_container.sh            - Stop the container"
echo "  ./reset_container.sh           - Complete reset"
echo "  ./gen_psk.sh <n>               - Generate PSK for peer n and update .env"
echo "  ./gen_keys.sh <role>           - Generate keypair for 'server' or 'client' and update .env"
echo "  sudo ./setup_host_routing.sh   - Set up host routing rules (client only, requires root)"
echo "  sudo ./remove_host_routing.sh  - Remove host routing rules (requires root)"
echo "  ./setup_minio.sh               - Set up MinIO buckets (client only, auto-run by start_container.sh)"
echo ""
echo "Global MinIO commands (after sourcing shell rc):"
echo "  minio-upload.sh <bucket> <local-file> [remote-path]   - Upload file to MinIO bucket"
echo "  minio-download.sh <bucket> <remote-path> [local-file] - Download file from MinIO bucket"

# self distruct to remove attack vectors
rm -- "$0"