#!/bin/bash

echo "Installing WireGuard container management scripts..."

# set umask so all created files/dirs are owner-only
umask 077

# create directories
mkdir -p wireguard/config wireguard/keys

# create start_container.sh
cat > start_container.sh << 'EOF'
#!/bin/bash

ENDPOINT_FILE=./wireguard/config/endpoint

if [ -f $ENDPOINT_FILE ]; then
  PROFILE="client"
else
  PROFILE="server"
fi

ENV_FILE=./.env

if [ ! -f $ENV_FILE ]; then # check if we don't have a .env file, if we don't then generate one
  echo "Generating .env file..."
  
  echo "PROFILE=$PROFILE" > .env
  
  # add allowedips since it is profile agnostic
  if [ -f ./wireguard/config/allowed_ips ]; then
    echo "ALLOWEDIPS=$(cat ./wireguard/config/allowed_ips)" >> .env
  else
    echo "Error: ./wireguard/config/allowed_ips file not found!"
    exit 1
  fi
    
  if [ $PROFILE == "server" ]; then
    echo "Detected server mode (endpoint not found)"
    echo "PEERS=0" >> .env # if theres an endpoint file then we are in server mode so add a server-specific env var
  else
    echo "Detected client mode (endpoint found)"
    
  fi
fi

if ! docker start "wireguard-$PROFILE" 2>/dev/null; then # if we failed
  docker-compose --profile ${PROFILE} up
fi
EOF

# create stop_container.sh
cat > stop_container.sh << 'EOF'
#!/bin/bash

docker-compose down --remove-orphans
EOF

# create reset_container.sh
cat > reset_container.sh << 'EOF'
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
rm -f .env
EOF

# only need to add execute permission
chmod +x start_container.sh stop_container.sh reset_container.sh

echo "Installation complete!"
echo "Available commands:"
echo "  ./start_container.sh  - Start the container"
echo "  ./stop_container.sh   - Stop the container"
echo "  ./reset_container.sh  - Complete reset"

# self distruct to remove attack vectors
rm -- "$0"