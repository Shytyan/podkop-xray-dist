#!/bin/sh
# shellcheck shell=dash
# ==============================================================================
# Podkop (Xray-core Edition) - Single Command Unified Installer & Upgrader
# Repository: https://github.com/Shytyan/podkop-xray-dist
# ==============================================================================

set -e

RELEASE_DOWNLOAD="https://github.com/Shytyan/podkop-xray-dist/releases/latest/download"
RELEASE_API="https://api.github.com/repos/Shytyan/podkop-xray-dist/releases/latest"
RELEASE_JSON="/tmp/podkop_release.json"
GITHUB_BLOCKED=0 # set once github.com fails and the api.github.com route works
XRAY_REPO="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
XRAY_RELEASES="https://api.github.com/repos/XTLS/Xray-core/releases?per_page=1"
DOWNLOAD_DIR="/tmp/podkop_install"
REQUIRED_SPACE_KB=46080 # 45MB in KB
NON_INTERACTIVE=0
FORCE_RU=0
# Xray-core release podkop is tested with; installed by default (see install_xray)
XRAY_PINNED_VERSION="v26.10.21"
XRAY_MODE="pinned" # pinned | latest | prerelease | version
XRAY_VERSION=""
NO_DOH_PROXY=0

# ANSI colors
c_green='\033[32;1m'
c_yellow='\033[33;1m'
c_red='\033[31;1m'
c_blue='\033[36;1m'
c_reset='\033[0m'

msg() {
    printf "%b%s%b\n" "$c_green" "$1" "$c_reset"
}

warn() {
    printf "%b%s%b\n" "$c_yellow" "$1" "$c_reset"
}

err() {
    printf "%b%s%b\n" "$c_red" "$1" "$c_reset" >&2
}

info() {
    printf "%b%s%b\n" "$c_blue" "$1" "$c_reset"
}

# Parse command line options
for arg in "$@"; do
    case "$arg" in
        -y|--yes|--non-interactive)
            NON_INTERACTIVE=1
            ;;
        --ru|ru)
            FORCE_RU=1
            ;;
        --xray-prerelease)
            XRAY_MODE="prerelease"
            ;;
        --xray-latest)
            XRAY_MODE="latest"
            ;;
        --xray-version=*)
            XRAY_MODE="version"
            XRAY_VERSION="${arg#--xray-version=}"
            XRAY_VERSION="v${XRAY_VERSION#v}"
            ;;
        --no-doh-proxy)
            NO_DOH_PROXY=1
            ;;
        -h|--help)
            echo "Usage: sh install.sh [-y] [--ru]"
            echo "  -y, --yes: Non-interactive mode (auto-confirm wipe and install)"
            echo "  --xray-latest: Install the latest stable Xray-core (default: the version podkop is tested with)"
            echo "  --xray-prerelease: Install the newest Xray-core including pre-releases"
            echo "  --xray-version=X: Install the given Xray-core version, e.g. --xray-version=26.3.27"
            echo "  --no-doh-proxy: Do not install https-dns-proxy (DNS queries other than A/AAAA then go through the proxy to 1.1.1.1)"
            echo "  --ru:      Install the Russian language pack (luci-i18n-podkop-ru); with -y the default is English"
            exit 0
            ;;
        *)
            ;;
    esac
done

# Detect package manager
PKG_IS_APK=0
command -v apk >/dev/null 2>&1 && PKG_IS_APK=1

pkg_update() {
    msg "Updating package database..."
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk update || true
    else
        opkg update || true
    fi
}

pkg_install_name() {
    local pkg_name="$1"
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk add "$pkg_name"
    else
        opkg install "$pkg_name"
    fi
}

# Installs a package file; any failure aborts the installer (no silent fallbacks)
pkg_install_file() {
    local pkg_file="$1" rc=0
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk add --allow-untrusted "$pkg_file" || rc=$?
    else
        opkg install "$pkg_file" || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        err "Error: failed to install $(basename "$pkg_file") (exit code $rc). See the package manager output above."
        exit 1
    fi
}

# Downloads URL to file; fails on HTTP errors and empty files
fetch_file() {
    local url="$1" out="$2"
    rm -f "$out"
    # up to 10 minutes per attempt: the ~20 MB Xray archive over a slow link
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 1 --connect-timeout 15 -m 600 -o "$out" "$url" || { rm -f "$out"; return 1; }
    else
        wget -q -O "$out" "$url" || { rm -f "$out"; return 1; }
    fi
    [ -s "$out" ]
}

# release_asset_info <name>: "<api url> <sha256>" of an asset of our latest release (from the GitHub API)
release_asset_info() {
    local name="$1"
    if [ ! -s "$RELEASE_JSON" ]; then
        curl -fsSL --connect-timeout 15 -m 60 -o "$RELEASE_JSON" "$RELEASE_API" 2>/dev/null || { rm -f "$RELEASE_JSON"; return 1; }
    fi
    tr ',{}' '\n\n\n' < "$RELEASE_JSON" | awk -v want="$name" '
        /"url": *"https:\/\/api\.github\.com\/repos\/[^"]*\/releases\/assets\/[0-9]+"/ {
            if (found) exit
            url = $0; sub(/^[^:]*: *"/, "", url); sub(/".*/, "", url)
        }
        /"name": *"/ { n = $0; sub(/^[^:]*: *"/, "", n); sub(/".*/, "", n); if (n == want && url != "") found = 1 }
        found && /"digest": *"sha256:/ { d = $0; sub(/.*sha256:/, "", d); sub(/".*/, "", d); print url, d; done = 1; exit }
        END { if (found && !done) print url, "" }'
}

# fetch_release_asset <name> <file>: an asset of our latest release. github.com first; if it is blocked
# (some ISPs block github.com:443 but not *.githubusercontent.com), the GitHub API, which redirects to
# release-assets.githubusercontent.com. That needs curl (Accept header); the file is checked against the API sha256.
fetch_release_asset() {
    local name="$1" out="$2" info url sum
    [ "$GITHUB_BLOCKED" -eq 0 ] && fetch_file "$RELEASE_DOWNLOAD/$name" "$out" && return 0
    if ! command -v curl >/dev/null 2>&1; then
        warn "github.com is not reachable, installing curl to download through api.github.com..."
        pkg_update
        pkg_install_name curl >/dev/null 2>&1 || return 1
    fi
    info="$(release_asset_info "$name" || true)"
    url="${info% *}"
    sum="${info#* }"
    [ -n "$url" ] || return 1
    [ "$GITHUB_BLOCKED" -eq 1 ] || warn "github.com is not reachable, downloading through api.github.com"
    rm -f "$out"
    curl -fsSL --retry 1 --connect-timeout 15 -m 600 -H "Accept: application/octet-stream" -o "$out" "$url" || { rm -f "$out"; return 1; }
    [ -s "$out" ] || return 1
    if [ -n "$sum" ] && command -v sha256sum >/dev/null 2>&1 && [ "$(sha256sum "$out" | awk '{print $1}')" != "$sum" ]; then
        err "Error: checksum mismatch for $name"
        rm -f "$out"
        return 1
    fi
    GITHUB_BLOCKED=1
}

pkg_remove() {
    local pkg_name="$1"
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk del "$pkg_name" 2>/dev/null || true
    else
        opkg remove --force-depends "$pkg_name" 2>/dev/null || true
    fi
}

check_system() {
    info "==> Step 1: System Validation"

    # 1. Root check
    if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
        err "Error: Installer must be run as root."
        exit 1
    fi

    # 2. Package manager check
    if [ "$PKG_IS_APK" -eq 0 ] && ! command -v opkg >/dev/null 2>&1; then
        err "Error: Neither opkg nor apk package manager found."
        exit 1
    fi

    # 3. Model display
    if [ -f /tmp/sysinfo/model ]; then
        msg "Router model: $(cat /tmp/sysinfo/model)"
    fi

    # 4. OpenWrt version check
    local openwrt_ver=""
    if [ -f /etc/os-release ]; then
        openwrt_ver="$(grep -E '^VERSION_ID=' /etc/os-release | cut -d'"' -f2 | cut -d'.' -f1)"
    elif [ -f /etc/openwrt_release ]; then
        openwrt_ver="$(grep -E 'DISTRIB_RELEASE=' /etc/openwrt_release | cut -d"'" -f2 | cut -d'.' -f1)"
    fi

    if [ -n "$openwrt_ver" ]; then
        case "$openwrt_ver" in
            2[4-9]*|[3-9][0-9]*)
                # >= 24 OK
                ;;
            *)
                err "Error: OpenWrt $openwrt_ver is not supported."
                err "Podkop (Xray edition) requires OpenWrt >= 24.10 (nftables & Xray-core support)."
                exit 1
                ;;
        esac
    fi

    # 5. Check free flash space
    local avail_kb=0
    if [ -d /overlay ]; then
        avail_kb="$(df -k /overlay 2>/dev/null | awk 'NR==2 {print $4}')"
    fi
    if [ -z "$avail_kb" ] || [ "$avail_kb" -eq 0 ]; then
        avail_kb="$(df -k / 2>/dev/null | awk 'NR==2 {print $4}')"
    fi

    if [ -n "$avail_kb" ] && [ "$avail_kb" -lt "$REQUIRED_SPACE_KB" ]; then
        err "Error: Insufficient flash storage."
        err "Available: $((avail_kb / 1024)) MB, Required: $((REQUIRED_SPACE_KB / 1024)) MB."
        exit 1
    fi

    # 6. Check DNS
    if ! nslookup github.com >/dev/null 2>&1 && ! nslookup api.github.com >/dev/null 2>&1; then
        warn "DNS resolution check failed for github.com. Testing raw IP..."
        if ! ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 && ! ping -c 1 -W 2 77.88.8.8 >/dev/null 2>&1; then
            err "Error: Network is unreachable. Please verify router internet connection."
            exit 1
        fi
    fi

    # 7. Check clock / NTP
    local cur_year
    cur_year="$(date +%Y)"
    if [ "$cur_year" -lt 2025 ]; then
        warn "System clock ($cur_year) is outdated. Synchronizing time..."
        if command -v ntpd >/dev/null 2>&1; then
            ntpd -q -p pool.ntp.org -p time.google.com 2>/dev/null || true
        fi
        /etc/init.d/sysntpd restart 2>/dev/null || true
    fi
    msg "System validation passed."
}

confirm_wipe() {
    info "==> Step 2: Confirmation"
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        warn "Non-interactive mode: proceeding with full purge and installation."
        return 0
    fi

    printf "\033[48;5;196m\033[1m╔══════════════════════════════════════════════════════════════════════╗\033[0m\n"
    printf "\033[48;5;196m\033[1m║ ВНИМАНИЕ! Существующая установка Podkop и sing-box будет удалена.   ║\033[0m\n"
    printf "\033[48;5;196m\033[1m║ Предыдущие настройки будут сброшены.                                 ║\033[0m\n"
    printf "\033[48;5;196m\033[1m║ Резервная копия конфигурации сохранится в /etc/config/podkop.bak-*   ║\033[0m\n"
    printf "\033[48;5;196m\033[1m║                                                                      ║\033[0m\n"
    printf "\033[48;5;196m\033[1m║ WARNING! Any existing Podkop & sing-box setup will be purged.        ║\033[0m\n"
    printf "\033[48;5;196m\033[1m║ All previous settings will be reset.                                 ║\033[0m\n"
    printf "\033[48;5;196m\033[1m║ A backup of your current config will be in /etc/config/podkop.bak-*  ║\033[0m\n"
    printf "\033[48;5;196m\033[1m╚══════════════════════════════════════════════════════════════════════╝\033[0m\n"
    echo ""

    printf "%bВведите 'yes' для продолжения (Type 'yes' to proceed): %b" "$c_yellow" "$c_reset"
    read -r ANSWER
    case "$ANSWER" in
        yes|Yes|YES|y|Y|да|Да|ДА)
            msg "Подтверждено / Confirmed. Продолжаем..."
            ;;
        *)
            warn "Установка отменена пользователем. Никаких изменений не внесено."
            exit 0
            ;;
    esac
}

purge_old_podkop() {
    info "==> Step 4: Purging Old Podkop, Sing-box & Conflicting Components"

    # Backup existing config and remove for clean default install
    if [ -f /etc/config/podkop ]; then
        local bak_path="/etc/config/podkop.bak-$(date +%Y%m%d-%H%M%S)"
        cp -f /etc/config/podkop "$bak_path"
        rm -f /etc/config/podkop
        msg "Current config backed up to $bak_path and reset to default"
    fi

    # 1. Stop and disable podkop service
    if [ -x /etc/init.d/podkop ]; then
        /etc/init.d/podkop stop >/dev/null 2>&1 || true
        /etc/init.d/podkop disable >/dev/null 2>&1 || true
    fi

    # 2. Cleanup nftables and routing
    nft delete table inet PodkopTable >/dev/null 2>&1 || true
    ip rule del fwmark 0x00100000/0x00100000 table podkop priority 105 >/dev/null 2>&1 || true
    ip route flush table podkop >/dev/null 2>&1 || true
    if [ -f /etc/iproute2/rt_tables ]; then
        sed -i '/105 podkop/d' /etc/iproute2/rt_tables 2>/dev/null || true
    fi

    # 3. Clean cron jobs
    if [ -f /etc/crontabs/root ]; then
        sed -i '/podkop/d' /etc/crontabs/root 2>/dev/null || true
        /etc/init.d/cron restart >/dev/null 2>&1 || true
    fi

    # 4. Remove conflicting and legacy packages
    for pkg in \
        luci-i18n-podkop-ru luci-i18n-podkop-en \
        luci-app-podkop podkop \
        sing-box \
        https-dns-proxy luci-app-https-dns-proxy luci-i18n-https-dns-proxy-ru \
        xray-example; do
        pkg_remove "$pkg"
    done

    # 5. Remove leftover directories and files
    rm -rf /etc/config/podkop-070 \
           /etc/podkop \
           /usr/lib/podkop \
           /usr/bin/podkop \
           /usr/bin/sing-box \
           /etc/init.d/podkop \
           /etc/init.d/sing-box \
           /www/luci-static/resources/view/podkop \
           /usr/share/luci/menu.d/luci-app-podkop.json \
           /usr/share/rpcd/acl.d/luci-app-podkop.json \
           /usr/lib/lua/luci/i18n/podkop.*.lmo \
           /etc/uci-defaults/*podkop* \
           /tmp/podkop.run* /tmp/podkop_traffic* /tmp/podkop_test* /tmp/xray /tmp/sing-box /var/run/podkop* /etc/sing-box \
           /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null || true

    msg "Purge completed."
}

install_deps() {
    info "==> Step 5: Installing System Dependencies"
    pkg_update

    local deps="curl jq bind-dig unzip kmod-nft-tproxy coreutils-base64 luci-base"
    for d in $deps; do
        msg "Installing dependency: $d"
        pkg_install_name "$d" || warn "Warning: Failed to install $d (might already be built-in)"
    done
}

# Tag of the newest Xray-core release: stable, or including pre-releases with --xray-prerelease.
# GitHub API first, then github.com pages (API rate limit for a shared IP).
xray_latest_tag() {
    local api_url="$XRAY_REPO" json tag=""
    [ "$XRAY_MODE" = "prerelease" ] && api_url="$XRAY_RELEASES"
    json="$(curl -fsSL -m 15 "$api_url" 2>/dev/null || true)"
    tag="$(echo "$json" | jq -r 'if type == "array" then .[0].tag_name else .tag_name end // empty' 2>/dev/null || true)"
    if [ -z "$tag" ]; then
        if [ "$XRAY_MODE" = "prerelease" ]; then
            tag="$(curl -fsSL -m 15 "https://github.com/XTLS/Xray-core/releases.atom" 2>/dev/null |
                grep -o 'releases/tag/v[0-9][0-9.]*' | head -n1 | sed 's|releases/tag/||')"
        else
            tag="$(curl -sI -m 15 "https://github.com/XTLS/Xray-core/releases/latest" 2>/dev/null | tr -d '\r' |
                sed -n 's|^[Ll]ocation: .*/releases/tag/\(v[0-9][0-9.]*\).*|\1|p' | head -n1)"
        fi
    fi
    echo "$tag"
}

# xray_fetch_binary <zip url | mirror:<asset name>> <file>: downloads the archive, extracts a complete, runnable xray binary
xray_fetch_binary() {
    local url="$1" out="$2" tmp_zip="/tmp/xray.zip" want_size have_size
    rm -f "$tmp_zip" "$out"
    case "$url" in
        mirror:*)
            msg "Downloading Xray-core ${url#mirror:} from the podkop release..."
            fetch_release_asset "${url#mirror:}" "$tmp_zip" || { rm -f "$tmp_zip"; return 1; }
            ;;
        *)
            msg "Downloading Xray-core from $url..."
            fetch_file "$url" "$tmp_zip" || { rm -f "$tmp_zip"; return 1; }
            ;;
    esac
    want_size="$(unzip -l "$tmp_zip" xray 2>/dev/null | awk '$NF == "xray" {print $1; exit}')"
    unzip -p "$tmp_zip" xray > "$out" 2>/dev/null || true
    rm -f "$tmp_zip"
    have_size="$(wc -c < "$out" 2>/dev/null | tr -d ' ')"
    if [ -z "$want_size" ] || [ "$have_size" != "$want_size" ]; then
        err "Error: Xray-core binary was not extracted completely ($have_size of $want_size bytes, /tmp full?)."
        rm -f "$out"
        return 1
    fi
    chmod +x "$out"
    if [ -z "$("$out" version 2>/dev/null | head -n1)" ]; then
        err "Error: Downloaded Xray-core binary failed execution check."
        rm -f "$out"
        return 1
    fi
}

# xray_download <zip arch> <file>: a working xray binary of the chosen version. Default: the release podkop is
# tested with (XRAY_PINNED_VERSION); if XTLS removes it, the copy in our latest release (the release workflow
# mirrors it), then the latest stable release.
xray_download() {
    local zip_arch="$1" out="$2" urls url tag_name
    case "$XRAY_MODE" in
        pinned)
            msg "Xray-core version tested with podkop: $XRAY_PINNED_VERSION"
            urls="https://github.com/XTLS/Xray-core/releases/download/${XRAY_PINNED_VERSION}/Xray-linux-${zip_arch}.zip"
            urls="$urls mirror:Xray-linux-${zip_arch}.zip latest"
            ;;
        version)
            urls="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${zip_arch}.zip"
            ;;
        *)
            urls="latest"
            ;;
    esac
    for url in $urls; do
        # github.com is blocked: only the mirror (through api.github.com) can work
        [ "$GITHUB_BLOCKED" -eq 1 ] && [ "${url#mirror:}" = "$url" ] && continue
        if [ "$url" = "latest" ]; then
            [ "$XRAY_MODE" = "pinned" ] && warn "Warning: Xray-core $XRAY_PINNED_VERSION is not available, installing the latest stable release"
            tag_name="$(xray_latest_tag)"
            if [ -n "$tag_name" ]; then
                url="https://github.com/XTLS/Xray-core/releases/download/${tag_name}/Xray-linux-${zip_arch}.zip"
            else
                url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${zip_arch}.zip"
            fi
        fi
        xray_fetch_binary "$url" "$out" && return 0
        warn "Warning: Xray-core is not available at $url"
    done
    return 1
}

install_xray() {
    info "==> Step 7: Installing Xray-core"

    local arch zip_arch
    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64)
            zip_arch="64"
            ;;
        aarch64|arm64)
            zip_arch="arm64-v8a"
            ;;
        armv7*|armhf)
            zip_arch="arm32-v7a"
            ;;
        i386|i686)
            zip_arch="32"
            ;;
        mips)
            zip_arch="mips32"
            ;;
        mipsel)
            zip_arch="mips32le"
            ;;
        *)
            err "Error: Unsupported CPU architecture '$arch' for Xray-core"
            exit 1
            ;;
    esac

    msg "Detected architecture: $arch -> Xray-linux-${zip_arch}.zip"

    # /tmp is RAM on OpenWrt: the archive (~12 MB) and the binary (~35 MB) must both fit
    local tmp_free
    tmp_free="$(df -k /tmp 2>/dev/null | awk 'NR==2 {print $4}')"
    if [ -n "$tmp_free" ] && [ "$tmp_free" -lt 61440 ]; then
        err "Error: not enough free space in /tmp for Xray-core: $((tmp_free / 1024)) MB, need 60 MB."
        err "podkop is installed and uses the xray-core package binary; free /tmp and run: podkop update_xray"
        exit 1
    fi

    local tmp_bin="/tmp/xray.new" xray_ver
    if ! xray_download "$zip_arch" "$tmp_bin"; then
        err "Error: Failed to download a working Xray-core binary."
        exit 1
    fi
    xray_ver="$("$tmp_bin" version 2>/dev/null | head -n1 | awk '{print $2}')"

    mv -f "$tmp_bin" /usr/bin/xray
    msg "Installed Xray-core $xray_ver to /usr/bin/xray"

    # Ensure /etc/init.d/xray service script exists with GOMEMLIMIT & respawn
    if [ ! -f /etc/init.d/xray ]; then
        msg "Creating /etc/init.d/xray service script..."
        cat << 'EOF' > /etc/init.d/xray
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=99

CONF="xray"
PROG="/usr/bin/xray"

start_service() {
	config_load "$CONF"

	local enabled
	config_get_bool enabled "enabled" "enabled" "0"
	[ "$enabled" -eq "1" ] || return 1

	local confdir
	local conffiles
	local datadir
	local dialer
	local format

	config_get confdir "config" "confdir"
	config_get conffiles "config" "conffiles"
	config_get datadir "config" "datadir" "/usr/share/xray"
	config_get dialer "config" "dialer"
	config_get format "config" "format" "json"

	procd_open_instance "$CONF"
	procd_set_param command "$PROG" run
	[ -n "$confdir" ] && procd_append_param command -confdir "$confdir"
	[ -n "$conffiles" ] && {
		for i in $conffiles
		do
			procd_append_param command -config "$i"
		done
	}
	[ -n "$format" ] && procd_append_param command -format "$format"
	[ -n "$dialer" ] && procd_set_param env XRAY_BROWSER_DIALER="$dialer"
	procd_set_param env XRAY_LOCATION_ASSET="$datadir"
	procd_set_param env GOMEMLIMIT="45MiB"
	procd_set_param file $conffiles

	procd_set_param limits core="unlimited"
	procd_set_param limits nofile="1000000 1000000"
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_set_param respawn 3600 5 5

	procd_close_instance
}

reload_service() {
	stop
	start
}

service_triggers() {
	procd_add_reload_trigger "$CONF"
}
EOF
        chmod +x /etc/init.d/xray
    else
        # Ensure GOMEMLIMIT and respawn exist in current init script
        grep -q "GOMEMLIMIT" /etc/init.d/xray || sed -i '/procd_set_param env XRAY_LOCATION_ASSET/a \\tprocd_set_param env GOMEMLIMIT="45MiB"' /etc/init.d/xray
        grep -q "respawn" /etc/init.d/xray || sed -i '/procd_close_instance/i \\tprocd_set_param respawn 3600 5 5' /etc/init.d/xray
    fi

    # Ensure /etc/config/xray exists
    if [ ! -f /etc/config/xray ]; then
        cat << 'EOF' > /etc/config/xray
config xray 'enabled'
	option enabled '1'

config xray 'config'
	option conffiles '/tmp/xray/config.json'
	option datadir '/usr/share/xray'
	option format 'json'
EOF
    fi
}

pkg_ext() {
    if [ "$PKG_IS_APK" -eq 1 ]; then echo apk; else echo ipk; fi
}

# Downloads the packages BEFORE the old podkop is removed: a failed download leaves the router untouched.
# Release assets with fixed names are fetched via releases/latest/download (no GitHub API, no rate limit).
fetch_packages() {
    info "==> Step 3: Downloading Podkop (Xray edition) Packages"
    local ext p
    ext="$(pkg_ext)"
    rm -rf "$DOWNLOAD_DIR"
    mkdir -p "$DOWNLOAD_DIR"

    for p in podkop luci-app-podkop luci-i18n-podkop-ru; do
        if [ -n "$PODKOP_PKG_DIR" ]; then
            # PODKOP_PKG_DIR=<dir with .ipk/.apk>: local packages (development/testing only)
            local f
            f="$(ls -1 "$PODKOP_PKG_DIR"/"$p"[-_.]*"$ext" 2>/dev/null | sort -V | tail -n1)"
            [ -n "$f" ] && cp -f "$f" "$DOWNLOAD_DIR/$p.$ext"
        else
            msg "Downloading $p.$ext..."
            fetch_release_asset "$p.$ext" "$DOWNLOAD_DIR/$p.$ext" || rm -f "$DOWNLOAD_DIR/$p.$ext"
        fi
    done

    if [ ! -s "$DOWNLOAD_DIR/podkop.$ext" ] || [ ! -s "$DOWNLOAD_DIR/luci-app-podkop.$ext" ]; then
        err "Error: could not download podkop/luci-app-podkop packages from $RELEASE_DOWNLOAD (or through api.github.com)"
        err "Check that the router can open https://github.com and https://api.github.com (some ISPs block github.com)."
        err "Nothing was changed on the router. Check the internet connection and try again."
        exit 1
    fi
    msg "Packages downloaded."
}

install_packages() {
    info "==> Step 6: Installing Podkop (Xray edition) Packages"
    local ext main_pkg luci_pkg ru_pkg
    ext="$(pkg_ext)"
    main_pkg="$DOWNLOAD_DIR/podkop.$ext"
    luci_pkg="$DOWNLOAD_DIR/luci-app-podkop.$ext"
    ru_pkg="$DOWNLOAD_DIR/luci-i18n-podkop-ru.$ext"

    msg "Installing podkop..."
    pkg_install_file "$main_pkg"

    msg "Installing luci-app-podkop..."
    pkg_install_file "$luci_pkg"

    # Russian language (separate luci-i18n-podkop-ru package, as in the original podkop)
    local install_ru=0
    if [ "$FORCE_RU" -eq 1 ]; then
        install_ru=1
    elif [ "$NON_INTERACTIVE" -eq 0 ]; then
        msg "Русский язык интерфейса ставим? y/n (Install the Russian interface language?)"
        while true; do
            read -r RU_ANSWER
            case "$RU_ANSWER" in
                y|Y|yes|Yes|д|Д|да|Да) install_ru=1; break ;;
                n|N|no|No|н|Н|нет|Нет) install_ru=0; break ;;
                *) echo "Введите y или n" ;;
            esac
        done
    fi

    if [ "$install_ru" -eq 1 ]; then
        if [ ! -s "$ru_pkg" ]; then
            err "Error: luci-i18n-podkop-ru package was not downloaded."
            exit 1
        fi
        msg "Installing luci-i18n-podkop-ru..."
        pkg_install_file "$ru_pkg"
        pkg_install_name "luci-i18n-base-ru" >/dev/null 2>&1 || warn "Warning: luci-i18n-base-ru is not installed (LuCI menus stay in English)"
        uci set luci.languages.ru='Русский (Russian)'
        uci set luci.main.lang='ru'
        uci commit luci
        msg "Russian localization activated."
    else
        msg "Interface language: English (Russian can be added later: install luci-i18n-podkop-ru from the release)."
    fi

    rm -rf "$DOWNLOAD_DIR"
}

# Local DoH proxy: DNS queries Xray cannot send over DoH (TXT, MX, SRV...) go to the main DoH server through it,
# so DNS leak tests show only the user's resolver. podkop runs it itself; the package service stays disabled.
# The config goes first: the package defaults would start it, take over dnsmasq and intercept port 53.
install_doh_proxy() {
    [ "$NO_DOH_PROXY" -eq 1 ] && return 0
    info "==> Step 7b: Installing https-dns-proxy (DNS queries other than A/AAAA over DoH)"
    if [ -x /usr/sbin/https-dns-proxy ]; then
        msg "https-dns-proxy is already installed, its configuration is left as is"
        return 0
    fi
    # A config left by an earlier https-dns-proxy (removed during the purge) may take over dnsmasq: back it up
    if [ -f /etc/config/https-dns-proxy ] && ! grep -q "Managed by podkop" /etc/config/https-dns-proxy; then
        mv /etc/config/https-dns-proxy "/etc/config/https-dns-proxy.bak-$(date +%Y%m%d-%H%M%S)"
        msg "Old https-dns-proxy configuration saved as /etc/config/https-dns-proxy.bak-<date>"
    fi
    if [ ! -f /etc/config/https-dns-proxy ]; then
        cat > /etc/config/https-dns-proxy <<'EOF'
# Managed by podkop: the package service stays disabled, podkop runs https-dns-proxy itself.
# No instances, no dnsmasq changes, no DNS hijacking.
config main 'config'
	option dnsmasq_config_update '-'
	option force_dns '0'
	option procd_trigger_wan6 '0'
EOF
    fi
    if ! pkg_install_name https-dns-proxy; then
        warn "Warning: https-dns-proxy is not installed: DNS queries other than A/AAAA will go through the proxy to 1.1.1.1"
        return 0
    fi
    /etc/init.d/https-dns-proxy stop >/dev/null 2>&1 || true
    /etc/init.d/https-dns-proxy disable >/dev/null 2>&1 || true
    msg "https-dns-proxy installed (started by podkop when the main DNS is DoH)"
}

post_install() {
    info "==> Step 8: Finalizing Installation"
    rm -f "$RELEASE_JSON"

    # Normalize line endings & permissions
    sed -i 's/\r$//' /usr/bin/podkop /etc/init.d/podkop /etc/init.d/xray /usr/lib/podkop/*.sh 2>/dev/null || true
    chmod +x /usr/bin/podkop /etc/init.d/podkop /etc/init.d/xray /usr/lib/podkop/*.sh 2>/dev/null || true

    # Clear LuCI caches and restart services
    rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null || true
    /etc/init.d/rpcd restart >/dev/null 2>&1 || true
    /etc/init.d/uhttpd restart >/dev/null 2>&1 || true

    local podkop_ver="Xray edition"
    if [ -x /usr/bin/podkop ]; then
        podkop_ver="$(/usr/bin/podkop show_version 2>/dev/null || echo "Xray edition")"
    fi
    local xray_ver="unknown"
    if [ -x /usr/bin/xray ]; then
        xray_ver="$(/usr/bin/xray version 2>/dev/null | head -n1)"
    fi

    echo ""
    msg "╔══════════════════════════════════════════════════════════════════════╗"
    msg "║   Podkop (Xray-core Edition) успешно установлен!                     ║"
    msg "╚══════════════════════════════════════════════════════════════════════╝"
    echo ""
    info "• Версия Podkop: $podkop_ver"
    info "• Ядро Xray:     $xray_ver"
    info "• Веб-интерфейс: http://$(uci -q get network.lan.ipaddr || echo "192.168.1.1")/cgi-bin/luci/admin/services/podkop"
    echo ""
    warn "Если LuCI уже был открыт, обновите страницу с Ctrl+F5: браузер кеширует старый интерфейс."
    warn "ВАЖНО: Служба Podkop не запущена автоматически."
    warn "Для запуска откройте веб-интерфейс LuCI, добавьте Outbound (Single Link: VLESS/VMess/Trojan/SS)"
    warn "и нажмите 'Сохранить и применить'."
    echo ""
}

main() {
    check_system
    confirm_wipe
    fetch_packages
    purge_old_podkop
    install_deps
    install_packages
    # after the packages: the xray-core dependency would overwrite a newer binary
    install_xray
    install_doh_proxy
    [ "$XRAY_MODE" = "prerelease" ] && uci -q set podkop.settings.xray_prerelease='1' && uci -q commit podkop
    post_install
}

# PODKOP_INSTALL_NO_MAIN=1: only define the functions (tools/test_install_xray.sh)
[ -n "$PODKOP_INSTALL_NO_MAIN" ] || main "$@"
