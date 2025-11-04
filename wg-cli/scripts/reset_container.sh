#!/bin/bash
./stop_container.sh

# prune containers and volumes
docker container prune -f
docker volume prune -f

# remove all images
docker images | awk '{print $3}' | grep -v IMAGE | xargs docker image rm

# clean up generated config files
rm -f ./wireguard/config/*.conf
rm -f ./wireguard/keys/*-server
rm -f ./wireguard/keys/*-client
