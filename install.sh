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
    local SMTP_BLOCK_FILE
    local TMP_CONFIG
    local CLEAN_CONFIG=""
    local SOURCE_CONFIG="$VPN_CONFIG_FILE"

    SMTP_BLOCK_FILE=$(mktemp) || return 1
    TMP_CONFIG=$(mktemp) || {
        rm -f "$SMTP_BLOCK_FILE"
        return 1
    }

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
    } > "$SMTP_BLOCK_FILE"

    if grep -q "^# VIPN outbound SMTP block$" "$VPN_CONFIG_FILE"; then
        echo -e "${YELLOW}Refreshing outbound SMTP block in ${VPN_CONFIG_FILE}.${NC}"
        CLEAN_CONFIG=$(mktemp) || {
            rm -f "$SMTP_BLOCK_FILE" "$TMP_CONFIG"
            return 1
        }

        if ! awk '
            /^# VIPN outbound SMTP block$/ {
                skipping = 1
                next
            }
            skipping && /^Post(Up|Down) = command -v ip6?tables / {
                next
            }
            {
                skipping = 0
                print
            }
        ' "$VPN_CONFIG_FILE" > "$CLEAN_CONFIG"; then
            rm -f "$SMTP_BLOCK_FILE" "$TMP_CONFIG" "$CLEAN_CONFIG"
            return 1
        fi
        SOURCE_CONFIG=$CLEAN_CONFIG
    fi

    if ! awk -v block_file="$SMTP_BLOCK_FILE" '
        BEGIN {
            while ((getline line < block_file) > 0) {
                block = block line ORS
            }
            inserted = 0
        }
        !inserted && /^\[Peer\]$/ {
            printf "%s", block
            inserted = 1
        }
        { print }
        END {
            if (!inserted) {
                printf "%s", block
            }
        }
    ' "$SOURCE_CONFIG" > "$TMP_CONFIG"; then
        rm -f "$SMTP_BLOCK_FILE" "$TMP_CONFIG" "$CLEAN_CONFIG"
        return 1
    fi

    cp "$TMP_CONFIG" "$VPN_CONFIG_FILE"
    rm -f "$SMTP_BLOCK_FILE" "$TMP_CONFIG" "$CLEAN_CONFIG"
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

RELEASE_REPO="akromjon/wireguard-api"

detect_binary_filename() {
    case "$(uname -sm)" in
        "Linux x86_64") echo "wireguard-linux-amd64" ;;
        "Linux i686")   echo "wireguard-linux-386" ;;
        "Linux armv7l") echo "wireguard-linux-arm" ;;
        "Linux aarch64") echo "wireguard-linux-arm64" ;;
        *) echo "" ;;
    esac
}

# Migrate an EXISTING node to the /16 allocator. Idempotent and non-destructive:
#   1) pull the latest wireguard-api binary and swap it in
#   2) restart the API service
#   3) widen the VPN interface from /24 to /16 (config + live) so the new
#      allocator's 10.x.0.x addresses route
#   4) widen firewalld masquerade if firewalld is in use (iptables MASQUERADE is
#      already unscoped, so nothing to do there)
# Existing peers (within the /16) are never touched or renumbered.
#
#   sudo ./install.sh sixteen-allocator                    # pulls latest release
#   SIXTEEN_TAG=v1.1.0 sudo ./install.sh sixteen-allocator # pin a specific tag
migrate_to_sixteen_allocator() {
    local TAG="${SIXTEEN_TAG:-latest}"
    local INSTALL_DIR="/usr/local/bin"
    local NIC CONF IP WG_SVC FILENAME URL TMP

    echo -e "${GREEN}== Sixteen-allocator migration ==${NC}"

    # 1. Detect VPN backend, interface, config, server IPv4.
    if [[ -f /etc/amnezia/amneziawg/params ]]; then
        # shellcheck disable=SC1091
        source /etc/amnezia/amneziawg/params
        NIC="${SERVER_AWG_NIC}"; IP="${SERVER_AWG_IPV4}"
        CONF="/etc/amnezia/amneziawg/${NIC}.conf"; WG_SVC="awg-quick@${NIC}"
    elif [[ -f /etc/wireguard/params ]]; then
        # shellcheck disable=SC1091
        source /etc/wireguard/params
        NIC="${SERVER_WG_NIC}"; IP="${SERVER_WG_IPV4}"
        CONF="/etc/wireguard/${NIC}.conf"; WG_SVC="wg-quick@${NIC}"
    else
        echo -e "${RED}No WireGuard/AmneziaWG params found — is this node installed?${NC}"; return 1
    fi
    if [[ -z "$NIC" || -z "$IP" || ! -f "$CONF" ]]; then
        echo -e "${RED}Could not resolve interface ($NIC), IP ($IP) or config ($CONF).${NC}"; return 1
    fi
    echo -e "${YELLOW}Backend interface=${NIC} ip=${IP} conf=${CONF}${NC}"

    # 2. Download + swap the new binary.
    FILENAME="$(detect_binary_filename)"
    [[ -z "$FILENAME" ]] && { echo -e "${RED}Unsupported arch: $(uname -sm)${NC}"; return 1; }
    if [[ "$TAG" == "latest" ]]; then
        URL="https://github.com/${RELEASE_REPO}/releases/latest/download/${FILENAME}"
    else
        URL="https://github.com/${RELEASE_REPO}/releases/download/${TAG}/${FILENAME}"
    fi
    TMP="$(mktemp)"
    echo -e "${YELLOW}Downloading ${FILENAME} (${TAG})...${NC}"
    if ! curl -sSLf "$URL" -o "$TMP" || [[ ! -s "$TMP" ]]; then
        echo -e "${RED}Download failed or empty: ${URL}${NC}"; rm -f "$TMP"; return 1
    fi
    chmod +x "$TMP"
    mv "$TMP" "${INSTALL_DIR}/wireguard" && chmod +x "${INSTALL_DIR}/wireguard"
    echo -e "${GREEN}Binary updated: ${INSTALL_DIR}/wireguard${NC}"

    # 3. Restart the API service.
    systemctl restart wireguard.service 2>/dev/null || true
    if systemctl is-active --quiet wireguard.service; then
        echo -e "${GREEN}wireguard.service restarted.${NC}"
    else
        echo -e "${YELLOW}Warning: wireguard.service not active — journalctl -u wireguard.service${NC}"
    fi

    # 4. Widen the interface to /16 — persist in config (IPv4 only; leave IPv6 /64).
    if grep -qE "^Address = ${IP}/16([,/[:space:]]|$)" "$CONF"; then
        echo -e "${GREEN}Config already /16.${NC}"
    else
        sed -i -E "s#^(Address = ${IP})/24#\1/16#" "$CONF"
        echo -e "${GREEN}Config Address set to ${IP}/16.${NC}"
    fi
    # Apply live (does NOT drop tunnels — peers are independent of the iface addr).
    ip addr del "${IP}/24" dev "${NIC}" 2>/dev/null || true
    ip addr replace "${IP}/16" dev "${NIC}"
    echo -e "${GREEN}Live interface set to ${IP}/16.${NC}"

    # 5. firewalld masquerade widening (only if firewalld is active).
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        local NET16 NET24
        NET16="$(echo "$IP" | cut -d. -f1-2).0.0/16"
        NET24="$(echo "$IP" | cut -d. -f1-3).0/24"
        firewall-cmd --remove-rich-rule="rule family=ipv4 source address=${NET24} masquerade" 2>/dev/null || true
        firewall-cmd --add-rich-rule="rule family=ipv4 source address=${NET16} masquerade" 2>/dev/null || true
        firewall-cmd --runtime-to-permanent 2>/dev/null || true
        echo -e "${GREEN}firewalld masquerade widened to ${NET16}.${NC}"
    fi

    # 6. Verify.
    echo -e "${YELLOW}Verification:${NC}"
    if ip -4 addr show "$NIC" | grep -qE "inet ${IP}/16"; then
        echo -e "${GREEN}  ✓ interface ${NIC} is ${IP}/16${NC}"
    else
        echo -e "${RED}  ✗ interface ${NIC} is NOT /16 — check manually${NC}"
    fi
    echo -e "${GREEN}Migration complete. New users allocate across the /16 (~64k addresses).${NC}"
    echo -e "${YELLOW}Next: raise this server's max_connections in the panel to a resource-realistic value.${NC}"
    return 0
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root${NC}"
  exit 1
fi

# Subcommand: migrate an existing node to the /16 allocator (no full reinstall).
if [[ "${1:-}" == "sixteen-allocator" ]]; then
    migrate_to_sixteen_allocator
    exit $?
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
