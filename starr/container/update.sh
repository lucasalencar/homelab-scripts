#!/bin/bash
# shellcheck disable=SC2015  # A && log || log is intentional: log is echo and cannot fail
set -e
export DEBIAN_FRONTEND=noninteractive

log() { echo "[starr-update] $*"; }

# Dependencies of starr/container/configure.py (migrates CTs provisioned before ruamel)
log "Ensuring configure dependencies..."
apt install -y python3-ruamel.yaml

ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
case "$ARCH" in
    amd64|x86_64) SERVARR_ARCH="x64" ;;
    arm64|aarch64) SERVARR_ARCH="arm64" ;;
    armhf|armv7l|armv6l|arm) SERVARR_ARCH="arm" ;;
    *) log "ERROR: unsupported arch $ARCH"; exit 1 ;;
esac
log "Detected arch: $ARCH -> Servarr arch: $SERVARR_ARCH"

# Same compat shim as provision.sh: old glibc cannot load the bundled SQLite
ensure_sqlite_compat() {
    local target="$1"
    local glibc_version glibc_major glibc_minor
    glibc_version=$(ldd --version 2>/dev/null | awk '/ldd/{print $NF}' | head -1)
    glibc_major=$(echo "$glibc_version" | cut -d. -f1)
    glibc_minor=$(echo "$glibc_version" | cut -d. -f2)
    if [ -n "$glibc_major" ] && { [ "$glibc_major" -lt 2 ] || { [ "$glibc_major" -eq 2 ] && [ "${glibc_minor:-0}" -lt 38 ]; }; }; then
        log "  glibc $glibc_version < 2.38, linking system SQLite..."
        mv "$target/libe_sqlite3.so" "$target/libe_sqlite3.so.backup" 2>/dev/null || true
        local system_sqlite="/usr/lib/x86_64-linux-gnu/libsqlite3.so.0"
        case "$ARCH" in
            arm64|aarch64) system_sqlite="/usr/lib/aarch64-linux-gnu/libsqlite3.so.0" ;;
            armhf|armv7l|armv6l|arm) system_sqlite="/usr/lib/arm-linux-gnueabihf/libsqlite3.so.0" ;;
        esac
        if [ -f "$system_sqlite" ]; then
            ln -s "$system_sqlite" "$target/libe_sqlite3.so"
        else
            log "  WARNING: system SQLite not found at $system_sqlite"
        fi
    fi
}

# Deploy the latest Servarr tarball over /opt/<app>, preserving the data dir.
# Usage: update_servarr <App> <service> <download_url> <target> <data_dir>
update_servarr() {
    local app="$1" service="$2" dl_url="$3" target="$4" data_dir="$5"

    if [ ! -d "$target" ] && [ ! -d "$data_dir" ]; then
        log "$app not installed — skipping"
        return 0
    fi

    log "Updating $app..."
    log "  URL: $dl_url"

    local tmpdir archive
    tmpdir=$(mktemp -d)
    archive="$tmpdir/archive.tar.gz"
    if ! curl -fsSL -o "$archive" "$dl_url"; then
        log "  download failed — keeping the installed version"
        rm -rf "$tmpdir"
        return 1
    fi

    systemctl stop "$service" 2>/dev/null || true

    if [ -d "$target" ] && [ "$(ls -A "$target" 2>/dev/null)" ]; then
        find "$target" -mindepth 1 -delete 2>/dev/null || rm -rf "${target:?}/"* 2>/dev/null || true
    fi
    mkdir -p "$target"

    local extract="$tmpdir/extract" top entry_count
    mkdir -p "$extract"
    if ! tar --no-same-owner -xzf "$archive" -C "$extract" 2>/dev/null; then
        tar --no-same-owner -xf "$archive" -C "$extract"
    fi
    top=$(find "$extract" -mindepth 1 -maxdepth 1 | head -1)
    entry_count=$(find "$extract" -mindepth 1 -maxdepth 1 | wc -l)
    if [ -d "$top" ] && [ "$entry_count" -eq 1 ]; then
        cp -r "$top"/* "$target/"
    else
        cp -r "$extract"/* "$target/"
    fi
    chmod 775 "$target"
    rm -rf "$tmpdir"

    ensure_sqlite_compat "$target"

    mkdir -p "$data_dir"
    chmod 775 "$data_dir" "$target"
    # Tarball is already latest — drop any stale self-update marker
    rm -f "$data_dir/update_required"

    if ! systemctl restart "$service" 2>/dev/null; then
        systemctl start "$service"
    fi
    if systemctl is-active --quiet "$service"; then
        log "  $service: active"
    else
        log "  $service: not active after restart"
        return 1
    fi
}

failed=0

update_servarr "Prowlarr" "prowlarr" "https://prowlarr.servarr.com/v1/update/master/updatefile?os=linux&runtime=netcore&arch=${SERVARR_ARCH}" "/opt/Prowlarr" "/var/lib/prowlarr" || failed=1
update_servarr "Sonarr" "sonarr" "https://services.sonarr.tv/v1/download/main/latest?version=4&os=linux&arch=${SERVARR_ARCH}" "/opt/Sonarr" "/var/lib/sonarr" || failed=1
update_servarr "Radarr" "radarr" "https://radarr.servarr.com/v1/update/master/updatefile?os=linux&runtime=netcore&arch=${SERVARR_ARCH}" "/opt/Radarr" "/var/lib/radarr" || failed=1

# Bazarr ships no self-updater: fetch the latest zip, redeploy the code,
# then refresh the venv against the new requirements.
if [ -d /opt/bazarr ] || [ -d /var/lib/bazarr ]; then
    log "Updating bazarr..."
    log "  URL: https://github.com/morpheus65535/bazarr/releases/latest/download/bazarr.zip"
    baz_tmpdir=$(mktemp -d)
    baz_archive="$baz_tmpdir/bazarr.zip"
    if curl -fsSL -o "$baz_archive" "https://github.com/morpheus65535/bazarr/releases/latest/download/bazarr.zip"; then
        systemctl stop bazarr 2>/dev/null || true
        # Clear code but keep the venv dir; stale pyc/source is rebuilt below
        if [ -d /opt/bazarr ]; then
            find /opt/bazarr -mindepth 1 -maxdepth 1 ! -name venv -exec rm -rf {} + 2>/dev/null || true
        fi
        mkdir -p /opt/bazarr "$baz_tmpdir/bazextract"
        unzip -q -o "$baz_archive" -d "$baz_tmpdir/bazextract"
        baz_entries=$(find "$baz_tmpdir/bazextract" -mindepth 1 -maxdepth 1 | wc -l)
        baz_top=$(find "$baz_tmpdir/bazextract" -mindepth 1 -maxdepth 1 | head -1)
        if [ "$baz_entries" -eq 1 ] && [ -d "$baz_top" ]; then
            cp -r "$baz_top"/* /opt/bazarr/
        else
            cp -r "$baz_tmpdir/bazextract"/* /opt/bazarr/
        fi
        chmod 775 /opt/bazarr
        mkdir -p /var/lib/bazarr
        chmod 775 /opt/bazarr /var/lib/bazarr
        sed -i.bak "s/--only-binary=Pillow//g" /opt/bazarr/requirements.txt 2>/dev/null || true
        if [ ! -d /opt/bazarr/venv ]; then
            python3 -m venv /opt/bazarr/venv
        fi
        /opt/bazarr/venv/bin/pip install --upgrade pip -q
        /opt/bazarr/venv/bin/pip install -r /opt/bazarr/requirements.txt -q
        /opt/bazarr/venv/bin/pip install psycopg2-binary -q 2>/dev/null || true
        if grep -q "ExecStart=/usr/bin/python3" /etc/systemd/system/bazarr.service 2>/dev/null; then
            sed -i "s|ExecStart=/usr/bin/python3 /opt/bazarr/bazarr.py|ExecStart=/opt/bazarr/venv/bin/python3 /opt/bazarr/bazarr.py|g" /etc/systemd/system/bazarr.service
            systemctl daemon-reload
        fi
        if ! systemctl restart bazarr 2>/dev/null; then
            systemctl start bazarr
        fi
        if systemctl is-active --quiet bazarr; then
            log "  bazarr: active"
        else
            log "  bazarr: not active after restart"
            failed=1
        fi
    else
        log "  download failed — keeping the installed version"
        failed=1
    fi
    rm -rf "$baz_tmpdir"
else
    log "bazarr not installed — skipping"
fi

# FlareSolverr has no self-update: stage the latest prebuilt release, validate it,
# then swap it into place so a failed download never empties /opt
if [ -f /etc/systemd/system/flaresolverr.service ]; then
    log "Refreshing FlareSolverr..."
    fs_tmpdir=$(mktemp -d)
    fs_stage="$fs_tmpdir/stage"
    mkdir -p "$fs_stage"
    refreshed=0
    if curl -fsSL -o "$fs_tmpdir/flaresolverr.tar.gz" \
        "https://github.com/FlareSolverr/FlareSolverr/releases/latest/download/flaresolverr_linux_x64.tar.gz" \
        && tar --no-same-owner -tzf "$fs_tmpdir/flaresolverr.tar.gz" >/dev/null \
        && tar --no-same-owner -xzf "$fs_tmpdir/flaresolverr.tar.gz" -C "$fs_stage" --strip-components=1 \
        && [ -x "$fs_stage/flaresolverr" ]; then
        systemctl stop flaresolverr 2>/dev/null || true
        find /opt/flaresolverr -mindepth 1 -delete 2>/dev/null || rm -rf /opt/flaresolverr/* 2>/dev/null || true
        mkdir -p /opt/flaresolverr
        cp -r "$fs_stage"/. /opt/flaresolverr/
        chmod 755 /opt/flaresolverr/flaresolverr
        if ! systemctl restart flaresolverr 2>/dev/null; then
            systemctl start flaresolverr
        fi
        refreshed=1
    else
        log "  failed to fetch a valid FlareSolverr release — keeping the installed version"
    fi
    rm -rf "$fs_tmpdir"
    if systemctl is-active --quiet flaresolverr; then
        log "  flaresolverr: active"
    elif [ "$refreshed" -eq 1 ]; then
        log "  flaresolverr: not active after restart"
    else
        log "  flaresolverr: untouched (still on the previous version)"
    fi
else
    log "flaresolverr not installed — skipping"
fi

# Seerr: pull latest source, rebuild, restart (config dir is preserved)
if [ -d /opt/seerr ] || [ -f /etc/systemd/system/seerr.service ]; then
    log "Refreshing seerr..."
    refreshed=0
    if [ -d /opt/seerr/.git ]; then
        systemctl stop seerr 2>/dev/null || true
        if git -C /opt/seerr pull --ff-only 2>/dev/null; then
            cd /opt/seerr
            export CYPRESS_INSTALL_BINARY=0
            if pnpm install --frozen-lockfile 2>/dev/null; then
                export NODE_OPTIONS="--max-old-space-size=3072"
                if pnpm build 2>/dev/null; then
                    refreshed=1
                fi
            fi
        else
            log "  git pull failed — keeping the installed version"
        fi
        if ! systemctl restart seerr 2>/dev/null; then
            systemctl start seerr 2>/dev/null || true
        fi
    else
        log "  /opt/seerr has no git checkout — keeping the installed version"
    fi
    if systemctl is-active --quiet seerr; then
        log "  seerr: active"
    elif [ "$refreshed" -eq 1 ]; then
        log "  seerr: not active after restart"
    else
        log "  seerr: untouched (still on the previous version)"
    fi
else
    log "seerr not installed — skipping"
fi

log "Update check complete. Service status:"
systemctl is-active --quiet prowlarr && log "  prowlarr: active" || log "  prowlarr: inactive"
systemctl is-active --quiet sonarr && log "  sonarr: active" || log "  sonarr: inactive"
systemctl is-active --quiet radarr && log "  radarr: active" || log "  radarr: inactive"
systemctl is-active --quiet bazarr && log "  bazarr: active" || log "  bazarr: inactive"
systemctl is-active --quiet flaresolverr && log "  flaresolverr: active" || log "  flaresolverr: inactive"
systemctl is-active --quiet seerr && log "  seerr: active" || log "  seerr: inactive"

exit "$failed"
