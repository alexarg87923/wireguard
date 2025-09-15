#!/bin/bash
docker stop wireguard
docker container prune
docker volume prune
docker images | awk '{print $3}' | grep -v IMAGE | xargs docker image rm

if [ -f "./config/*.conf" ]; then
    rm ./config/*.conf
fi

if [ -f "./keys/*-server" ]; then
    rm ./keys/*-server
fi

if [ -f "./keys/*-client" ]; then
    rm ./keys/*-client
fi