#!/bin/bash
docker stop wireguard
docker container prune
docker volume prune
docker images | awk '{print $3}' | grep -v IMAGE | xargs docker image rm

if [ -f "./config/*.conf" ]; then
    rm ./config/*.conf
fi

if [ -f "./config/*-server" ]; then
    rm ./config/*-server
fi

if [ -f "./config/*-client" ]; then
    rm ./config/*-client
fi