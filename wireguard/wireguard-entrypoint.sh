#!/bin/bash
set -x  # Enable debug mode to see all commands

KEY_DIR="/config/server"
CONFIG_DIR="/config/wg_confs"
TEMPLATE_DIR="/config/templates"
LOG_FILE="/config/entrypoint.log"

# Setup logging function that writes to both stderr and log file
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE" >&2
}

# Create log file
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# MODE determined by PROFILE env passed via compose (server|client)
MODE=${PROFILE}

log "=== WireGuard Entrypoint Script Starting ==="
log "MODE: $MODE"
log "PROFILE: $PROFILE"

if [ "$MODE" = "client" ] || [ "$MODE" = "CLIENT" ]; then
  log "Running in CLIENT mode..."
  if [ -z "$CLIENT_IP" ] || [ -z "$CLIENT_ENDPOINT" ] || [ -z "$CLIENT_PORT" ] || [ -z "$ALLOWEDIPS" ] || [ -z "$SERVER_PUBLIC_KEY" ]; then
    log "Missing required client env vars: CLIENT_IP, CLIENT_ENDPOINT, CLIENT_PORT, ALLOWEDIPS, SERVER_PUBLIC_KEY"
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
      log "Warning: Could not auto-detect CONTAINER_GATEWAY. Please set it manually."
      exit 1
    fi
    log "Auto-detected CONTAINER_GATEWAY: $CONTAINER_GATEWAY"
  fi

  # HOST_PUBLIC_IP should be provided by start_container.sh
  if [ -z "$HOST_PUBLIC_IP" ]; then
    log "Error: HOST_PUBLIC_IP is not set. This should be detected automatically by start_container.sh"
    log "If auto-detection fails, you can set it manually in .env or as an environment variable"
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
      log "No client keypair found, generating..."
      umask 077
      wg genkey | tee "$KEY_DIR/privatekey-client" | wg pubkey > "$KEY_DIR/publickey-client"
  fi

  LOCAL_VPN_IP="${CLIENT_IP%%/*}"
  VPN_PORT_DNAT_UP=""
  VPN_PORT_DNAT_DOWN=""
  OLD_IFS="$IFS"
  IFS=','
  for entry in ${VPN_ALLOW}; do
    entry=$(echo "$entry" | tr -d '[:space:]')
    [ -z "$entry" ] && continue
    dest="${entry%:*}"
    port="${entry##*:}"
    [ "$dest" != "$LOCAL_VPN_IP" ] && continue
    [ -z "$port" ] || [ "$port" = "$entry" ] && continue
    VPN_PORT_DNAT_UP="${VPN_PORT_DNAT_UP}PostUp = iptables -t nat -A PREROUTING -i %i -d ${LOCAL_VPN_IP} -p tcp --dport ${port} -j DNAT --to-destination ${CONTAINER_GATEWAY}:${port}
"
    VPN_PORT_DNAT_DOWN="${VPN_PORT_DNAT_DOWN}PostDown = iptables -t nat -D PREROUTING -i %i -d ${LOCAL_VPN_IP} -p tcp --dport ${port} -j DNAT --to-destination ${CONTAINER_GATEWAY}:${port}
"
  done
  IFS="$OLD_IFS"

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
PostUp = iptables -t nat -A POSTROUTING -o %i -j SNAT --to-source ${CLIENT_IP%%/*}
${VPN_PORT_DNAT_UP}${VPN_PORT_DNAT_DOWN}
PostDown = iptables -t nat -D POSTROUTING -o %i -j SNAT --to-source ${CLIENT_IP%%/*}
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
  log "Generated client wg0.conf from env"
else
  # SERVER mode: write templates/server.conf; /init generates wg0.conf from it
  if [ -z "$INTERNAL_SUBNET" ]; then
    log "Missing required server env var: INTERNAL_SUBNET"
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
      log "No server keypair found, generating..."
      umask 077
      wg genkey | tee "$KEY_DIR/privatekey-server" | wg pubkey > "$KEY_DIR/publickey-server"
  fi

  LOCAL_VPN_IP="${INTERNAL_SUBNET%%/*}"
  VPN_PORT_DNAT_UP=""
  VPN_PORT_DNAT_DOWN=""
  VPN_PEER_FWD_UP=""
  VPN_PEER_FWD_DOWN=""
  if [ -n "${VPN_ALLOW}" ]; then
    if [ -z "$CONTAINER_GATEWAY" ]; then
      CONTAINER_GATEWAY=$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -n1)
      if [ -z "$CONTAINER_GATEWAY" ]; then
        CONTAINER_GATEWAY=$(ip -4 addr show eth0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | sed 's/\.[0-9]*$/.1/')
      fi
      if [ -z "$CONTAINER_GATEWAY" ]; then
        log "Warning: Could not auto-detect CONTAINER_GATEWAY. Please set it manually."
        exit 1
      fi
      log "Auto-detected CONTAINER_GATEWAY: $CONTAINER_GATEWAY"
    fi
    OLD_IFS="$IFS"
    IFS=','
    for entry in ${VPN_ALLOW}; do
      entry=$(echo "$entry" | tr -d '[:space:]')
      [ -z "$entry" ] && continue
      dest="${entry%:*}"
      port="${entry##*:}"
      [ -z "$port" ] || [ "$port" = "$entry" ] && continue
      if [ "$dest" = "$LOCAL_VPN_IP" ]; then
        VPN_PORT_DNAT_UP="${VPN_PORT_DNAT_UP}PostUp = iptables -t nat -A PREROUTING -i %i -d ${LOCAL_VPN_IP} -p tcp --dport ${port} -j DNAT --to-destination ${CONTAINER_GATEWAY}:${port}
"
        VPN_PORT_DNAT_DOWN="${VPN_PORT_DNAT_DOWN}PostDown = iptables -t nat -D PREROUTING -i %i -d ${LOCAL_VPN_IP} -p tcp --dport ${port} -j DNAT --to-destination ${CONTAINER_GATEWAY}:${port}
"
      else
        VPN_PEER_FWD_UP="${VPN_PEER_FWD_UP}PostUp = iptables -A FORWARD -i %i -d ${dest} -p tcp --dport ${port} -j ACCEPT
"
        VPN_PEER_FWD_DOWN="${VPN_PEER_FWD_DOWN}PostDown = iptables -D FORWARD -i %i -d ${dest} -p tcp --dport ${port} -j ACCEPT
"
      fi
    done
    IFS="$OLD_IFS"
  fi

  mkdir -p "$TEMPLATE_DIR"
  cat > "$TEMPLATE_DIR/server.conf" <<EOF
[Interface]
Address = ${INTERNAL_SUBNET}
ListenPort = ${SERVER_PORT_VALUE}
PrivateKey = $(cat ${KEY_DIR}/privatekey-server)
PostUp = iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostUp = iptables -A FORWARD -i %i -o eth+ -j ACCEPT
PostUp = iptables -A FORWARD -i eth+ -o %i -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o eth+ -s 10.0.2.0/24 -d 172.16.0.0/12 -j RETURN
PostUp = iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE
PostUp = iptables -t nat -A POSTROUTING -o %i ! -s 10.0.2.0/24 -j SNAT --to-source ${INTERNAL_SUBNET%%/*}
${VPN_PEER_FWD_UP}${VPN_PORT_DNAT_UP}${VPN_PORT_DNAT_DOWN}${VPN_PEER_FWD_DOWN}
PostDown = iptables -t nat -D POSTROUTING -o %i ! -s 10.0.2.0/24 -j SNAT --to-source ${INTERNAL_SUBNET%%/*}
PostDown = iptables -t nat -D POSTROUTING -o eth+ -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o eth+ -s 10.0.2.0/24 -d 172.16.0.0/12 -j RETURN
PostDown = iptables -D FORWARD -i eth+ -o %i -j ACCEPT
PostDown = iptables -D FORWARD -i %i -o eth+ -j ACCEPT
PostDown = iptables -D FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
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
      log "Missing ${ALLOWED_VAR} for peer ${i}"
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
        log "Gap detected: ${test_var} is missing while higher peers exist (max index $max_idx)"
        exit 1
      fi
      j=$((j+1))
    done
  fi

  log "Generated server template from env for ${generated} peers"
  mkdir -p "$CONFIG_DIR"
  cp "$TEMPLATE_DIR/server.conf" "$CONFIG_DIR/wg0.conf"
fi

exec /init
