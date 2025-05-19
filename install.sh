#!/bin/bash

set -e
# github: https://github.com/akromjon/wireguard-api
URL_PREFIX="https://github.com/akromjon/wireguard-api/releases/download/v1.0.0"
INSTALL_DIR=${INSTALL_DIR:-/usr/local/bin}
CONFIG_DIR=${CONFIG_DIR:-/etc/wireguard-api}

case "$(uname -sm)" in
  "Darwin x86_64") FILENAME="wireguard-darwin-amd64" ;;
  "Darwin arm64") FILENAME="wireguard-darwin-arm64" ;;
  "Linux x86_64") FILENAME="wireguard-linux-amd64" ;;
  "Linux i686") FILENAME="wireguard-linux-386" ;;
  "Linux armv7l") FILENAME="wireguard-linux-arm" ;;
  "Linux aarch64") FILENAME="wireguard-linux-arm64" ;;
  *) echo "Unsupported architecture: $(uname -sm)" >&2; exit 1 ;;
esac

echo "Downloading $FILENAME from github releases"
if ! curl -sSLf "$URL_PREFIX/$FILENAME" -o "$INSTALL_DIR/wireguard"; then
  echo "Failed to write to $INSTALL_DIR; try with sudo" >&2
  exit 1
fi

if ! chmod +x "$INSTALL_DIR/wireguard"; then
  echo "Failed to set executable permission on $INSTALL_DIR/wireguard" >&2
  exit 1
fi

# Install systemd service on Linux
if [[ "$(uname -s)" == "Linux" ]] && command -v systemctl &> /dev/null; then
  echo "Installing systemd service..."
  
  # Create config directory and .env file if it doesn't exist
  if [ ! -d "$CONFIG_DIR" ]; then
    mkdir -p "$CONFIG_DIR"
    echo "Created configuration directory: $CONFIG_DIR"
  fi
  
  # Check if .env file exists, create from .env.example if it doesn't
  if [ ! -f "$CONFIG_DIR/.env" ]; then
    echo "Creating .env file in $CONFIG_DIR"
    
    # Check if .env.example exists in current directory
    if [ -f "./.env.example" ]; then
      # Copy from .env.example to .env
      cp ./.env.example "$CONFIG_DIR/.env"
      echo "Copied from .env.example template"
    else
      # Create default .env file
      cat > "$CONFIG_DIR/.env" << 'EOF'
# Wireguard API Configuration
PORT=8080
WG_CONFIG_DIR=/etc/wireguard
# Add other environment variables as needed
EOF
      echo "Created default .env file"
    fi
    
    # Generate a random API token and add/replace it in .env file
    API_TOKEN=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
    if grep -q "^API_TOKEN=" "$CONFIG_DIR/.env"; then
      # Replace existing API_TOKEN line
      sed -i "s/^API_TOKEN=.*$/API_TOKEN=$API_TOKEN/" "$CONFIG_DIR/.env"
    else
      # Add API_TOKEN line if it doesn't exist
      echo "API_TOKEN=$API_TOKEN" >> "$CONFIG_DIR/.env"
    fi
    
    echo -e "\033[0;32mAPI Token generated: $API_TOKEN\033[0m"
    echo "Please save this token for API authentication"
  else
    echo "Using existing .env file in $CONFIG_DIR"
    
    # Check if API_TOKEN exists in .env, generate if it doesn't
    if ! grep -q "^API_TOKEN=" "$CONFIG_DIR/.env"; then
      API_TOKEN=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
      echo "API_TOKEN=$API_TOKEN" >> "$CONFIG_DIR/.env"
      echo -e "\033[0;32mAPI Token generated: $API_TOKEN\033[0m"
      echo "Please save this token for API authentication"
    else
      # Display existing API token
      API_TOKEN=$(grep "^API_TOKEN=" "$CONFIG_DIR/.env" | cut -d= -f2)
      echo -e "\033[0;32mExisting API Token: $API_TOKEN\033[0m"
    fi
  fi
  
  # Create OpenAPI documentation in config directory
  echo "Creating OpenAPI documentation..."
  cat > "$CONFIG_DIR/openapi.yaml" << 'EOF'
openapi: 3.0.3
info:
  title: WireGuard API
  description: API for managing WireGuard VPN users and service
  version: 1.0.0
  contact:
    name: GitHub Repository
    url: https://github.com/akromjon/wireguard-api
servers:
  - url: http://localhost:8080
    description: Local development server

components:
  securitySchemes:
    ApiKeyAuth:
      type: apiKey
      in: header
      name: key
  
  schemas:
    APIResponse:
      type: object
      properties:
        success:
          type: boolean
          description: Indicates if the operation was successful
        message:
          type: string
          description: Human-readable message about the operation
        data:
          type: object
          description: Optional data returned from the operation
    
    Client:
      type: object
      properties:
        name:
          type: string
          description: Client name
        ipv4:
          type: string
          description: IPv4 address assigned to the client
        ipv6:
          type: string
          description: IPv6 address assigned to the client
        config:
          type: string
          description: WireGuard configuration file content for the client
    
    AddUserRequest:
      type: object
      required:
        - name
      properties:
        name:
          type: string
          description: Client name (alphanumeric, underscore, dash only; max 15 chars)
          example: client1
        ipv4:
          type: string
          description: IPv4 address to assign (optional, auto-assigned if not provided)
          example: 10.8.0.2
        ipv6:
          type: string
          description: IPv6 address to assign (optional, auto-assigned if not provided)
          example: fd42:42:42::2
    
    DeleteUserRequest:
      type: object
      required:
        - name
      properties:
        name:
          type: string
          description: Client name to delete
          example: client1

security:
  - ApiKeyAuth: []

paths:
  /api/users:
    get:
      summary: List all WireGuard clients
      description: Returns a list of all configured WireGuard clients
      operationId: listUsers
      responses:
        '200':
          description: List of clients
          content:
            application/json:
              schema:
                type: object
                properties:
                  success:
                    type: boolean
                    example: true
                  data:
                    type: array
                    items:
                      $ref: '#/components/schemas/Client'
        '401':
          description: Unauthorized - Missing or invalid API token
  
  /api/users/add:
    post:
      summary: Add a new WireGuard client
      description: Creates a new WireGuard client configuration
      operationId: addUser
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/AddUserRequest'
      responses:
        '200':
          description: Client created successfully
          content:
            application/json:
              schema:
                type: object
                properties:
                  success:
                    type: boolean
                    example: true
                  message:
                    type: string
                    example: Client added successfully
                  data:
                    $ref: '#/components/schemas/Client'
        '400':
          description: Invalid request
        '401':
          description: Unauthorized - Missing or invalid API token
        '409':
          description: Client already exists
  
  /api/users/delete:
    post:
      summary: Delete a WireGuard client
      description: Removes a WireGuard client configuration
      operationId: deleteUser
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/DeleteUserRequest'
      responses:
        '200':
          description: Client deleted successfully
          content:
            application/json:
              schema:
                type: object
                properties:
                  success:
                    type: boolean
                    example: true
                  message:
                    type: string
                    example: Client deleted successfully
        '400':
          description: Invalid request
        '401':
          description: Unauthorized
        '404':
          description: Client not found

  /api/wireguard-status:
    get:
      summary: Get WireGuard service status
      description: Returns detailed status information about the WireGuard service
      operationId: getWireGuardStatus
      responses:
        '200':
          description: WireGuard status information
          content:
            application/json:
              schema:
                type: object
                properties:
                  success:
                    type: boolean
                    example: true
                  data:
                    type: object
                    properties:
                      interface:
                        type: string
                        example: wg0
                      running:
                        type: boolean
                        example: true
                      peers:
                        type: array
                        items:
                          type: object
                      server_info:
                        type: object
                      system:
                        type: object
        '401':
          description: Unauthorized - Missing or invalid API token

  /api/wireguard/start:
    post:
      summary: Start the WireGuard service
      description: Starts the WireGuard service using systemctl
      operationId: startWireGuard
      responses:
        '200':
          description: Service started successfully
          content:
            application/json:
              schema:
                type: object
                properties:
                  success:
                    type: boolean
                    example: true
                  message:
                    type: string
                    example: WireGuard service started successfully
        '401':
          description: Unauthorized - Missing or invalid API token
        '500':
          description: Failed to start the service

  /api/wireguard/stop:
    post:
      summary: Stop the WireGuard service
      description: Stops the WireGuard service using systemctl
      operationId: stopWireGuard
      responses:
        '200':
          description: Service stopped successfully
          content:
            application/json:
              schema:
                type: object
                properties:
                  success:
                    type: boolean
                    example: true
                  message:
                    type: string
                    example: WireGuard service stopped successfully
        '401':
          description: Unauthorized - Missing or invalid API token
        '500':
          description: Failed to stop the service

  /api/wireguard/restart:
    post:
      summary: Restart the WireGuard service
      description: Restarts the WireGuard service using systemctl
      operationId: restartWireGuard
      responses:
        '200':
          description: Service restarted successfully
          content:
            application/json:
              schema:
                type: object
                properties:
                  success:
                    type: boolean
                    example: true
                  message:
                    type: string
                    example: WireGuard service restarted successfully
        '401':
          description: Unauthorized - Missing or invalid API token
        '500':
          description: Failed to restart the service
EOF
  echo "OpenAPI documentation created at $CONFIG_DIR/openapi.yaml"
  
  # Create service file
  cat > /tmp/wireguard.service << 'EOF'
[Unit]
Description=Wireguard API Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/wireguard-api
ExecStart=/usr/local/bin/wireguard
EnvironmentFile=/etc/wireguard-api/.env
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  # Copy service file to systemd directory
  if ! cp /tmp/wireguard.service /etc/systemd/system/; then
    echo "Failed to copy service file to /etc/systemd/system/; try with sudo" >&2
    exit 1
  fi
  
  # Reload systemd, enable and start service
  systemctl daemon-reload
  systemctl enable wireguard.service
  systemctl start wireguard.service
  echo "Systemd service installed and started"
fi

# let's check if the service is running
if [[ "$(uname -s)" == "Linux" ]] && command -v systemctl &> /dev/null; then
  if ! systemctl is-active --quiet wireguard.service; then
    echo "Failed to start wireguard service" >&2
    echo "Check logs with: journalctl -u wireguard.service" >&2
    exit 1
  fi
fi

echo "wireguard V1 is successfully installed"
echo "API Documentation available at $CONFIG_DIR/openapi.yaml"

# Display API access information
if [[ -f "$CONFIG_DIR/.env" ]]; then
  API_PORT=$(grep "^PORT=" "$CONFIG_DIR/.env" | cut -d= -f2 || echo "8080")
  API_TOKEN=$(grep "^API_TOKEN=" "$CONFIG_DIR/.env" | cut -d= -f2)
  
  echo ""
  echo -e "\033[0;32mAPI Information:\033[0m"
  echo -e "- Endpoint: http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost"):$API_PORT"
  echo -e "- API Token: \033[0;33m$API_TOKEN\033[0m"
  echo -e "- Example usage: curl -H \"key: $API_TOKEN\" http://localhost:$API_PORT/api/wireguard-status"
fi