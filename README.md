# WireGuard VPN Management API

A Go-based REST API for managing WireGuard VPN configurations and users.

## Features

- Add new WireGuard clients
- List existing WireGuard clients
- Delete WireGuard clients
- All responses in JSON format
- Token-based authentication
- Debug mode for troubleshooting

## Setup

### Prerequisites

- WireGuard installed on your server
- Go 1.15 or higher
- WireGuard configuration at `/etc/wireguard/wg0.conf`
- WireGuard params file at `/etc/wireguard/params`

### Configuration

Create a `.env` file in the same directory as the executable with the following content:

```
# WireGuard API Configuration

# API Settings
API_PORT=8080
API_TOKEN=your-secure-random-token

# WireGuard Paths
WG_CONFIG_FILE=/etc/wireguard/wg0.conf
WG_PARAMS_FILE=/etc/wireguard/params
WIREGUARD_CLIENTS=/home/wireguard/users

# Debug Settings
DEBUG_MODE=false
```

Make sure to replace `your-secure-random-token` with a strong random token for API authentication.

### Running the API

```bash
go build -o wireguard-api
./wireguard-api
```

Or using the Makefile:

```bash
# Just run (without building)
make run

# Build and then run
make start
```

## Troubleshooting

If you encounter issues, you can enable debug mode by setting `DEBUG_MODE=true` in your `.env` file. This will:

1. Enable detailed error logging
2. Add a debugging endpoint at `/api/debug/wireguard-status` that provides information about your WireGuard configuration

The debug endpoint returns:
- WireGuard installation status
- Configuration file status
- Current WireGuard parameters
- WireGuard running status
- Server information

## API Endpoints

### Authentication

All API requests require an API token in the `key` header:

```
key: your-secure-random-token
```

### List Users

**GET** `/api/users`

Returns all WireGuard clients with their configurations.

### Add User

**POST** `/api/users/add`

Request body:
```json
{
  "name": "client1",
  "ipv4": "10.66.66.2",  // Optional, auto-assigned if not provided
  "ipv6": "fd42:42:42::2" // Optional, auto-assigned if not provided
}
```

### Delete User

**POST** `/api/users/delete`

Request body:
```json
{
  "name": "client1"
}
```

### Debug WireGuard Status (Debug Mode Only)

**GET** `/api/debug/wireguard-status`

Returns detailed information about the WireGuard configuration and system status.

## Response Format

All API responses follow this format:

```json
{
  "success": true,
  "message": "Operation status message",
  "data": {} // Operation data if applicable
}
```

For client configurations, the `data` field will include the WireGuard configuration as a plain text string in the `config` field. 