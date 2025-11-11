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

  # Resolve MinIO container IP using Docker network DNS (containers share the same network)
  # iptables requires an IP address, so we resolve the container name "minio" to its IP
  if [ -z "$MINIO_CONTAINER_IP" ]; then
    # Wait for MinIO container to be resolvable (with retries)
    echo "Waiting for MinIO container to be available..."
    max_attempts=30
    attempt=0
    MINIO_CONTAINER_IP=""
    
    while [ $attempt -lt $max_attempts ]; do
      MINIO_CONTAINER_IP=$(getent hosts minio 2>/dev/null | awk '{print $1}' | head -n1)
      if [ -n "$MINIO_CONTAINER_IP" ]; then
        echo "Resolved MinIO container IP: $MINIO_CONTAINER_IP (from hostname 'minio')"
        break
      fi
      attempt=$((attempt + 1))
      if [ $attempt -lt $max_attempts ]; then
        echo "Attempt $attempt/$max_attempts: MinIO not yet resolvable, waiting 2 seconds..."
        sleep 2
      fi
    done
    
    if [ -z "$MINIO_CONTAINER_IP" ]; then
      echo "Warning: Could not resolve MinIO container IP from hostname 'minio' after $max_attempts attempts."
      echo "MinIO DNAT rules will be skipped. Ensure MinIO container is running and on the same network."
      echo "You can set MINIO_CONTAINER_IP manually in .env if needed."
      MINIO_CONTAINER_IP=""
    fi
  else
    echo "Using manually configured MinIO container IP: $MINIO_CONTAINER_IP"
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

PostUp = iptables -t nat -A POSTROUTING -o eth0 -s 10.0.2.0/24 -d 172.17.0.0/16 -j RETURN
PostUp = iptables -t nat -A POSTROUTING -o eth0 -s 10.0.2.0/24 -d 172.18.0.0/16 -j RETURN
PostUp = iptables -t nat -A POSTROUTING -o eth0 -s 10.0.2.0/24 -j MASQUERADE

PostUp = ip route add ${HOST_PUBLIC_IP} via ${CONTAINER_GATEWAY} dev eth0 table 51820
PostUp = ip route add ${CLIENT_ENDPOINT} via ${CONTAINER_GATEWAY} dev eth0 table 51820
PostUp = ip route add 172.17.0.0/16 via ${CONTAINER_GATEWAY} dev eth0 table 51820
PostUp = iptables -A FORWARD -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o %i -m mark --mark 0xca6c -j SNAT --to-source ${CLIENT_IP%%/*}
PostUp = iptables -t nat -A PREROUTING -i %i -d ${CLIENT_IP%%/*} -p tcp --dport 22 -j DNAT --to-destination ${CONTAINER_GATEWAY}:22
PostUp = iptables -t nat -A PREROUTING -i %i -d ${CLIENT_IP%%/*} -p tcp --dport 3060 -j DNAT --to-destination ${CONTAINER_GATEWAY}:3060
$( [ -n "${MINIO_CONTAINER_IP}" ] && echo "PostUp = iptables -t nat -A PREROUTING -i %i -d ${CLIENT_IP%%/*} -p tcp --dport ${MINIO_WEB_PORT:-8080} -j DNAT --to-destination ${MINIO_CONTAINER_IP}:${MINIO_WEB_PORT:-8080}" )
$( [ -n "${MINIO_CONTAINER_IP}" ] && echo "PostUp = iptables -t nat -A PREROUTING -i %i -d ${CLIENT_IP%%/*} -p tcp --dport ${MINIO_CONSOLE_PORT:-4020} -j DNAT --to-destination ${MINIO_CONTAINER_IP}:${MINIO_CONSOLE_PORT:-4020}" )

$( [ -n "${MINIO_CONTAINER_IP}" ] && echo "PostDown = iptables -t nat -D PREROUTING -i %i -d ${CLIENT_IP%%/*} -p tcp --dport ${MINIO_CONSOLE_PORT:-4020} -j DNAT --to-destination ${MINIO_CONTAINER_IP}:${MINIO_CONSOLE_PORT:-4020}" )
$( [ -n "${MINIO_CONTAINER_IP}" ] && echo "PostDown = iptables -t nat -D PREROUTING -i %i -d ${CLIENT_IP%%/*} -p tcp --dport ${MINIO_WEB_PORT:-8080} -j DNAT --to-destination ${MINIO_CONTAINER_IP}:${MINIO_WEB_PORT:-8080}" )
PostDown = iptables -t nat -D PREROUTING -i %i -d ${CLIENT_IP%%/*} -p tcp --dport 3060 -j DNAT --to-destination ${CONTAINER_GATEWAY}:22
PostDown = iptables -t nat -D PREROUTING -i %i -d ${CLIENT_IP%%/*} -p tcp --dport 22 -j DNAT --to-destination ${CONTAINER_GATEWAY}:22
PostDown = iptables -t nat -D POSTROUTING -o %i -m mark --mark 0xca6c -j SNAT --to-source ${CLIENT_IP%%/*}
PostDown = iptables -D FORWARD -j ACCEPT
PostDown = ip route del 172.17.0.0/16 via ${CONTAINER_GATEWAY} dev eth0 table 51820
PostDown = ip route del ${CLIENT_ENDPOINT} via ${CONTAINER_GATEWAY} dev eth0 table 51820
PostDown = ip route del ${HOST_PUBLIC_IP} via ${CONTAINER_GATEWAY} dev eth0 table 51820

PostDown = iptables -t nat -D POSTROUTING -o eth0 -s 10.0.2.0/24 -d 172.17.0.0/16 -j RETURN
PostDown = iptables -t nat -D POSTROUTING -o eth0 -s 10.0.2.0/24 -d 172.18.0.0/16 -j RETURN
PostDown = iptables -t nat -D POSTROUTING -o eth0 -s 10.0.2.0/24 -j MASQUERADE

$( [ -n "${CLIENT_DNS}" ] && echo "DNS = ${CLIENT_DNS}" )

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
PersistentKeepalive = 25
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
