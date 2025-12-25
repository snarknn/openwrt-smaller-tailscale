#!/bin/sh

# Exit on error
set -e

RELEASE_INFO_FILE=""
DOWNLOAD_FILE=""
BACKUP_DIR=""

cleanup() {
    if [ -n "$RELEASE_INFO_FILE" ] && [ -f "$RELEASE_INFO_FILE" ]; then
        rm -f "$RELEASE_INFO_FILE"
    fi
    if [ -n "$DOWNLOAD_FILE" ] && [ -f "$DOWNLOAD_FILE" ]; then
        rm -f "$DOWNLOAD_FILE"
    fi
    if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
        rm -rf "$BACKUP_DIR"
    fi
}
trap cleanup EXIT

# Ensure latest release JSON is available locally
ensure_release_info() {
    if [ -n "$RELEASE_INFO_FILE" ] && [ -f "$RELEASE_INFO_FILE" ]; then
        return 0
    fi

    local api_url="https://api.github.com/repos/snarknn/openwrt-smaller-tailscale/releases/latest"
    RELEASE_INFO_FILE=$(mktemp /tmp/tailscale_release.XXXXXX)
    if ! wget -qO "$RELEASE_INFO_FILE" --header="Accept: application/vnd.github.v3+json" "$api_url"; then
        echo "Error: Failed to get release info from GitHub" >&2
        rm -f "$RELEASE_INFO_FILE"
        RELEASE_INFO_FILE=""
        return 1
    fi
}

# Helper to extract data from release JSON via jsonfilter
json_query() {
    jsonfilter -i "$RELEASE_INFO_FILE" -e "$1" 2>/dev/null
}

find_asset_url_by_name() {
    local needle="$1" idx=0 name
    while true; do
        name=$(json_query "@.assets[$idx].name") || break
        [ -z "$name" ] && break
        if [ "$name" = "$needle" ]; then
            json_query "@.assets[$idx].browser_download_url"
            return 0
        fi
        idx=$((idx + 1))
    done
    return 1
}

# Normalize version string (remove 'v' prefix)
normalize_version() { echo "${1#v}"; }

get_latest_version() {
    ensure_release_info || return 1
    local ver=$(json_query '@.tag_name')
    ver=$(normalize_version "$ver")
    [ -z "$ver" ] && echo "Error: Failed to parse version from GitHub response" >&2 && return 1
    echo "$ver"
}

get_release_asset_url() {
    [ -z "$1" ] || [ -z "$2" ] && return 1
    ensure_release_info || return 1

    local version="$1" arch="$2" target="tailscale_${version}_${arch}.tar.gz" url

    if url=$(find_asset_url_by_name "$target"); then
        echo "$url"
        return 0
    fi

    if [ "$arch" = "arm64" ]; then
        local fallback="tailscale_${version}_arm.tar.gz"
        if url=$(find_asset_url_by_name "$fallback"); then
            echo "Warning: arm64 asset missing, falling back to arm." >&2
            echo "$url"
            return 0
        fi
    fi

    echo "Error: No compatible package found for $arch" >&2
    local available=$(json_query '@.assets[*].name')
    [ -n "$available" ] && printf 'Available assets:%s' "\n$available" >&2
    return 1
}

# Check if firewall zone/forwarding exists
tailscale_zone_exists() {
    uci show firewall | sed -n 's/^firewall\.\([^=]*\)=zone$/\1/p' | while read z; do
        [ "$(uci -q get firewall.$z.name)" = "tailscale" ] && return 0
    done; return 1
}

# Check if running on OpenWRT
if [ ! -f /etc/openwrt_version ]; then
    echo "Error: This script must be run on OpenWRT"
    exit 1
fi

echo "OpenWRT Smaller Tailscale Installer"
echo "==================================="

get_arch() {
    case $(uname -m) in
        x86_64) echo "amd64";;
        aarch64|armv8*) echo "arm64";;
        arm*|armv7*) echo "arm";;
        mips) echo "mips";;
        mipsel) echo "mipsle";;
        *) echo "unknown";;
    esac
}

install_dependencies() {
    echo "Updating packages..." && opkg update
    echo "Checking and installing dependencies..."
    for pkg in kmod-tun iptables-nft wget jsonfilter ca-bundle ca-certificates; do
        if ! opkg list-installed | grep -q "^$pkg - "; then
            echo "Installing $pkg..."
            opkg install "$pkg"
        else
            echo "$pkg is already installed"
        fi
    done
}

configure_network() {
    uci show network.tailscale >/dev/null 2>&1 && echo "Network interface exists, skipping" && return
    echo "Configuring network..."
    uci set network.tailscale=interface
    uci set network.tailscale.proto='unmanaged'
    uci set network.tailscale.device='tailscale0'
    uci commit network
}

forwarding_rule_exists() {
    local sections=$(uci show firewall | sed -n 's/^firewall\.\([^=]*\)=forwarding$/\1/p')
    for fwd in $sections; do
        [ "$(uci -q get firewall.$fwd.src 2>/dev/null)" = "$1" ] && \
        [ "$(uci -q get firewall.$fwd.dest 2>/dev/null)" = "$2" ] && return 0
    done; return 1
}

add_forwarding() {
    forwarding_rule_exists "$1" "$2" || {
        uci add firewall forwarding
        uci set firewall.@forwarding[-1].src="$1"
        uci set firewall.@forwarding[-1].dest="$2"
        uci set firewall.@forwarding[-1].name="tailscale_${1}_to_${2}"
    }
}

configure_firewall() {
    if ! tailscale_zone_exists; then
        echo "Configuring firewall..."
        uci add firewall zone
        uci set firewall.@zone[-1].name='tailscale'
        uci set firewall.@zone[-1].input='ACCEPT'
        uci set firewall.@zone[-1].output='ACCEPT'
        uci set firewall.@zone[-1].forward='ACCEPT'
        uci set firewall.@zone[-1].masq='1'
        uci set firewall.@zone[-1].mtu_fix='1'
        uci add_list firewall.@zone[-1].network='tailscale'
    fi
    add_forwarding 'tailscale' 'lan'
    add_forwarding 'lan' 'tailscale'
    uci commit firewall
}

# Main installation process
main() {
    local arch=$(get_arch)
    if [ "$arch" = "unknown" ]; then
        echo "Error: Unsupported architecture"
        exit 1
    fi

    # Install dependencies
    install_dependencies

    # Get latest version
    local version
    if ! version=$(get_latest_version); then
        echo "Error: Failed to get latest version"
        exit 1
    fi
    echo "Latest version: $version"

    local asset_url
    if ! asset_url=$(get_release_asset_url "$version" "$arch"); then
        echo "Error: Failed to determine download URL for architecture $arch"
        exit 1
    fi

    # Check if Tailscale is already installed and get current version
    local current_version=""
    local is_upgrade=0
    if [ -f /usr/bin/tailscale ]; then
        # Get the first line of version output which contains just the version number
        current_version=$(/usr/bin/tailscale version 2>/dev/null | head -n1)
        current_version=$(normalize_version "$current_version")
        if [ -n "$current_version" ]; then
            is_upgrade=1
            echo "Current version: $current_version"
        else
            echo "Warning: Could not determine current version"
        fi
    fi

    # Normalize both versions for comparison
    local normalized_new_version=$(normalize_version "$version")
    local needs_install=1
    if [ "$current_version" = "$normalized_new_version" ]; then
        echo "Latest version already installed."
        # Check if configuration is complete
        if ! uci show network.tailscale >/dev/null 2>&1 || ! tailscale_zone_exists; then
            echo "But configuration is incomplete, fixing..."
            is_upgrade=0  # Treat as first install to complete setup
            needs_install=0
        else
            exit 0
        fi
    fi

    if [ $needs_install -eq 1 ]; then
        echo "Downloading Tailscale ${version} for ${arch}..."
        DOWNLOAD_FILE="/tmp/tailscale_${version}_${arch}.tar.gz"

        if ! wget -O "$DOWNLOAD_FILE" "$asset_url"; then
            echo "Error: Failed to download Tailscale" >&2
            exit 1
        fi

        # Verify the downloaded file exists and is not empty
        if [ ! -f "$DOWNLOAD_FILE" ] || [ ! -s "$DOWNLOAD_FILE" ]; then
            echo "Error: Downloaded file is missing or empty" >&2
            exit 1
        fi

        echo "Download completed successfully ($(du -h "$DOWNLOAD_FILE" | cut -f1))"

        # Create backup if upgrading
        if [ $is_upgrade -eq 1 ]; then
            echo "Creating backup of current installation..."
            BACKUP_DIR="/tmp/tailscale_backup_$(date +%s)"
            mkdir -p "$BACKUP_DIR"

            # Backup binaries and init script
            [ -f /usr/bin/tailscale ] && cp /usr/bin/tailscale "$BACKUP_DIR/tailscale" 2>/dev/null || true
            [ -f /usr/bin/tailscaled ] && cp /usr/bin/tailscaled "$BACKUP_DIR/tailscaled" 2>/dev/null || true
            [ -f /etc/init.d/tailscale ] && cp /etc/init.d/tailscale "$BACKUP_DIR/tailscale.init" 2>/dev/null || true

            echo "Stopping Tailscale service for upgrade..."
            /etc/init.d/tailscale stop 2>/dev/null || true
            sleep 2
        fi

        # Rollback helper
        do_rollback() {
            [ $is_upgrade -eq 1 ] && [ -d "$BACKUP_DIR" ] && {
                echo "Restoring backup..." >&2
                [ -f "$BACKUP_DIR/tailscale" ] && cp "$BACKUP_DIR/tailscale" /usr/bin/tailscale 2>/dev/null || true
                [ -f "$BACKUP_DIR/tailscaled" ] && cp "$BACKUP_DIR/tailscaled" /usr/bin/tailscaled 2>/dev/null || true
                [ -f "$BACKUP_DIR/tailscale.init" ] && cp "$BACKUP_DIR/tailscale.init" /etc/init.d/tailscale 2>/dev/null || true
                /etc/init.d/tailscale start 2>/dev/null || true
            }
        }

        echo "Installing Tailscale..."
        if ! tar x -zvC / -f "$DOWNLOAD_FILE"; then
            echo "Error: Failed to extract" >&2; do_rollback; exit 1
        fi

        if [ ! -f /usr/bin/tailscale ] || [ ! -f /usr/bin/tailscaled ]; then
            echo "Error: Binaries not found" >&2; do_rollback; exit 1
        fi

        rm -f "$DOWNLOAD_FILE" && DOWNLOAD_FILE=""

        if [ $is_upgrade -eq 1 ] && [ -d "$BACKUP_DIR" ]; then
            rm -rf "$BACKUP_DIR"
            BACKUP_DIR=""
        fi
    else
        echo "Skipping download: binaries already up to date."
    fi

    if [ $is_upgrade -eq 1 ]; then
        /etc/init.d/tailscale start && echo "Upgrade complete!"
    else
        /etc/init.d/tailscale start
        echo "Authenticating... (visit the URL in your browser)"

        # Optional advertise-routes via environment variable
        local advertise_route="${TAILSCALE_ADVERTISE_ROUTE:-}"
        if [ -n "$advertise_route" ]; then
            echo "Advertising route: $advertise_route"
            tailscale up --accept-dns=false --netfilter-mode=off --advertise-routes="$advertise_route" || { echo "Error: Authentication failed" >&2; exit 1; }
        else
            tailscale up --accept-dns=false --netfilter-mode=off || { echo "Error: Authentication failed" >&2; exit 1; }
        fi

        /etc/init.d/tailscale enable
        ls /etc/rc.d/S*tailscale* >/dev/null 2>&1 || { echo "Error: Autostart failed" >&2; exit 1; }

        configure_network
        configure_firewall
        /etc/init.d/network reload; /etc/init.d/firewall reload

        echo "Installation complete!"
    fi
}

# Run the installation
main