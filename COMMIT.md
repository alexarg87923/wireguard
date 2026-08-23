Drive host and peer access from a single VPN_ALLOW ip:port list.

Replace per-port flags with VPN_ALLOW so the server punches its own host ports and forwards the rest to peers. Tag our iptables as wireguard, reset only this project's containers/images, and document the install path in README.
