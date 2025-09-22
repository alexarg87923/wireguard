#!/bin/bash

echo "Starting transparent proxy..."

# Start redsocks in background
redsocks -c /etc/redsocks/redsocks.conf &

# Keep container running
wait