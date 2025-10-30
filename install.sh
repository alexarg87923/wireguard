#!/bin/bash

echo "Removing commands if they exist"

rm ./start_container.sh
rm ./stop_container.sh
rm ./reset_container.sh

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

if ! docker start "wireguard-$PROFILE" 2>/dev/null; then # if we failed
  docker compose --profile ${PROFILE} up -d
fi
EOF

# create stop_container.sh
cat > stop_container.sh << 'EOF'
#!/bin/bash

docker compose down --remove-orphans
EOF

# create reset_container.sh
cat > reset_container.sh << 'EOF'
#!/bin/bash
./stop_container.sh

# prune containers and volumes
docker container prune -f
docker volume prune -f

# remove all images
docker images | awk '{print $3}' | grep -v IMAGE | xargs docker image rm

# clean up generated config files
rm -f ./wireguard/config/*.conf
rm -f ./wireguard/keys/*-server
rm -f ./wireguard/keys/*-client
rm -f .env
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

# only need to add execute permission
chmod +x start_container.sh stop_container.sh reset_container.sh gen_psk.sh gen_keys.sh

echo "Installation complete!"
echo "Available commands:"
echo "  ./start_container.sh  - Start the container"
echo "  ./stop_container.sh   - Stop the container"
echo "  ./reset_container.sh  - Complete reset"
echo "  ./gen_psk.sh <n>      - Generate PSK for peer n and update .env"
echo "  ./gen_keys.sh <role>  - Generate keypair for 'server' or 'client' and update .env"

# self distruct to remove attack vectors
rm -- "$0"