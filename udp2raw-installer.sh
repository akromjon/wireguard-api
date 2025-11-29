#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root${NC}"
  exit 1
fi

echo -e "${GREEN}udp2raw Installer${NC}"
echo "This script will download and install udp2raw."

# Install wget if not already installed
if ! command -v wget &> /dev/null; then
    echo -e "${YELLOW}Wget not found. Installing wget...${NC}"
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y wget
    elif command -v yum &> /dev/null; then
        yum install -y wget
    elif command -v dnf &> /dev/null; then
        dnf install -y wget
    elif command -v apk &> /dev/null; then
        apk add wget
    else
        echo -e "${RED}Could not install wget. Please install wget manually and try again.${NC}"
        exit 1
    fi
fi

# Install udp2raw
echo -e "${YELLOW}Installing udp2raw...${NC}"
UDP2RAW_URL="https://github.com/wangyu-/udp2raw/releases/download/20230206.0/udp2raw_binaries.tar.gz"
UDP2RAW_TEMP_DIR=$(mktemp -d)
UDP2RAW_INSTALL_DIR="/usr/local/bin"

# Download udp2raw
if wget -q "$UDP2RAW_URL" -O "$UDP2RAW_TEMP_DIR/udp2raw_binaries.tar.gz"; then
    echo -e "${GREEN}Downloaded udp2raw successfully.${NC}"
else
    echo -e "${RED}Failed to download udp2raw.${NC}"
    rm -rf "$UDP2RAW_TEMP_DIR"
    exit 1
fi

# Extract udp2raw
cd "$UDP2RAW_TEMP_DIR" || exit 1
if tar -xzf udp2raw_binaries.tar.gz; then
    echo -e "${GREEN}Extracted udp2raw successfully.${NC}"
else
    echo -e "${RED}Failed to extract udp2raw.${NC}"
    rm -rf "$UDP2RAW_TEMP_DIR"
    exit 1
fi

# Detect architecture and copy the appropriate binary
ARCH=$(uname -m)
OS_TYPE=$(uname -s)

case "$ARCH" in
    x86_64|amd64)
        UDP2RAW_BINARY="udp2raw_amd64"
        ;;
    armv7l|arm)
        UDP2RAW_BINARY="udp2raw_arm"
        ;;
    aarch64|arm64)
        UDP2RAW_BINARY="udp2raw_arm64"
        ;;
    i386|i686)
        UDP2RAW_BINARY="udp2raw_x86"
        ;;
    mips)
        UDP2RAW_BINARY="udp2raw_mips"
        ;;
    mips64)
        UDP2RAW_BINARY="udp2raw_mips64"
        ;;
    *)
        echo -e "${RED}Unsupported architecture: $ARCH${NC}"
        rm -rf "$UDP2RAW_TEMP_DIR"
        exit 1
        ;;
esac

# Find and copy the binary
if [ -f "$UDP2RAW_BINARY" ]; then
    cp "$UDP2RAW_BINARY" "$UDP2RAW_INSTALL_DIR/udp2raw"
    chmod +x "$UDP2RAW_INSTALL_DIR/udp2raw"
    echo -e "${GREEN}Installed udp2raw binary to $UDP2RAW_INSTALL_DIR/udp2raw${NC}"
elif [ -f "udp2raw_binaries/$UDP2RAW_BINARY" ]; then
    cp "udp2raw_binaries/$UDP2RAW_BINARY" "$UDP2RAW_INSTALL_DIR/udp2raw"
    chmod +x "$UDP2RAW_INSTALL_DIR/udp2raw"
    echo -e "${GREEN}Installed udp2raw binary to $UDP2RAW_INSTALL_DIR/udp2raw${NC}"
else
    # Try to find any udp2raw binary
    UDP2RAW_FOUND=$(find . -name "udp2raw*" -type f ! -name "*.tar.gz" | head -1)
    if [ -n "$UDP2RAW_FOUND" ]; then
        cp "$UDP2RAW_FOUND" "$UDP2RAW_INSTALL_DIR/udp2raw"
        chmod +x "$UDP2RAW_INSTALL_DIR/udp2raw"
        echo -e "${GREEN}Installed udp2raw binary to $UDP2RAW_INSTALL_DIR/udp2raw${NC}"
    else
        echo -e "${RED}Could not find udp2raw binary for architecture $ARCH${NC}"
        rm -rf "$UDP2RAW_TEMP_DIR"
        exit 1
    fi
fi

# Install systemd service for udp2raw (Linux only)
if [[ "$OS_TYPE" == "Linux" ]] && command -v systemctl &> /dev/null; then
    echo -e "${YELLOW}Creating systemd service for udp2raw...${NC}"
    
    # Read WireGuard port and password from .env file
    CONFIG_DIR="/etc/wireguard-api"
    WG_PORT="51820"  # Default fallback port
    UDP2RAW_PORT="4096"  # Default udp2raw port
    UDP2RAW_PASSWORD=""
    SERVER_PUB_IP=""
    
    # Ensure .env file exists
    if [ ! -f "$CONFIG_DIR/.env" ]; then
        echo -e "${YELLOW}.env file not found at $CONFIG_DIR/.env. Creating it...${NC}"
        mkdir -p "$CONFIG_DIR"
        touch "$CONFIG_DIR/.env"
    fi
    
    # Read WireGuard port from .env
    if grep -q "^WG_PORT=" "$CONFIG_DIR/.env"; then
        WG_PORT=$(grep "^WG_PORT=" "$CONFIG_DIR/.env" | cut -d= -f2)
        echo -e "${GREEN}Found WireGuard port in .env: ${WG_PORT}${NC}"
    else
        echo -e "${YELLOW}WG_PORT not found in .env, using default: ${WG_PORT}${NC}"
    fi
    
    # Read or set udp2raw port in .env
    if grep -q "^UDP2RAW_PORT=" "$CONFIG_DIR/.env"; then
        UDP2RAW_PORT=$(grep "^UDP2RAW_PORT=" "$CONFIG_DIR/.env" | cut -d= -f2)
        echo -e "${GREEN}Found udp2raw port in .env: ${UDP2RAW_PORT}${NC}"
    else
        # Write default udp2raw port to .env file
        echo "UDP2RAW_PORT=$UDP2RAW_PORT" >> "$CONFIG_DIR/.env"
        echo -e "${GREEN}Set udp2raw port in .env: ${UDP2RAW_PORT}${NC}"
    fi
    
    # udp2raw routes to localhost since WireGuard is on the same server
    # Using 127.0.0.1 ensures traffic stays local and is more efficient
    SERVER_PUB_IP="127.0.0.1"
    echo -e "${GREEN}udp2raw will route to localhost: ${SERVER_PUB_IP}:${WG_PORT}${NC}"
    
    # Generate or read udp2raw password
    if grep -q "^UDP2RAW_PASSWORD=" "$CONFIG_DIR/.env"; then
        UDP2RAW_PASSWORD=$(grep "^UDP2RAW_PASSWORD=" "$CONFIG_DIR/.env" | cut -d= -f2)
        echo -e "${GREEN}Using existing udp2raw password from .env${NC}"
    else
        # Generate a random password (32 characters, alphanumeric)
        UDP2RAW_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
        # Write password to .env file
        echo "UDP2RAW_PASSWORD=$UDP2RAW_PASSWORD" >> "$CONFIG_DIR/.env"
        echo -e "${GREEN}Generated udp2raw password and saved to .env${NC}"
        echo -e "${GREEN}udp2raw Password: ${UDP2RAW_PASSWORD}${NC}"
        echo -e "${YELLOW}Please save this password for udp2raw client configuration${NC}"
    fi
    
    # Create systemd service file with updated configuration
    cat > /etc/systemd/system/udp2raw.service << EOF
[Unit]
Description=udp2raw Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/udp2raw -s -l 0.0.0.0:${UDP2RAW_PORT} -r ${SERVER_PUB_IP}:${WG_PORT} --raw-mode udp -k "${UDP2RAW_PASSWORD}" --cipher-mode none --auth-mode none --tos 0x10
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # Reload systemd, enable and start service
    systemctl daemon-reload
    systemctl enable udp2raw.service
    systemctl start udp2raw.service
    echo -e "${GREEN}udp2raw systemd service installed and started${NC}"
    
    # Check if service is running
    if systemctl is-active --quiet udp2raw.service; then
        echo -e "${GREEN}udp2raw service is running${NC}"
    else
        echo -e "${YELLOW}Warning: udp2raw service may not be running. Check with: systemctl status udp2raw.service${NC}"
        echo -e "${YELLOW}Note: You may need to configure udp2raw parameters in /etc/systemd/system/udp2raw.service${NC}"
    fi
else
    echo -e "${YELLOW}Systemd not available. udp2raw binary installed but service not configured.${NC}"
fi

# Clean up temp directory
cd / || exit 1
rm -rf "$UDP2RAW_TEMP_DIR"

echo -e "${GREEN}udp2raw has been installed successfully!${NC}"
exit 0

