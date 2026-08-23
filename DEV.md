# Dev / recovery commands

These are leftover commands from debugging, not the normal install path. See `README.md` for setup.

## Nuclear iptables reset (host)

Only if the host firewall is wedged. This is **not** what `reset.sh` does.

```bash
sudo iptables -t nat -F
sudo iptables -t mangle -F
sudo iptables -F
sudo iptables -X

sudo ip rule del fwmark 1 table 100 2>/dev/null
sudo ip rule del fwmark 1 table vpn 2>/dev/null
sudo ip rule del fwmark 2 table main 2>/dev/null

sudo ip route flush table 100 2>/dev/null
sudo ip route flush table vpn 2>/dev/null

sudo systemctl restart ufw
sudo systemctl restart docker

ip route show
ip rule show
sudo iptables -L -n -v
```

## Inspect the tunnel

```bash
sudo docker exec wireguard-server wg show
sudo docker exec wireguard-client wg show
sudo docker exec wireguard-server grep -E 'AllowedIPs|PersistentKeepalive|PostUp' /config/wg_confs/wg0.conf
sudo iptables -S INPUT | grep wireguard
```
