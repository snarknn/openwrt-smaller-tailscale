## OpenWRT Smaller Tailscale

> [!WARNING]
> This script generates binaries automatically and does not come with any warranty. As of the time of writing, `Tailscale v1.84.2` works fine on `Xiaomi Mi Router 4A Gigabit Edition` (≈8512 KiB storage) running `OpenWrt 22.03.2 r19803-9a599fee93`. Proceed with caution and use this software at your own risk.

> [!NOTE]
> This project is not affiliated with Tailscale. Use at your own risk.


## Installation

### Quick install (recommended)

You can install or update Tailscale in one command directly on your OpenWRT router:

```sh
sh <(wget -O - https://raw.githubusercontent.com/snarknn/openwrt-smaller-tailscale/main/install.sh)
```

This script will automatically:
- Download the latest compatible Tailscale build
- Install required dependencies
- Set up the network and firewall
- Start and enable Tailscale

Follow the prompts in the script to complete authentication.

### Environment Variables

You can customize the installation by setting environment variables:

- **`TAILSCALE_ADVERTISE_ROUTE`** - Specify CIDR route(s) to advertise to your Tailnet (e.g., `192.168.1.0/24`). Multiple routes can be comma-separated (e.g., `192.168.1.0/24,10.0.0.0/24`). If not set, no routes will be advertised.
- **`TAILSCALE_LOGIN_SERVER`** - Custom control server URL (e.g., `https://headscale.example.com`). If not set during upgrades, the installer tries to reuse the current control server from the existing Tailscale prefs.

**Examples:**

```sh
# Install with route advertising
TAILSCALE_ADVERTISE_ROUTE="192.168.1.0/24" sh <(wget -O - https://raw.githubusercontent.com/snarknn/openwrt-smaller-tailscale/main/install.sh)

# Install with multiple routes
TAILSCALE_ADVERTISE_ROUTE="192.168.1.0/24,10.0.0.0/24" sh <(wget -O - https://raw.githubusercontent.com/snarknn/openwrt-smaller-tailscale/main/install.sh)

# Install with a custom login server (headscale)
TAILSCALE_LOGIN_SERVER="https://headscale.example.com" sh <(wget -O - https://raw.githubusercontent.com/snarknn/openwrt-smaller-tailscale/main/install.sh)

# Install without route advertising (default)
sh <(wget -O - https://raw.githubusercontent.com/snarknn/openwrt-smaller-tailscale/main/install.sh)
```

---

### Manual installation (advanced)

1. Update packages & Install required dependencies:

   ```sh
   opkg update
   opkg install kmod-tun iptables-nft
   ```

2. From your local machine, download the appropriate tarball from
   [Releases](https://github.com/snarknn/openwrt-smaller-tailscale/releases), then copy it to the router’s `/tmp` folder with a simple name:

   ```sh
   scp -O tailscale_<version>_<arch>.tar.gz root@192.168.1.1:/tmp/tailscale.tar.gz
   ```

3. On the router, extract it to root:

   ```sh
   tar x -zvC / -f /tmp/tailscale.tar.gz
   ```

4. Start Tailscale:

   ```sh
   /etc/init.d/tailscale start
   tailscale up --accept-dns=false --netfilter-mode=off

   # For headscale, add your control server URL:
   # tailscale up --accept-dns=false --netfilter-mode=off --login-server=https://headscale.example.com
   ```

5. Enable on boot:

   ```sh
   /etc/init.d/tailscale enable
   ls /etc/rc.d/S*tailscale*  # should show an entry
   ```


## Final Setup (Required via LuCI)

To finish the integration, do the following in the **LuCI web interface**:

1. **Network → Interfaces → Add New Interface**
    * Name: `tailscale`
    * Protocol: `Unmanaged`
    * Interface: `tailscale0`

2. **Network → Firewall → Zones → Add**
    * Name: `tailscale`
    * Input: `ACCEPT` (default)
    * Output: `ACCEPT` (default)
    * Forward: `ACCEPT`
    * Masquerading: `on`
    * MSS Clamping: `on`
    * Covered networks: `tailscale`
    * Add forwardings:
      * Allow forward to destination zones: Select your `LAN` (and/or other internal zones or `WAN` if you plan on using this device as an exit node)
      *  Allow forward from source zones: Select your `LAN` (and/or other internal zones or leave it blank if you do not want to route `LAN` traffic to other tailscale hosts)


Source: [OpenWRT Tailscale Wiki](https://openwrt.org/docs/guide-user/services/vpn/tailscale/start#initial_setup)
