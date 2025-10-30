#!/bin/bash

echo "Removing commands if they exist"

rm ./start_container.sh
rm ./stop_container.sh
rm ./reset_container.sh

echo "Installing WireGuard container management scripts..."

# set umask so all created files/dirs are owner-only
umask 077

# create directories
mkdir -p wireguard/config wireguard/keys

# create start_container.sh
cat > start_container.sh << 'EOF'
#!/bin/bash

ENV_FILE=./.env

if [ ! -f "$ENV_FILE" ]; then
  echo "Error: .env file not found. Create it (e.g. copy .env.EXAMPLE) and configure."
  exit 1
fi

# Load environment variables from .env
set -o allexport
source "$ENV_FILE"
set +o allexport

if [ -z "$PROFILE" ]; then
  echo "Error: PROFILE is not set in .env"
  exit 1
fi

if [ -z "$ALLOWEDIPS" ]; then
  echo "Error: ALLOWEDIPS is not set in .env"
  exit 1
fi

if ! docker start "wireguard-$PROFILE" 2>/dev/null; then # if we failed
  docker compose --profile ${PROFILE} up -d
fi
EOF

# create stop_container.sh
cat > stop_container.sh << 'EOF'
#!/bin/bash

docker compose down --remove-orphans
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