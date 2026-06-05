# WireGuard VPN API

A REST API for managing WireGuard VPN users and configurations. This API allows you to add, list, and delete WireGuard clients programmatically.

## Features

- **RESTful API** for WireGuard management
- **Token-based authentication** for secure access
- **Client management**: list, add, and delete WireGuard clients
- **Cross-platform support** with graceful fallbacks for different system commands
- **Detailed status information** about the WireGuard server and its peers

## Requirements

- WireGuard installed and configured on the server
- Go 1.16 or later (for building from source)
- Linux system with systemd (for service installation)

## Quick Installation

### Using the Provided Installation Script
Download and run our installation script that handles cloning the repository and running the installer:
```bash
curl -sSL https://raw.githubusercontent.com/akromjon/wireguard-api/main/install.sh -o install.sh
chmod +x install.sh
sudo ./install.sh
```

This script will:
- Check if git is installed and install it if needed
- Clone the WireGuard API repository
- Run the installer script
- Clean up after installation

Fresh installs provision the VPN interface on a **/16** (≈64k addresses per node).

## Scaling: /16 Allocator Migration (existing nodes)

Older nodes were provisioned on a **/24**, which caps a node at ~253 peers
(IPv4 last octet `2–254`). To lift that ceiling on an **already-installed** node,
run the migration subcommand:

```bash
curl -sSL https://raw.githubusercontent.com/akromjon/wireguard-api/main/install.sh -o install.sh
chmod +x install.sh
sudo ./install.sh sixteen-allocator
```

Pin a specific release instead of `latest`:
```bash
SIXTEEN_TAG=v1.1.0 sudo ./install.sh sixteen-allocator
```

The subcommand is **idempotent and non-destructive**. In order, it:
1. Detects the backend (WireGuard or AmneziaWG), interface, config and server IP
   from `/etc/{wireguard,amnezia/amneziawg}/params`.
2. **Widens the interface to /16 first** — updates the config `Address` line
   (`/24 → /16`, IPv6 left at `/64`), applies it live gap-free (`ip addr` adds
   `/16` before removing `/24`), and widens the firewalld masquerade source if
   firewalld is in use (plain `iptables` MASQUERADE is unscoped, so no change).
3. Downloads the new `/16`-aware binary, swaps `/usr/local/bin/wireguard`, and
   restarts `wireguard.service`.
4. Verifies the interface is `/16`.

**Existing peers are never touched.** Their `10.x.x.x` addresses already sit
inside the `/16`, so there is no renumbering and tunnels stay up. New users are
allocated the lowest free address (e.g. `10.x.0.x`), reading and skipping every
address already present in the live config.

**After migrating, raise the server's `max_connections`** in the control panel to
a value matched to the node's bandwidth/CPU (not the full 64k — concurrency is
resource-bound, not IP-bound).

> Requires a published GitHub Release with the platform binaries attached
> (`wireguard-linux-amd64`, etc.), built via `./build.sh`. The migration pulls
> from `releases/latest/download/` (or the pinned `SIXTEEN_TAG`).

### Manual Installation Steps
1. Clone the repository:
```bash
git clone https://github.com/akromjon/wireguard-api.git
cd wireguard-api
```

2. Run the installation script as root:
```bash
chmod +x wireguard-installer.sh
sudo ./wireguard-installer.sh
```

The script will:
- Check if WireGuard is installed and install it if needed
- Install Go and other dependencies
- Create a dedicated service user
- Build and install the application
- Create a systemd service
- Generate a random API token
- Configure permissions
- Start the service

After installation, you'll receive the API URL and token.

## Manual Installation

If you prefer to install the service manually:

1. Build the application:
```bash
go build -o wireguard-api
```

2. Create a `.env` file with your configuration:
```
API_PORT=8080
API_TOKEN=your-secure-api-token
WG_CONFIG_FILE=/etc/wireguard/wg0.conf
WG_PARAMS_FILE=/etc/wireguard/params
WIREGUARD_CLIENTS=/home/wireguard/users
DEBUG_MODE=false
```

3. Run the application:
```bash
./wireguard-api
```

## API Endpoints

All endpoints require authentication with the API token in the request header: `key: your-api-token`

### Get WireGuard Status

**GET /api/wireguard/status**

Returns detailed information about the WireGuard server status, including connected peers, transfer statistics, and configuration details.

### List Clients

**GET /api/users**

Returns a list of all configured WireGuard clients and their configurations.

### Add Client

**POST /api/users/add**

Creates a new WireGuard client configuration.

Request body:
```json
{
  "name": "client1",
  "ipv4": "10.66.66.2",   // Optional: auto-assigned if not provided
  "ipv6": "fd42:42:42::2" // Optional: auto-assigned if not provided
}
```

### Delete Client

**POST /api/users/delete**

Removes a WireGuard client configuration.

Request body:
```json
{
  "name": "client1"
}
```

## Security Considerations

- The API token should be kept secure
- For production use, consider configuring SSL termination with Nginx or similar
- Use a firewall to restrict access to the API port
- Regularly update the server and the API

## Troubleshooting

- Check service status: `systemctl status wireguard-api`
- View logs: `journalctl -u wireguard-api -f`
- Verify permissions: Ensure the service user has access to WireGuard configuration files

## License

MIT 