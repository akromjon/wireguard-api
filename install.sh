#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color
SMTP_BLOCK_PORTS=(25 465 587)

add_firewall_rule() {
    local FIREWALL_BIN=$1
    shift

    if ! command -v "$FIREWALL_BIN" &> /dev/null; then
        if [[ "$FIREWALL_BIN" == "iptables" ]]; then
            echo -e "${RED}${FIREWALL_BIN} not found. Cannot install outbound SMTP block.${NC}"
            return 1
        fi
        return 0
    fi

    if "$FIREWALL_BIN" -C "$@" 2> /dev/null; then
        return 0
    fi

    "$FIREWALL_BIN" -I "$@"
}

append_smtp_block_to_vpn_config() {
    local VPN_CONFIG_FILE=$1
    local VPN_INTERFACE=$2

    if grep -q "^# VIPN outbound SMTP block$" "$VPN_CONFIG_FILE"; then
        echo -e "${YELLOW}Outbound SMTP block already exists in ${VPN_CONFIG_FILE}.${NC}"
        return 0
    fi

    {
        echo ""
        echo "# VIPN outbound SMTP block"
        for PORT in "${SMTP_BLOCK_PORTS[@]}"; do
            echo "PostUp = command -v iptables >/dev/null && (iptables -C FORWARD -i ${VPN_INTERFACE} -p tcp --dport ${PORT} -j REJECT 2>/dev/null || iptables -I FORWARD -i ${VPN_INTERFACE} -p tcp --dport ${PORT} -j REJECT) || true"
            echo "PostUp = command -v iptables >/dev/null && (iptables -C OUTPUT -p tcp --dport ${PORT} -j REJECT 2>/dev/null || iptables -I OUTPUT -p tcp --dport ${PORT} -j REJECT) || true"
            echo "PostUp = command -v ip6tables >/dev/null && (ip6tables -C FORWARD -i ${VPN_INTERFACE} -p tcp --dport ${PORT} -j REJECT 2>/dev/null || ip6tables -I FORWARD -i ${VPN_INTERFACE} -p tcp --dport ${PORT} -j REJECT) || true"
            echo "PostUp = command -v ip6tables >/dev/null && (ip6tables -C OUTPUT -p tcp --dport ${PORT} -j REJECT 2>/dev/null || ip6tables -I OUTPUT -p tcp --dport ${PORT} -j REJECT) || true"
            echo "PostDown = command -v iptables >/dev/null && iptables -D FORWARD -i ${VPN_INTERFACE} -p tcp --dport ${PORT} -j REJECT 2>/dev/null || true"
            echo "PostDown = command -v iptables >/dev/null && iptables -D OUTPUT -p tcp --dport ${PORT} -j REJECT 2>/dev/null || true"
            echo "PostDown = command -v ip6tables >/dev/null && ip6tables -D FORWARD -i ${VPN_INTERFACE} -p tcp --dport ${PORT} -j REJECT 2>/dev/null || true"
            echo "PostDown = command -v ip6tables >/dev/null && ip6tables -D OUTPUT -p tcp --dport ${PORT} -j REJECT 2>/dev/null || true"
        done
    } >> "$VPN_CONFIG_FILE"
}

configure_outbound_smtp_block() {
    local VPN_INTERFACE=""
    local VPN_CONFIG_FILE=""

    case "$VPN_TYPE" in
        amneziawg)
            if [[ -f /etc/amnezia/amneziawg/params ]]; then
                # shellcheck disable=SC1091
                source /etc/amnezia/amneziawg/params
                VPN_INTERFACE="${SERVER_AWG_NIC:-}"
                VPN_CONFIG_FILE="/etc/amnezia/amneziawg/${VPN_INTERFACE}.conf"
            fi
            ;;
        wireguard)
            if [[ -f /etc/wireguard/params ]]; then
                # shellcheck disable=SC1091
                source /etc/wireguard/params
                VPN_INTERFACE="${SERVER_WG_NIC:-}"
                VPN_CONFIG_FILE="/etc/wireguard/${VPN_INTERFACE}.conf"
            fi
            ;;
    esac

    if [[ -z "$VPN_INTERFACE" || ! -f "$VPN_CONFIG_FILE" ]]; then
        echo -e "${RED}Could not find the installed ${VPN_TYPE} interface/config for outbound SMTP blocking.${NC}"
        return 1
    fi

    echo -e "${YELLOW}Blocking outbound SMTP ports for VPN traffic: ${SMTP_BLOCK_PORTS[*]}${NC}"

    for PORT in "${SMTP_BLOCK_PORTS[@]}"; do
        add_firewall_rule iptables FORWARD -i "$VPN_INTERFACE" -p tcp --dport "$PORT" -j REJECT || return 1
        add_firewall_rule iptables OUTPUT -p tcp --dport "$PORT" -j REJECT || return 1
        add_firewall_rule ip6tables FORWARD -i "$VPN_INTERFACE" -p tcp --dport "$PORT" -j REJECT || return 1
        add_firewall_rule ip6tables OUTPUT -p tcp --dport "$PORT" -j REJECT || return 1
    done

    append_smtp_block_to_vpn_config "$VPN_CONFIG_FILE" "$VPN_INTERFACE"
    echo -e "${GREEN}Outbound SMTP block installed for ${VPN_INTERFACE}.${NC}"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root${NC}"
  exit 1
fi

echo -e "${GREEN}WireGuard API Installer${NC}"
echo "This script will clone the WireGuard API repository and run the installer."
echo ""
echo "Please choose which VPN backend you want to install:"
echo "  1) WireGuard"
echo "  2) AmneziaWG"
until [[ ${VPN_CHOICE} =~ ^[12]$ ]]; do
    read -rp "Select an option [1-2]: " -e -i "2" VPN_CHOICE
done

case "${VPN_CHOICE}" in
    1)
        VPN_TYPE="wireguard"
        INSTALLER_SCRIPT="wireguard-installer.sh"
        ;;
    2)
        VPN_TYPE="amneziawg"
        INSTALLER_SCRIPT="amneziawg-install.sh"
        ;;
esac

echo -e "${GREEN}Selected: ${VPN_TYPE}${NC}"
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
chmod +x "$INSTALLER_SCRIPT"

# Run the installer script
echo -e "${YELLOW}Running the ${VPN_TYPE} installer script...${NC}"
if ./"$INSTALLER_SCRIPT"; then
    echo -e "${GREEN}Installation completed successfully.${NC}"
else
    echo -e "${RED}Installation failed.${NC}"
    exit 1
fi

if ! configure_outbound_smtp_block; then
    echo -e "${RED}Failed to install outbound SMTP block.${NC}"
    cd - > /dev/null || exit 1
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Clean up
cd - > /dev/null || exit 1
rm -rf "$TEMP_DIR"

echo -e "${GREEN}WireGuard API has been installed successfully!${NC}"
exit 0
