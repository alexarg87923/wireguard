# WireGuard

Docker WireGuard for a small mesh. The server (hub) and each client run this repo with a different `PROFILE` in `.env`.

## What you need

- A Linux box
- Docker and Docker Compose
- This repo cloned on that box

## Install (every machine)

```bash
git clone <this-repo> && cd wireguard
sudo ./install.sh
cp .env.EXAMPLE .env
# edit .env for this machine (PROFILE=server or PROFILE=client)
sudo ./install_service.sh
sudo systemctl enable wireguard-vpn
```

`install.sh` writes the helper scripts, then deletes itself. Re-run it from git after you pull.

## Keys

On a **client**:

```bash
sudo ./gen_keys.sh client
```

Send the operator the printed **public** key (and the VPN IP you will use, e.g. `10.0.2.3/32`). They add it as a peer on the server.

On the **server** (if you do not already have a keypair):

```bash
sudo ./gen_keys.sh server
```

Clients need `SERVER_PUBLIC_KEY` and the server endpoint (`CLIENT_ENDPOINT` + `CLIENT_PORT`).

Optional PSK for peer `N`:

```bash
sudo ./gen_psk.sh N
```

## Server `.env`

- `PROFILE=server`
- `PEER1_PUBLIC_KEY` / `PEER1_ALLOWED_IPS`, `PEER2_…`, …
- `VPN_ALLOW` — `ip:port` list for the private network
  - This box’s VPN IP (usually `10.0.2.1:22`) is DNATed to the host
  - Other IPs are **peer forwards** through the hub (`10.0.2.3:22`, `10.0.2.3:3060`, …)

## Client `.env`

- `PROFILE=client`
- `CLIENT_IP` (your `/32`, must match what the server listed)
- `CLIENT_ENDPOINT`, `CLIENT_PORT`, `SERVER_PUBLIC_KEY`, `ALLOWEDIPS`
- `VPN_ALLOW` — only entries for **this** box’s IP are applied (`10.0.2.3:22,10.0.2.3:3060`)
- `ENABLE_EMERGENCY_ACCESS` — when the tunnel is down, allow SSH from `CLIENT_ENDPOINT` (the server’s public IP)

MinIO ports in `.env` are for the MinIO container only. They do not open firewall holes. To reach MinIO over the VPN, add that `ip:port` to `VPN_ALLOW`.

## Start

```bash
sudo systemctl start wireguard-vpn
```

If the `.env` and keys match, the client connects to the server by itself.

```bash
sudo systemctl status wireguard-vpn
sudo docker exec wireguard-client wg show   # or wireguard-server
```

`wireguard-vpn` is oneshot: `active (exited)` is normal after a successful start. Use `restart` to apply config changes.

## After a pull

```bash
git pull
sudo ./install.sh
sudo systemctl restart wireguard-vpn
```

`sudo ./reset.sh` stops this project's containers, removes our WireGuard images, and deletes iptables rules tagged `wireguard`. It does not flush the host firewall or touch other Docker apps.

## Commands

All generated scripts require root. Docker-using scripts also require Docker.

| Script | Purpose |
|---|---|
| `sudo ./install.sh` | Generate scripts (self-deletes) |
| `sudo ./install_service.sh` | Install `wireguard-vpn.service` |
| `sudo ./start_container.sh` | Start (also run by the unit) |
| `sudo ./stop_container.sh` | Stop |
| `sudo ./reset.sh` | Stop our containers, drop our rules, remove our WG images |
| `sudo ./gen_keys.sh client\|server` | Write keypair into `.env` |
| `sudo ./gen_psk.sh N` | Write peer PSK into `.env` |

Recovery / debug commands: `DEV.md`.
