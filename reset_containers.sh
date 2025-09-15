#!/bin/bash
docker stop wireguard
docker container prune
docker volume prune
docker images | awk '{print $3}' | grep -v IMAGE | xargs docker image rm

if ls ./config/*.conf 1> /dev/null 2>&1; then
    rm ./config/*.conf
fi

if ls ./keys/*-server 1> /dev/null 2>&1; then
    rm ./keys/*-server
fi

if ls ./keys/*-client 1> /dev/null 2>&1; then
    rm ./keys/*-client
fi