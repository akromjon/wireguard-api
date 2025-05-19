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

### One-Command Installation
```bash
curl -sSL https://raw.githubusercontent.com/akromjon/wireguard-api/main/wireguard-installer.sh | sudo bash
```

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