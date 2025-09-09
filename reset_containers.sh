#!/bin/bash
docker stop wireguard
docker container prune
docker volume prune
docker images | awk '{print $3}' | grep -v IMAGE | xargs docker image rm
