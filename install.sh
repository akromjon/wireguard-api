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
  
  # Copy wireguard.service file to systemd directory
  if [ -f "./wireguard.service" ]; then
    echo "Using existing wireguard.service file"
    
    # Copy service file to systemd directory
    if ! cp ./wireguard.service /etc/systemd/system/; then
      echo "Failed to copy service file to /etc/systemd/system/; try with sudo" >&2
      exit 1
    fi
  else
    echo "wireguard.service file not found in current directory"
    echo "Creating default service file..."
    
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

# Display API access information
if [[ -f "$CONFIG_DIR/.env" ]]; then
  API_PORT=$(grep "^API_PORT=" "$CONFIG_DIR/.env" | cut -d= -f2 || echo "8080")
  API_TOKEN=$(grep "^API_TOKEN=" "$CONFIG_DIR/.env" | cut -d= -f2)
  
  echo ""
  echo -e "\033[0;32mAPI Information:\033[0m"
  echo -e "- Service API: http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost"):$API_PORT"
  echo -e "- API Token: \033[0;33m$API_TOKEN\033[0m"
  echo -e "- Example usage: curl -H \"key: $API_TOKEN\" http://localhost:$API_PORT/api/wireguard-status"
fi