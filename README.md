# Flush all iptables rules
sudo iptables -t nat -F
sudo iptables -t mangle -F
sudo iptables -F
sudo iptables -X

# Delete custom ip rules
sudo ip rule del fwmark 1 table 100 2>/dev/null
sudo ip rule del fwmark 1 table vpn 2>/dev/null
sudo ip rule del fwmark 2 table main 2>/dev/null

# Flush custom routing tables
sudo ip route flush table 100 2>/dev/null
sudo ip route flush table vpn 2>/dev/null

# Remove any custom routes we added
sudo ip route del default via 172.18.0.2 dev br-3b1f2716e3f2 2>/dev/null

# Bring down and up eth interface to restore default routes
sudo ip link set enp1s0 down
sudo ip link set enp1s0 up

# Restart services to restore everything
sudo systemctl restart ufw
sudo systemctl restart docker

# Verify everything is back to normal
echo "=== Routes ==="
ip route show
echo "=== IP Rules ==="
ip rule show
echo "=== iptables Filter ==="
sudo iptables -L -n -v