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
  
  # Check if .env file exists, create a sample one if it doesn't
  if [ ! -f "$CONFIG_DIR/.env" ]; then
    echo "Creating sample .env file in $CONFIG_DIR"
    cat > "$CONFIG_DIR/.env" << 'EOF'
# Wireguard API Configuration
PORT=8080
WG_CONFIG_DIR=/etc/wireguard
# Add other environment variables as needed
EOF
    echo "Please review and modify $CONFIG_DIR/.env as needed"
  else
    echo "Using existing .env file in $CONFIG_DIR"
  fi
  
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