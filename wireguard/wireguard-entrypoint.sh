#!/bin/bash

KEY_DIR="/config/server"
CONFIG_DIR="/config/wg_confs"
TEMPLATE_DIR="/config/templates"

# MODE determined by PROFILE env passed via compose (server|client)
MODE=${PROFILE}

if [ "$MODE" = "client" ] || [ "$MODE" = "CLIENT" ]; then
  if [ -z "$CLIENT_IP" ] || [ -z "$CLIENT_ENDPOINT" ] || [ -z "$CLIENT_PORT" ] || [ -z "$ALLOWEDIPS" ] || [ -z "$SERVER_PUBLIC_KEY" ]; then
    echo "Missing required client env vars: CLIENT_IP, CLIENT_ENDPOINT, CLIENT_PORT, ALLOWEDIPS, SERVER_PUBLIC_KEY"
    exit 1
  fi

  # Dynamically detect CONTAINER_GATEWAY if not provided (Docker bridge gateway)
  if [ -z "$CONTAINER_GATEWAY" ]; then
    CONTAINER_GATEWAY=$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -n1)
    if [ -z "$CONTAINER_GATEWAY" ]; then
      # Fallback: extract from Docker network interface (more portable method)
      CONTAINER_GATEWAY=$(ip -4 addr show eth0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | sed 's/\.[0-9]*$/.1/')
    fi
    if [ -z "$CONTAINER_GATEWAY" ]; then
      echo "Warning: Could not auto-detect CONTAINER_GATEWAY. Please set it manually."
      exit 1
    fi
    echo "Auto-detected CONTAINER_GATEWAY: $CONTAINER_GATEWAY"
  fi

  # HOST_PUBLIC_IP should be provided by start_container.sh
  if [ -z "$HOST_PUBLIC_IP" ]; then
    echo "Error: HOST_PUBLIC_IP is not set. This should be detected automatically by start_container.sh"
    echo "If auto-detection fails, you can set it manually in .env or as an environment variable"
    exit 1
  fi

  # Client keys: prefer env-provided; else use existing files; else generate on first run
  if [ -n "${CLIENT_PRIVATE_KEY}" ]; then
      umask 077
      printf "%s" "$CLIENT_PRIVATE_KEY" > "$KEY_DIR/privatekey-client"
      if [ -n "${CLIENT_PUBLIC_KEY}" ]; then
          printf "%s" "$CLIENT_PUBLIC_KEY" > "$KEY_DIR/publickey-client"
      else
          wg pubkey < "$KEY_DIR/privatekey-client" > "$KEY_DIR/publickey-client"
      fi
  elif [ ! -f "$KEY_DIR/privatekey-client" ]; then
      echo "No client keypair found, generating..."
      umask 077
      wg genkey | tee "$KEY_DIR/privatekey-client" | wg pubkey > "$KEY_DIR/publickey-client"
  fi

  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_DIR/wg0.conf" <<EOF
[Interface]
Address = ${CLIENT_IP}
PrivateKey = $(cat ${KEY_DIR}/privatekey-client)

PostUp = iptables -t nat -A POSTROUTING -o %i -j MASQUERADE
PostUp = ip route add ${HOST_PUBLIC_IP} via ${CONTAINER_GATEWAY} dev eth0
PostUp = ip route add ${CLIENT_ENDPOINT} via ${CONTAINER_GATEWAY} dev eth0
PostUp = iptables -A FORWARD -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o %i -j SNAT --to-source ${CLIENT_IP%%/*}

PostDown = ip route del ${HOST_PUBLIC_IP} via ${CONTAINER_GATEWAY} dev eth0
PostDown = ip route del ${CLIENT_ENDPOINT} via ${CONTAINER_GATEWAY} dev eth0
PostDown = iptables -D FORWARD -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o %i -j SNAT --to-source ${CLIENT_IP%%/*}
PostDown = iptables -t nat -D POSTROUTING -o %i -j MASQUERADE

$( [ -n "${CLIENT_DNS}" ] && echo "DNS = ${CLIENT_DNS}" )

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
$( [ -n "${SERVER_PRESHARED_KEY}" ] && echo "PresharedKey = ${SERVER_PRESHARED_KEY}" )
Endpoint = ${CLIENT_ENDPOINT}:${CLIENT_PORT}
AllowedIPs = ${ALLOWEDIPS}
EOF
  echo "Generated client wg0.conf from env"
else
  # SERVER mode: generate template from env; support multiple peers with optional PSKs
  if [ -z "$INTERNAL_SUBNET" ]; then
    echo "Missing required server env var: INTERNAL_SUBNET"
    exit 1
  fi

  SERVER_PORT_VALUE=${SERVER_PORT:-51821}

  # Server keys: prefer env-provided; else use existing files; else generate on first run
  if [ -n "${SERVER_PRIVATE_KEY}" ]; then
      umask 077
      printf "%s" "$SERVER_PRIVATE_KEY" > "$KEY_DIR/privatekey-server"
      if [ -n "${SERVER_PUBLIC_KEY}" ]; then
          printf "%s" "$SERVER_PUBLIC_KEY" > "$KEY_DIR/publickey-server"
      else
          wg pubkey < "$KEY_DIR/privatekey-server" > "$KEY_DIR/publickey-server"
      fi
  elif [ ! -f "$KEY_DIR/privatekey-server" ]; then
      echo "No server keypair found, generating..."
      umask 077
      wg genkey | tee "$KEY_DIR/privatekey-server" | wg pubkey > "$KEY_DIR/publickey-server"
  fi

  mkdir -p "$TEMPLATE_DIR"
  cat > "$TEMPLATE_DIR/server.conf" <<EOF
[Interface]
Address = ${INTERNAL_SUBNET}
ListenPort = ${SERVER_PORT_VALUE}
PrivateKey = $(cat ${KEY_DIR}/privatekey-server)
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth+ -j MASQUERADE
EOF

  i=1
  generated=0
  while true; do
    PUB_KEY_VAR=PEER${i}_PUBLIC_KEY
    ALLOWED_VAR=PEER${i}_ALLOWED_IPS
    PSK_VAR=PEER${i}_PRESHARED_KEY

    PUB_KEY_VALUE=${!PUB_KEY_VAR}
    ALLOWED_VALUE=${!ALLOWED_VAR}
    PSK_VALUE=${!PSK_VAR}

    if [ -z "$PUB_KEY_VALUE" ]; then
      break
    fi
    if [ -z "$ALLOWED_VALUE" ]; then
      echo "Missing ${ALLOWED_VAR} for peer ${i}"
      exit 1
    fi

    {
      echo ""
      echo "[Peer]"
      echo "PublicKey = ${PUB_KEY_VALUE}"
      echo "AllowedIPs = ${ALLOWED_VALUE}"
      if [ -n "$PSK_VALUE" ]; then
        echo "PresharedKey = ${PSK_VALUE}"
      fi
    } >> "$TEMPLATE_DIR/server.conf"

    generated=$((generated+1))
    i=$((i+1))
  done

  # Strict gap check: ensure indices 1..max are all defined if any higher exists
  max_idx=$(env | grep -E '^PEER[0-9]+_PUBLIC_KEY=' | sed -E 's/^PEER([0-9]+)_PUBLIC_KEY=.*/\1/' | sort -n | tail -n 1)
  if [ -n "$max_idx" ]; then
    j=1
    while [ $j -le $max_idx ]; do
      test_var="PEER${j}_PUBLIC_KEY"
      test_val=${!test_var}
      if [ -z "$test_val" ]; then
        echo "Gap detected: ${test_var} is missing while higher peers exist (max index $max_idx)"
        exit 1
      fi
      j=$((j+1))
    done
  fi

  echo "Generated server template from env for ${generated} peers"
fi

exec /init
