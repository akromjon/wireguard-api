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

echo -e "${GREEN}WireGuard API Installer${NC}"
echo "This script will clone the WireGuard API repository and run the installer."
echo ""

# Install git if not already installed
if ! command -v git &> /dev/null; then
    echo -e "${YELLOW}Git not found. Installing git...${NC}"
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y git
    elif command -v yum &> /dev/null; then
        yum install -y git
    elif command -v dnf &> /dev/null; then
        dnf install -y git
    elif command -v apk &> /dev/null; then
        apk add git
    else
        echo -e "${RED}Could not install git. Please install git manually and try again.${NC}"
        exit 1
    fi
fi

# Create a temporary directory
TEMP_DIR=$(mktemp -d)
echo -e "${YELLOW}Cloning repository...${NC}"

# Clone the repository
if git clone https://github.com/akromjon/wireguard-api.git "$TEMP_DIR"; then
    echo -e "${GREEN}Repository cloned successfully.${NC}"
else
    echo -e "${RED}Failed to clone repository.${NC}"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Navigate to the repository directory
cd "$TEMP_DIR" || exit 1

# Make the installer script executable
chmod +x wireguard-installer.sh

# Run the installer script
echo -e "${YELLOW}Running the installer script...${NC}"
if ./wireguard-installer.sh; then
    echo -e "${GREEN}Installation completed successfully.${NC}"
else
    echo -e "${RED}Installation failed.${NC}"
    exit 1
fi

# Clean up
cd - > /dev/null
rm -rf "$TEMP_DIR"

echo -e "${GREEN}WireGuard API has been installed successfully!${NC}"
exit 0 