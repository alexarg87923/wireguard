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
