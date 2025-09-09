#!/bin/bash

PEER_PSK="/config/wg_confs/peer1.psk"

if [ ! -f "$PEER_PSK" ]; then
    wg genpsk > "$PEER_PSK"
fi

exec /init
