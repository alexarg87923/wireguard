#!/bin/bash

KEY_DIR="/config/server"

# MODE determined by PROFILE env passed via compose (server|client)
MODE=${PROFILE}

if [ "$MODE" = "client" ] || [ "$MODE" = "CLIENT" ]; then
  if [ -z "$CLIENT_IP" ] || [ -z "$CLIENT_ENDPOINT" ] || [ -z "$CLIENT_PORT" ] || [ -z "$ALLOWEDIPS" ] || [ -z "$SERVER_PUBLIC_KEY" ]; then
    echo "Missing required client env vars: CLIENT_IP, CLIENT_ENDPOINT, CLIENT_PORT, ALLOWEDIPS, SERVER_PUBLIC_KEY"
    exit 1
  fi

  if [ ! -f "$KEY_DIR/privatekey-client" ]; then
      echo "No client keypair found, generating..."
      umask 077
      wg genkey | tee "$KEY_DIR/privatekey-client" | wg pubkey > "$KEY_DIR/publickey-client"
  fi

  cat > "/etc/wireguard/wg0.conf" <<EOF
[Interface]
Address = ${CLIENT_IP}
PrivateKey = $(cat ${KEY_DIR}/privatekey-client)
PostUp = iptables -t nat -A POSTROUTING -o %i -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o %i -j MASQUERADE
$( [ -n "${CLIENT_DNS}" ] && echo "DNS = ${CLIENT_DNS}" )

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = ${CLIENT_ENDPOINT}:${CLIENT_PORT}
AllowedIPs = ${ALLOWEDIPS}
EOF
  echo "Generated client wg0.conf from env"
else
  # SERVER mode: generate config from env; support multiple peers with optional PSKs
  if [ -z "$INTERNAL_SUBNET" ]; then
    echo "Missing required server env var: INTERNAL_SUBNET"
    exit 1
  fi

  SERVER_PORT_VALUE=${SERVER_PORT:-51821}

  cat > "/etc/wireguard/wg0.conf" <<EOF
[Interface]
Address = ${INTERNAL_SUBNET}
ListenPort = ${SERVER_PORT_VALUE}
PrivateKey = $(cat ${KEY_DIR}/privatekey-server)
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth+ -j MASQUERADE
EOF

  TOTAL_PEERS=${PEERS:-0}
  i=1
  while [ $i -le $TOTAL_PEERS ]; do
    PUB_KEY_VAR=PEER${i}_PUBLIC_KEY
    ALLOWED_VAR=PEER${i}_ALLOWED_IPS
    PSK_VAR=PEER${i}_PRESHARED_KEY

    PUB_KEY_VALUE=${!PUB_KEY_VAR}
    ALLOWED_VALUE=${!ALLOWED_VAR}
    PSK_VALUE=${!PSK_VAR}

    if [ -z "$PUB_KEY_VALUE" ] || [ -z "$ALLOWED_VALUE" ]; then
      echo "Missing ${PUB_KEY_VAR} or ${ALLOWED_VAR} for peer ${i}"
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
    } >> "/etc/wireguard/wg0.conf"

    i=$((i+1))
  done

  echo "Generated server wg0.conf from env for ${TOTAL_PEERS} peers"
fi

exec /init
