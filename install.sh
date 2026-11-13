#!/bin/sh
# shellcheck shell=dash
# ==============================================================================
# Podkop (Xray-core Edition) - Single Command Unified Installer & Upgrader
# Repository: https://github.com/Shytyan/podkop-xray-dist
# ==============================================================================

set -e

# Optional own mirror of the release files (tried before GitHub); empty in the published installer
MIRROR_BASE="${MIRROR_BASE:-}"
RELEASE_DOWNLOAD="https://github.com/Shytyan/podkop-xray-dist/releases/latest/download"
RELEASE_API="https://api.github.com/repos/Shytyan/podkop-xray-dist/releases/latest"
RELEASE_JSON="/tmp/podkop_release.json"
GITHUB_BLOCKED=0 # set once github.com fails and the api.github.com route works
DOWNLOAD_DIR="/tmp/podkop_install"
XRAY_TMP_BIN="/tmp/xray.new" # Xray-core downloaded in step 3b, installed in step 7
REQUIRED_SPACE_KB=46080 # 45MB in KB
NON_INTERACTIVE=0
FORCE_RU=0
# The Xray-core version podkop uses (see install_xray)
XRAY_VERSION="v26.10.31"
NO_DOH_PROXY=0
# --reset: clean install even over podkop Xray edition; UPGRADE=1: update, the settings are kept (detect_upgrade)
RESET=0
UPGRADE=0
PODKOP_WAS_ENABLED=0
SAVED_CONFIG=""

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
        --no-doh-proxy)
            NO_DOH_PROXY=1
            ;;
        --reset)
            RESET=1
            ;;
        -h|--help)
            echo "Usage: sh install.sh [-y] [--ru] [--reset]"
            echo "  -y, --yes: Non-interactive mode (auto-confirm wipe and install)"
            echo "  --reset:   Clean install with default settings even over podkop Xray edition (default: update, settings kept)"
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

# fetch_release_asset <name> <file>: an asset of our latest release. Our mirror (MIRROR_BASE) first, then
# github.com; if github.com is blocked (some ISPs block github.com:443 but not *.githubusercontent.com), the
# GitHub API, which redirects to release-assets.githubusercontent.com. That needs curl (Accept header); the file
# is checked against the API sha256.
fetch_release_asset() {
    local name="$1" out="$2" info url sum
    [ -n "$MIRROR_BASE" ] && fetch_file "${MIRROR_BASE%/}/releases/latest/$name" "$out" && return 0
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

# pkg_files <package>: absolute paths of the files of an installed package
pkg_files() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk info -L "$1" 2>/dev/null
    else
        opkg files "$1" 2>/dev/null
    fi | awk '/ contains:$/ || /following files:$/ || NF == 0 {next} { if (substr($0, 1, 1) != "/") $0 = "/" $0; print }'
}

pkg_list_installed() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk info 2>/dev/null || true
    else
        opkg list-installed 2>/dev/null | awk '{print $1}' || true
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
    check_free_space

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

# detect_upgrade: podkop Xray edition (ours) is installed and configured -> UPGRADE=1: the settings are kept.
# The sing-box podkop (different config) and --reset -> clean install. PODKOP_PURGE_ROOT: a fake root (tests).
detect_upgrade() {
    local root="${PODKOP_PURGE_ROOT:-}" c="${PODKOP_PURGE_ROOT:-}/usr/lib/podkop/constants.sh"
    UPGRADE=0
    [ "$RESET" -eq 1 ] && return 0
    [ -s "$root/etc/config/podkop" ] && [ -f "$c" ] || return 0
    if grep -q '^PODKOP_VERSION=".*_Xray"' "$c" || grep -q '^XRAY_VERSION=' "$c"; then
        UPGRADE=1
    fi
}

# inherit_mirror: an update started without a mirror keeps using the one the router was installed from
# (settings.mirror_url): packages, Xray-core and the DoH presets come from it first, as before
inherit_mirror() {
    local saved
    [ -z "$MIRROR_BASE" ] && [ "$UPGRADE" -eq 1 ] || return 0
    saved="$(uci -q get podkop.settings.mirror_url 2>/dev/null || true)"
    case "$saved" in
        https://*) MIRROR_BASE="$saved"; msg "Mirror from the current settings is used first." ;;
    esac
    return 0
}

# remember_podkop_state: was podkop enabled at boot before the installer touched it (the purge disables it);
# an upgrade keeps the Russian interface (the purge removes luci-i18n-podkop-ru, -y would install English)
remember_podkop_state() {
    local f
    PODKOP_WAS_ENABLED=0
    for f in "${PODKOP_PURGE_ROOT:-}"/etc/rc.d/S*podkop; do
        [ -e "$f" ] && PODKOP_WAS_ENABLED=1
    done
    if [ "$UPGRADE" -eq 1 ] && pkg_list_installed | grep -qx "luci-i18n-podkop-ru"; then
        FORCE_RU=1
    fi
    return 0
}

# restore_config: upgrade -> the settings saved by the purge replace the package defaults
restore_config() {
    [ "$UPGRADE" -eq 1 ] && [ -s "$SAVED_CONFIG" ] || return 0
    cp -f "$SAVED_CONFIG" "${PODKOP_PURGE_ROOT:-}/etc/config/podkop"
    msg "Settings restored from $SAVED_CONFIG"
}

# start_after_upgrade: upgrade of an enabled podkop -> enabled and started with the kept settings
start_after_upgrade() {
    [ "$UPGRADE" -eq 1 ] && [ "$PODKOP_WAS_ENABLED" -eq 1 ] || return 0
    info "==> Starting podkop with your settings"
    podkop_service enable >/dev/null 2>&1 || true
    podkop_service start >/dev/null 2>&1 || warn "Warning: podkop did not start, see: logread -e podkop"
}

confirm_wipe() {
    info "==> Step 2: Confirmation"
    if [ "$UPGRADE" -eq 1 ]; then
        msg "Podkop (Xray edition) is installed: UPDATE, your settings are kept (clean install: --reset)."
        msg "Podkop (Xray edition) уже установлен: ОБНОВЛЕНИЕ, ваши настройки сохранятся (чистая установка: --reset)."
    fi
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        if [ "$UPGRADE" -eq 1 ]; then
            warn "Non-interactive mode: proceeding with the update."
        else
            warn "Non-interactive mode: proceeding with full purge and installation."
        fi
        return 0
    fi

    # An update keeps the settings and removes nothing of the user: no question (a clean install still asks)
    if [ "$UPGRADE" -eq 1 ]; then
        msg "Обновляем без вопросов / Updating, no questions asked."
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

# M6: Bulletproof purge of sing-box of any origin (official/custom packages, running processes,
# init scripts, and custom/renamed binaries detected by filename or by the sing-box Go module path inside).
# Nothing is executed: a renamed build is recognised as an ELF file containing "sing-box" (every build embeds
# github.com/sagernet/sing-box or its fork path); scripts that merely mention sing-box are left alone.
is_singbox_binary() {
    local f="$1" base
    [ -f "$f" ] && [ -x "$f" ] && [ ! -L "$f" ] || return 1
    base="$(basename "$f")"
    case "$base" in
        busybox|apk|opkg|xray|podkop|podkop-guard|curl|wget|jq|dig|unzip|nft|ip|tc|ss|uhttpd|rpcd|ubus|ubusd|procd|netifd|dnsmasq|odhcpd|dropbear|https-dns-proxy|sh|ash|bash|lua|ucode|fw4|iptables*|ip6tables*)
            return 1
            ;;
        *sing-box*|*singbox*)
            return 0
            ;;
    esac
    [ "$(head -c 4 "$f" 2>/dev/null)" = "$(printf '\177ELF')" ] || return 1
    grep -qa "sing-box" "$f" 2>/dev/null
}

# flash_avail_kb: free space on the overlay (or on / without an overlay), KB
flash_avail_kb() {
    local avail_kb=""
    [ -d /overlay ] && avail_kb="$(df -k /overlay 2>/dev/null | awk 'NR==2 {print $4}')"
    if [ -z "$avail_kb" ] || [ "$avail_kb" -eq 0 ]; then
        avail_kb="$(df -k / 2>/dev/null | awk 'NR==2 {print $4}')"
    fi
    echo "$avail_kb"
}

# reclaimable_kb: flash space (KB) the purge frees: files of the packages it removes (old podkop, sing-box of any
# origin, xray-core), sing-box binaries outside packages and the old /usr/bin/xray (replaced). Each path counts once,
# and only if it takes space on the overlay (its copy in /overlay/upper; files only in /rom free nothing).
# https-dns-proxy is not counted: it is installed again. PODKOP_PURGE_ROOT: a fake root (tests).
reclaimable_kb() {
    local root="${PODKOP_PURGE_ROOT:-}" upper="" p d f
    [ -d "$root/overlay/upper" ] && upper="$root/overlay/upper"
    {
        for p in $(pkg_list_installed); do
            case "$p" in
                podkop|luci-app-podkop|luci-i18n-podkop-*|xray-core|xray-example|*sing-box*|*singbox*) pkg_files "$p" ;;
            esac
        done
        echo /usr/bin/xray
        for d in /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin /opt /root /sbin /bin; do
            for f in "$root$d"/*; do
                is_singbox_binary "$f" && echo "$d/${f##*/}"
            done
            [ -n "$upper" ] || continue
            for f in "$upper$d"/*; do
                is_singbox_binary "$f" && echo "$d/${f##*/}"
            done
        done
    } | sort -u | {
        local total=0 sz
        while read -r p; do
            f="${upper:-$root}$p"
            [ -f "$f" ] && [ ! -L "$f" ] || continue
            sz="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
            total=$((total + ${sz:-0}))
        done
        echo $((total / 1024))
    }
}

# check_free_space: enough flash for the install, counting what the purge of old podkop / sing-box / xray frees.
# Runs before anything is changed: not enough space -> exit, the router stays as it is.
check_free_space() {
    local avail_kb reclaim_kb=0 total_kb
    avail_kb="$(flash_avail_kb)"
    [ -n "$avail_kb" ] || return 0
    [ "$avail_kb" -ge "$REQUIRED_SPACE_KB" ] && return 0
    reclaim_kb="$(reclaimable_kb)"
    total_kb=$((avail_kb + ${reclaim_kb:-0}))
    if [ "$total_kb" -lt "$REQUIRED_SPACE_KB" ]; then
        err "Error: Insufficient flash storage."
        err "Available: $((avail_kb / 1024)) MB + $((reclaim_kb / 1024)) MB freed by removing old podkop/sing-box/xray = $((total_kb / 1024)) MB, Required: $((REQUIRED_SPACE_KB / 1024)) MB."
        err "Nothing was changed on the router."
        exit 1
    fi
    msg "Free flash: $((avail_kb / 1024)) MB + $((reclaim_kb / 1024)) MB freed by removing old podkop/sing-box/xray = $((total_kb / 1024)) MB (required $((REQUIRED_SPACE_KB / 1024)) MB)"
}

purge_singbox_everywhere() {
    local root="${PODKOP_PURGE_ROOT:-}" before_kb=0 after_kb=0 freed_kb=0
    local p pid exe cmdline f d init_f rc_f sb_bins="" removed_items=""

    if [ -z "$root" ]; then
        if [ -d /overlay ]; then
            before_kb="$(df -k /overlay 2>/dev/null | awk 'NR==2 {print $4}')"
        else
            before_kb="$(df -k / 2>/dev/null | awk 'NR==2 {print $4}')"
        fi
    fi

    # 1. Kill running sing-box processes (by /proc/<pid>/exe or /proc/<pid>/cmdline)
    if [ -z "$root" ] && [ -d /proc ]; then
        for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
            [ "$pid" = "$$" ] && continue
            exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
            cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
            case "$exe $cmdline" in
                *sing-box*|*singbox*)
                    kill -9 "$pid" 2>/dev/null || true
                    removed_items="$removed_items proc:$pid"
                    ;;
            esac
        done
    fi

    # 2. Remove any installed packages matching *sing-box* or *singbox*
    for p in $(pkg_list_installed); do
        case "$p" in
            *sing-box*|*singbox*)
                pkg_remove "$p"
                removed_items="$removed_items pkg:$p"
                ;;
        esac
    done

    # 3. Scan executable directories for custom or renamed sing-box binaries
    for d in "$root/usr/bin" "$root/usr/sbin" "$root/usr/local/bin" "$root/usr/local/sbin" \
             "$root/opt" "$root/root" "$root/sbin" "$root/bin" \
             "$root/overlay/upper/usr/bin" "$root/overlay/upper/usr/sbin" "$root/overlay/upper/opt" "$root/overlay/upper/root"; do
        [ -d "$d" ] || continue
        for f in "$d"/*; do
            [ -e "$f" ] || continue
            if is_singbox_binary "$f"; then
                sb_bins="$sb_bins $f"
                 [ -n "$root" ] && sb_bins="$sb_bins ${f#$root}"
                rm -f "$f" 2>/dev/null || true
                removed_items="$removed_items bin:$f"
            fi
        done
    done

    # 4. Stop, disable and remove init.d / rc.d scripts referencing sing-box or the removed binaries
    if [ -d "$root/etc/init.d" ]; then
        for init_f in "$root/etc/init.d"/*; do
            [ -f "$init_f" ] || continue
            local match=0
            case "$(basename "$init_f")" in
                *sing-box*|*singbox*) match=1 ;;
            esac
            if [ "$match" -eq 0 ] && grep -qE 'sing-?box' "$init_f" 2>/dev/null; then
                match=1
            fi
            if [ "$match" -eq 0 ] && [ -n "$sb_bins" ]; then
                for f in $sb_bins; do
                    grep -qF "$f" "$init_f" 2>/dev/null && match=1 && break
                done
            fi
            if [ "$match" -eq 1 ]; then
                [ -z "$root" ] && "$init_f" stop >/dev/null 2>&1 || true
                [ -z "$root" ] && "$init_f" disable >/dev/null 2>&1 || true
                for rc_f in "$root/etc/rc.d"/*"$("basename" "$init_f")"; do
                    [ -e "$rc_f" ] || [ -L "$rc_f" ] && rm -f "$rc_f" 2>/dev/null || true
                done
                rm -f "$init_f" 2>/dev/null || true
                removed_items="$removed_items init:$init_f"
            fi
        done
    fi

    # 5. Remove leftover *sing-box* / *singbox* files & dirs across standard paths and overlay
    for d in "$root/etc" "$root/usr" "$root/opt" "$root/root" "$root/tmp" "$root/var" "$root/overlay/upper"; do
        [ -d "$d" ] || continue
        find "$d" \( -name '*sing-box*' -o -name '*singbox*' -o -name '*.srs' \) -exec rm -rf {} + 2>/dev/null || true
    done

    if [ -z "$root" ]; then
        if [ -d /overlay ]; then
            after_kb="$(df -k /overlay 2>/dev/null | awk 'NR==2 {print $4}')"
        else
            after_kb="$(df -k / 2>/dev/null | awk 'NR==2 {print $4}')"
        fi
        if [ -n "$before_kb" ] && [ -n "$after_kb" ] && [ "$after_kb" -gt "$before_kb" ] 2>/dev/null; then
            freed_kb=$((after_kb - before_kb))
        fi
    fi

    if [ -n "$removed_items" ]; then
        msg "Sing-box purge removed:${removed_items} (freed $((freed_kb / 1024)) MB / ${freed_kb} KB)"
    else
        msg "Sing-box purge: no sing-box packages or binaries found (freed 0 KB)"
    fi
}

# purge_podkop_data: /etc/podkop. An upgrade keeps the downloaded lists and subscriptions (lists-cache,
# subscriptions): without them the first start has no subnets, and no servers when the subscription host is down.
# PODKOP_PURGE_ROOT: a fake root (tests).
purge_podkop_data() {
    local dir="${PODKOP_PURGE_ROOT:-}/etc/podkop" entry
    [ -d "$dir" ] || return 0
    if [ "$UPGRADE" -ne 1 ]; then
        rm -rf "$dir"
        return 0
    fi
    for entry in "$dir"/* "$dir"/.[!.]*; do
        [ -e "$entry" ] || continue
        case "${entry##*/}" in
            lists-cache|subscriptions) ;;
            *) rm -rf "$entry" ;;
        esac
    done
    return 0
}

# Install marker (holds the time it was set): the package postinst starts podkop on the default config before the
# kept settings are back; podkop does not start while a fresh marker is there (install_in_progress, /usr/bin/podkop).
install_marker_set() {
    date +%s > "${PODKOP_PURGE_ROOT:-}/tmp/podkop.installing"
}

install_marker_clear() {
    rm -f "${PODKOP_PURGE_ROOT:-}/tmp/podkop.installing"
}

purge_old_podkop() {
    info "==> Step 4: Purging Old Podkop, Sing-box & Conflicting Components"

    # 1. Stop and disable podkop service. Before its config is removed: a stop without the config cannot tell that
    # dnsmasq is already given back and restarts it again. Already stopped for the downloads -> no second stop.
    if [ -x /etc/init.d/podkop ]; then
        if [ "$PODKOP_STOPPED" -ne 1 ]; then
            /etc/init.d/podkop stop >/dev/null 2>&1 || true
        fi
        /etc/init.d/podkop disable >/dev/null 2>&1 || true
    fi

    # Backup existing config and remove it (the package installs the defaults); an upgrade puts it back (restore_config)
    if [ -f /etc/config/podkop ]; then
        SAVED_CONFIG="/etc/config/podkop.bak-$(date +%Y%m%d-%H%M%S)"
        cp -f /etc/config/podkop "$SAVED_CONFIG"
        rm -f /etc/config/podkop
        if [ "$UPGRADE" -eq 1 ]; then
            msg "Current config saved to $SAVED_CONFIG (restored after the update)"
        else
            msg "Current config backed up to $SAVED_CONFIG and reset to default"
        fi
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

    # 4. Remove conflicting and legacy packages + thorough sing-box purge.
    # xray-core (OpenWrt feed, older): podkop uses its own Xray-core binary (step 7); left installed, a package
    # upgrade would put the old binary back. Removed after its dependents (podkop, xray-example).
    for pkg in \
        luci-i18n-podkop-ru luci-i18n-podkop-en \
        luci-app-podkop podkop \
        sing-box \
        https-dns-proxy luci-app-https-dns-proxy luci-i18n-https-dns-proxy-ru \
        xray-example xray-core; do
        pkg_remove "$pkg"
    done
    purge_singbox_everywhere

    # 5. Remove leftover directories and files
    purge_podkop_data
    rm -rf /etc/config/podkop-070 \
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
           /tmp/podkop_xray_update* /tmp/podkop_xray_releases.json \
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

# xray_fetch_binary <zip url | release:<asset name>> <file>: downloads the archive, extracts a complete, runnable xray binary
xray_fetch_binary() {
    local url="$1" out="$2" tmp_zip="/tmp/xray.zip" want_size have_size
    rm -f "$tmp_zip" "$out"
    case "$url" in
        release:*)
            msg "Downloading Xray-core ${url#release:} from the podkop release..."
            fetch_release_asset "${url#release:}" "$tmp_zip" || { rm -f "$tmp_zip"; return 1; }
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

# xray_download <zip arch> <file>: a working xray binary of XRAY_VERSION, from our mirror (MIRROR_BASE) first,
# then XTLS, then the copy in our release (the release workflow attaches it). No other version is ever installed.
xray_download() {
    local zip_arch="$1" out="$2" urls="" url
    msg "Xray-core version: $XRAY_VERSION"
    [ -n "$MIRROR_BASE" ] && urls="${MIRROR_BASE%/}/xray/${XRAY_VERSION}/Xray-linux-${zip_arch}.zip"
    urls="$urls https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${zip_arch}.zip"
    urls="$urls release:Xray-linux-${zip_arch}.zip"
    for url in $urls; do
        # github.com is blocked: skip direct https://github.com URLs
        [ "$GITHUB_BLOCKED" -eq 1 ] && [ "${url#https://github.com/}" != "$url" ] && continue
        xray_fetch_binary "$url" "$out" && return 0
        warn "Warning: Xray-core is not available at $url"
    done
    return 1
}

# Downloads Xray-core (XRAY_VERSION) to XRAY_TMP_BIN BEFORE the old podkop is removed, like the packages: a failed
# download leaves the router untouched. No xray-core package from the OpenWrt feed (an older version) is installed.
fetch_xray() {
    info "==> Step 3b: Downloading Xray-core"

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
            download_failed
            ;;
    esac

    msg "Detected architecture: $arch -> Xray-linux-${zip_arch}.zip"

    # /tmp is RAM on OpenWrt: the archive (~12 MB) and the binary (~35 MB) must both fit
    local tmp_free
    tmp_free="$(df -k /tmp 2>/dev/null | awk 'NR==2 {print $4}')"
    if [ -n "$tmp_free" ] && [ "$tmp_free" -lt 61440 ]; then
        err "Error: not enough free space in /tmp for Xray-core: $((tmp_free / 1024)) MB, need 60 MB."
        err "Nothing was changed on the router. Free /tmp (or reboot the router) and run the installer again."
        download_failed
    fi

    if ! xray_download "$zip_arch" "$XRAY_TMP_BIN"; then
        err "Error: Failed to download a working Xray-core binary."
        err "Nothing was changed on the router. Check the internet connection and try again."
        download_failed
    fi
    msg "Xray-core $("$XRAY_TMP_BIN" version 2>/dev/null | head -n1 | awk '{print $2}') downloaded."
}

install_xray() {
    info "==> Step 7: Installing Xray-core"
    local xray_ver
    if [ ! -s "$XRAY_TMP_BIN" ]; then
        err "Error: the downloaded Xray-core binary $XRAY_TMP_BIN is gone (/tmp cleared?). Run: podkop update_xray"
        exit 1
    fi
    xray_ver="$("$XRAY_TMP_BIN" version 2>/dev/null | head -n1 | awk '{print $2}')"
    mv -f "$XRAY_TMP_BIN" /usr/bin/xray
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

podkop_service() {
    [ -x /etc/init.d/podkop ] && /etc/init.d/podkop "$@"
}

# The downloads go before the purge. While podkop runs, dnsmasq sends DNS to podkop's 127.0.0.42, and a broken podkop
# (the usual reason to reinstall) answers only now and then, so a test lookup proves nothing. podkop is removed in
# step 4 anyway: stop it for the downloads (dnsmasq goes back to the provider DNS); download_failed starts it again.
PODKOP_STOPPED=0
podkop_dns_bypass() {
    uci -q get dhcp.@dnsmasq[0].server 2>/dev/null | grep -q "127.0.0.42" || return 0
    warn "Stopping podkop for the downloads: DNS goes through it (it is reinstalled anyway)"
    podkop_service stop >/dev/null 2>&1 || true
    PODKOP_STOPPED=1
}

# download_failed: a download before the purge failed -> start the podkop stopped for the downloads and exit
download_failed() {
    if [ "$PODKOP_STOPPED" -eq 1 ]; then
        msg "Starting podkop again..."
        podkop_service start >/dev/null 2>&1 || true
    fi
    exit 1
}

# Downloads the packages BEFORE the old podkop is removed: a failed download leaves the router untouched.
# Release assets with fixed names are fetched via releases/latest/download (no GitHub API, no rate limit).
fetch_packages() {
    info "==> Step 3: Downloading Podkop (Xray edition) Packages"
    local ext p
    podkop_dns_bypass
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
        download_failed
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
    elif [ "$UPGRADE" -eq 1 ]; then
        # an update asks nothing: the language stays as it was (FORCE_RU when the Russian package was installed)
        install_ru=0
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
    if [ "$UPGRADE" -eq 1 ]; then
        msg "Обновление: ваши настройки сохранены (копия: $SAVED_CONFIG)."
        if [ "$PODKOP_WAS_ENABLED" -eq 1 ]; then
            msg "Podkop запускается с вашими настройками."
        else
            warn "Podkop был выключен до обновления и остаётся выключенным: запустите его в LuCI."
        fi
    else
        warn "ВАЖНО: Служба Podkop не запущена автоматически."
        warn "Для запуска откройте веб-интерфейс LuCI, добавьте Outbound (Single Link: VLESS/VMess/Trojan/SS)"
        warn "и нажмите 'Сохранить и применить'."
    fi
    echo ""
}

# Installed from a mirror: podkop keeps using it first for lists and Xray-core (settings.mirror_url)
save_mirror_url() {
    [ -n "$MIRROR_BASE" ] || return 0
    uci -q set podkop.settings.mirror_url="$MIRROR_BASE"
    uci -q commit podkop
}

# Installed from a mirror: its private DoH servers (<mirror>/dns-presets.txt, one https URL per line) are offered in
# the LuCI DNS lists (settings.dns_presets). No mirror or no file -> the settings stay as they are.
save_dns_presets() {
    [ -n "$MIRROR_BASE" ] || return 0
    local f="/tmp/podkop_dns_presets.txt" url
    fetch_file "${MIRROR_BASE%/}/dns-presets.txt" "$f" || { rm -f "$f"; return 0; }
    # set -e: deleting an option that does not exist yet fails
    uci -q delete podkop.settings.dns_presets || true
    while read -r url; do
        case "$url" in
            https://*) uci -q add_list podkop.settings.dns_presets="$url" || true ;;
        esac
    done < "$f"
    uci -q commit podkop || true
    rm -f "$f"
    msg "DoH servers of the mirror added to the DNS lists"
}

main() {
    check_system
    detect_upgrade
    inherit_mirror
    remember_podkop_state
    confirm_wipe
    fetch_packages
    fetch_xray
    purge_old_podkop
    install_deps
    trap install_marker_clear EXIT
    install_marker_set
    install_packages
    restore_config
    save_mirror_url
    save_dns_presets
    install_marker_clear
    install_xray
    install_doh_proxy
    post_install
    start_after_upgrade
}

# PODKOP_INSTALL_NO_MAIN=1: only define the functions (tools/test_install_xray.sh)
[ -n "$PODKOP_INSTALL_NO_MAIN" ] || main "$@"
