#!/bin/sh
# shellcheck shell=dash
# ==============================================================================
# Podkop (Xray-core Edition) - Single Command Unified Installer & Upgrader
# Repository: https://github.com/Shytyan/podkop-xray-dist
# ==============================================================================

set -e

RELEASE_DOWNLOAD="https://github.com/Shytyan/podkop-xray-dist/releases/latest/download"
XRAY_REPO="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
XRAY_RELEASES="https://api.github.com/repos/XTLS/Xray-core/releases?per_page=1"
DOWNLOAD_DIR="/tmp/podkop_install"
REQUIRED_SPACE_KB=46080 # 45MB in KB
NON_INTERACTIVE=0
FORCE_RU=0
XRAY_PRERELEASE=0

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
            XRAY_PRERELEASE=1
            ;;
        -h|--help)
            echo "Usage: sh install.sh [-y] [--ru]"
            echo "  -y, --yes: Non-interactive mode (auto-confirm wipe and install)"
            echo "  --xray-prerelease: Install the newest Xray-core including pre-releases (default: latest stable)"
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
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 2 -m 180 -o "$out" "$url" || { rm -f "$out"; return 1; }
    else
        wget -q -O "$out" "$url" || { rm -f "$out"; return 1; }
    fi
    [ -s "$out" ]
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

install_xray() {
    info "==> Step 7: Installing the latest Xray-core"

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

    # Query latest release
    local download_url=""
    local tag_name=""
    local latest_json=""

    # Same policy as `podkop update_xray`: latest stable by default, newest including pre-releases with --xray-prerelease
    local api_url="$XRAY_REPO"
    [ "$XRAY_PRERELEASE" -eq 1 ] && api_url="$XRAY_RELEASES"
    if command -v curl >/dev/null 2>&1; then
        latest_json="$(curl -fsSL -m 15 "$api_url" 2>/dev/null || true)"
    fi
    if [ -n "$latest_json" ] && echo "$latest_json" | grep -q '"tag_name"'; then
        latest_json="$(echo "$latest_json" | jq -c 'if type == "array" then .[0] else . end' 2>/dev/null || true)"
        tag_name="$(echo "$latest_json" | jq -r '.tag_name // empty' 2>/dev/null || true)"
        download_url="$(echo "$latest_json" | jq -r --arg target "Xray-linux-${zip_arch}.zip" '.assets[]? | select(.name == $target) | .browser_download_url' 2>/dev/null || true)"
    fi

    # GitHub API unavailable (e.g. rate limit for a shared IP): github.com pages, no API involved
    if [ -z "$tag_name" ]; then
        if [ "$XRAY_PRERELEASE" -eq 1 ]; then
            tag_name="$(curl -fsSL -m 15 "https://github.com/XTLS/Xray-core/releases.atom" 2>/dev/null |
                grep -o 'releases/tag/v[0-9][0-9.]*' | head -n1 | sed 's|releases/tag/||')"
        else
            tag_name="$(curl -sI -m 15 "https://github.com/XTLS/Xray-core/releases/latest" 2>/dev/null | tr -d '\r' |
                sed -n 's|^[Ll]ocation: .*/releases/tag/\(v[0-9][0-9.]*\).*|\1|p' | head -n1)"
        fi
        [ -n "$tag_name" ] && msg "GitHub API unavailable, Xray tag from github.com: $tag_name"
    fi

    if [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
        if [ -n "$tag_name" ]; then
            download_url="https://github.com/XTLS/Xray-core/releases/download/${tag_name}/Xray-linux-${zip_arch}.zip"
        else
            download_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${zip_arch}.zip"
        fi
    fi

    # /tmp is RAM on OpenWrt: the archive (~12 MB) and the binary (~35 MB) must both fit
    local tmp_free
    tmp_free="$(df -k /tmp 2>/dev/null | awk 'NR==2 {print $4}')"
    if [ -n "$tmp_free" ] && [ "$tmp_free" -lt 61440 ]; then
        err "Error: not enough free space in /tmp for Xray-core: $((tmp_free / 1024)) MB, need 60 MB."
        err "podkop is installed and uses the xray-core package binary; free /tmp and run: podkop update_xray"
        exit 1
    fi

    msg "Downloading Xray-core from $download_url..."
    local tmp_zip="/tmp/xray.zip"
    local tmp_bin="/tmp/xray.new"
    rm -f "$tmp_zip" "$tmp_bin"

    if ! fetch_file "$download_url" "$tmp_zip"; then
        err "Error: Failed to download Xray-core archive."
        rm -f "$tmp_zip"
        exit 1
    fi

    msg "Extracting Xray binary..."
    local want_size have_size
    want_size="$(unzip -l "$tmp_zip" xray 2>/dev/null | awk '$NF == "xray" {print $1; exit}')"
    unzip -p "$tmp_zip" xray > "$tmp_bin" || true
    rm -f "$tmp_zip"
    have_size="$(wc -c < "$tmp_bin" 2>/dev/null | tr -d ' ')"
    if [ -z "$want_size" ] || [ "$have_size" != "$want_size" ]; then
        err "Error: Xray-core binary was not extracted completely ($have_size of $want_size bytes, /tmp full?)."
        rm -f "$tmp_bin"
        exit 1
    fi
    chmod +x "$tmp_bin"

    # Validate binary
    local xray_ver
    xray_ver="$("$tmp_bin" version 2>/dev/null | head -n1 | awk '{print $2}')"
    if [ -z "$xray_ver" ]; then
        err "Error: Downloaded Xray-core binary failed execution check."
        rm -f "$tmp_bin"
        exit 1
    fi

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
            fetch_file "$RELEASE_DOWNLOAD/$p.$ext" "$DOWNLOAD_DIR/$p.$ext" || rm -f "$DOWNLOAD_DIR/$p.$ext"
        fi
    done

    if [ ! -s "$DOWNLOAD_DIR/podkop.$ext" ] || [ ! -s "$DOWNLOAD_DIR/luci-app-podkop.$ext" ]; then
        err "Error: could not download podkop/luci-app-podkop packages from $RELEASE_DOWNLOAD"
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

post_install() {
    info "==> Step 8: Finalizing Installation"

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
    [ "$XRAY_PRERELEASE" -eq 1 ] && uci -q set podkop.settings.xray_prerelease='1' && uci -q commit podkop
    post_install
}

main "$@"
