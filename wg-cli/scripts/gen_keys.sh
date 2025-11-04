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
