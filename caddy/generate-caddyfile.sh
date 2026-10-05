#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/functions.sh
source "$SCRIPT_DIR/../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

require_root

LOCAL_CADDYFILE="${CADDY_LOCAL_CADDYFILE:-$SCRIPT_DIR/Caddyfile.local}"
STATE_FILE="${CADDY_STATE_FILE:-$SCRIPT_DIR/state.json}"
CADDY_CONTAINER_NAME="caddy"
DOMAIN="marx.home"
CORE_SCRIPT="$SCRIPT_DIR/generate_caddyfile_core.py"

# Seconds allowed per guest-agent probe; a dead agent fails fast instead of
# hanging the run silently. Override with CADDY_GUEST_TIMEOUT for slow hosts.
GUEST_PROBE_TIMEOUT="${CADDY_GUEST_TIMEOUT:-30}"
if ! command -v timeout >/dev/null 2>&1; then
    log_warning "  'timeout' not found — guest probes run without a time limit"
    GUEST_PROBE_TIMEOUT=""
fi

# Runs a guest probe with a timeout, printing probe stdout on success.
# Failures get a visible warning (label + exit code + first error line)
# instead of vanishing into 2>/dev/null, so a dead guest agent shows up in
# the log. Callers add `|| true` when a failed probe is an expected miss.
run_probe() {
    local label="$1"
    shift
    local output status=0
    if [ -n "$GUEST_PROBE_TIMEOUT" ]; then
        output=$(timeout "$GUEST_PROBE_TIMEOUT" "$@" 2>&1) || status=$?
    else
        output=$("$@" 2>&1) || status=$?
    fi
    if [ "$status" -ne 0 ]; then
        # To stderr: callers capture stdout, and the warning must stay visible
        log_warning "  Probe failed for $label (exit $status): $(printf '%s' "$output" | head -1)" >&2
        return "$status"
    fi
    printf '%s\n' "$output"
}

log_step "Caddyfile Generator for *.$DOMAIN"
echo ""

# --- Verify Caddy container exists ---
CADDY_ID=$(get_container_id_by_name "$CADDY_CONTAINER_NAME")
if [ -z "$CADDY_ID" ]; then
    log_error "Caddy container not found. Run install.sh first."
    exit 1
fi

pct start "$CADDY_ID" 2>/dev/null || true

CADDY_IP=$(get_container_ip "$CADDY_ID")
log_info "Caddy container: $CADDY_ID (IP: ${CADDY_IP:-unknown})"
echo ""

# --- Collect all guests (containers + VMs, excluding caddy itself) ---
GUEST_IDS=()
GUEST_NAMES=()
GUEST_TYPES=()
declare -A GUEST_IPS

# --- Collect containers (LXC) ---
while IFS= read -r cid; do
    cid="${cid// /}"
    [ -z "$cid" ] && continue

    if ! cfg=$(pct config "$cid" 2>&1); then
        log_warning "  Skipping CT $cid: 'pct config' failed: $(printf '%s' "$cfg" | head -1)"
        continue
    fi
    name=$(printf '%s' "$cfg" | grep -oP 'hostname:\s*\K\S+' || true)
    if [ -z "$name" ]; then
        log_warning "  Skipping CT $cid: could not determine hostname"
        continue
    fi
    [ "$name" = "$CADDY_CONTAINER_NAME" ] && continue

    log_info "  Probing CT $cid ($name)..."

    if ! ip=$(get_container_ip "$cid"); then
        log_warning "  Skipping CT $cid ($name): no IP found"
        continue
    fi
    if [ -z "$ip" ]; then
        log_warning "  Skipping CT $cid ($name): no IP found"
        continue
    fi

    GUEST_IDS+=("$cid")
    GUEST_NAMES+=("$name")
    GUEST_TYPES+=("ct")
    GUEST_IPS["$name"]="$ip"
done < <(pct list | tail -n +2 | awk '{print $1}' | sort -n)

# --- Collect VMs (QEMU) ---
while IFS= read -r vmid; do
    vmid="${vmid// /}"
    [ -z "$vmid" ] && continue

    name=$(qm config "$vmid" 2>/dev/null | grep -oP '(?:hostname|name):\s*\K\S+' || true)
    [ -z "$name" ] && continue
    [ "$name" = "$CADDY_CONTAINER_NAME" ] && continue

    if [ -n "${GUEST_IPS[$name]:-}" ]; then
        log_warning "  Skipping VM $vmid ($name) — name already used by another guest"
        continue
    fi

    log_info "  Probing VM $vmid ($name)..."

    json=$(run_probe "VM $vmid ($name) 'hostname -I'" qm guest exec "$vmid" -- hostname -I || true)
    ip=$(echo "$json" | jq -r '.["out-data"] // .["out"] // empty' 2>/dev/null | awk '{print $1}' || true)
    if [ -z "$ip" ]; then
        json=$(run_probe "VM $vmid ($name) 'ip addr'" qm guest exec "$vmid" -- ip -4 addr show || true)
        ip=$(echo "$json" | jq -r '.["out-data"] // .["out"] // empty' 2>/dev/null | grep -oP 'inet \K[\d.]+' | grep -v '^127\.' | head -1 || true)
    fi
    if [ -z "$ip" ]; then
        ip=$(qm config "$vmid" 2>/dev/null | grep -oP 'ipconfig\d:\s*ip=\K[^/]+' | head -1 || true)
    fi
    if [ -z "$ip" ]; then
        log_warning "  Skipping VM $vmid ($name): no IP found (is the guest agent running?)"
        continue
    fi

    GUEST_IDS+=("$vmid")
    GUEST_NAMES+=("$name")
    GUEST_TYPES+=("vm")
    GUEST_IPS["$name"]="$ip"
done < <(qm list 2>/dev/null | tail -n +2 | awk '{print $1}' | sort -n)

TOTAL=${#GUEST_NAMES[@]}
if [ "$TOTAL" -eq 0 ]; then
    log_warning "No guests found to configure."
    exit 0
fi

log_info "Found $TOTAL guest(s) to configure:"
for i in $(seq 0 $((TOTAL - 1))); do
    type_label="[${GUEST_TYPES[$i]}]"
    log_info "  $type_label ${GUEST_IDS[$i]}: ${GUEST_NAMES[$i]} (${GUEST_IPS[${GUEST_NAMES[$i]}]})"
done
echo ""

# Prints sorted unique TCP ports from ss -tlnp output on stdin
parse_ss_ports() {
    tail -n +2 | awk '{n=split($4, a, ":"); print a[n]}' | sort -n | uniq
}

# Prints listening TCP ports of a guest (one per line, numeric sort)
detect_ports() {
    local guest_type="$1"
    local guest_id="$2"
    local guest_name="${3:-$guest_id}"
    local output
    if [ "$guest_type" = "ct" ]; then
        if pct status "$guest_id" 2>/dev/null | grep -q "running"; then
            if ! output=$(run_probe "CT $guest_id ($guest_name) port scan" pct exec "$guest_id" -- ss -tlnp </dev/null); then
                return 1
            fi
            printf '%s' "$output" | parse_ss_ports
        fi
    else
        if qm status "$guest_id" 2>/dev/null | grep -q "running"; then
            if ! output=$(run_probe "VM $guest_id ($guest_name) port scan" qm guest exec "$guest_id" -- ss -tlnp </dev/null); then
                return 1
            fi
            echo "$output" | jq -r '.["out-data"] // .["out"] // empty' 2>/dev/null | parse_ss_ports
        fi
    fi
}

# Locates a real python3, skipping the bats mock bin
resolve_real_python3() {
    local found candidate
    found=$(command -v python3 2>/dev/null || true)
    case "$found" in
        ""|*mocks*) ;;
        *)
            printf '%s\n' "$found"
            return 0
            ;;
    esac
    for candidate in /opt/homebrew/bin/python3 /usr/bin/python3 /usr/local/bin/python3; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# --- Describe guests (with listening ports) for the Python core ---
if ! command -v jq >/dev/null 2>&1; then
    log_error "jq not found. Install jq to describe guests, then re-run."
    exit 1
fi
GUESTS_JSON=$(mktemp)
TMP_CADDYFILE=$(mktemp)
trap 'rm -f "$GUESTS_JSON" "$TMP_CADDYFILE"' EXIT
echo '[]' > "$GUESTS_JSON"

# One summary line per guest, printed right before the core prompts so the
# operator need not scroll up to see which ports each guest exposes
PORT_SUMMARY=()
for i in $(seq 0 $((TOTAL - 1))); do
    name="${GUEST_NAMES[$i]}"
    gid="${GUEST_IDS[$i]}"
    guest_type="${GUEST_TYPES[$i]}"
    ip="${GUEST_IPS[$name]}"

    listening_ports=$(detect_ports "$guest_type" "$gid" "$name" || true)
    if [ -n "$listening_ports" ]; then
        log_info "  Detected ports for $name: $(echo "$listening_ports" | tr '\n' ' ')"
        PORT_SUMMARY+=("$name ($ip): $(printf '%s' "$listening_ports" | tr '\n' ' ')")
    else
        log_info "  No listening ports detected for $name"
        PORT_SUMMARY+=("$name ($ip): no ports detected")
    fi
    ports_json=$(printf '%s' "$listening_ports" | jq -R -s '[split("\n")[] | select(test("^[0-9]+$")) | tonumber]' || true)
    [ -z "$ports_json" ] && ports_json="[]"
    guests_updated=$(jq --arg name "$name" --arg gid "$gid" --arg type "$guest_type" --arg ip "$ip" --argjson ports "$ports_json" \
        '. + [{name: $name, gid: $gid, gtype: $type, ip: $ip, ports: $ports}]' "$GUESTS_JSON")
    echo "$guests_updated" > "$GUESTS_JSON"
done

echo ""
log_step "Detected services (use these ports when answering below)"
for summary_line in "${PORT_SUMMARY[@]}"; do
    log_info "  $summary_line"
done
echo ""

# --- Merge guests into state, then render the Caddyfile via the core ---
REAL_PYTHON3=$(resolve_real_python3 || true)
if [ -z "$REAL_PYTHON3" ]; then
    log_error "python3 not found. Install Python 3 (e.g. apt install python3) to run $CORE_SCRIPT."
    exit 1
fi

if ! "$REAL_PYTHON3" "$CORE_SCRIPT" sync --domain "$DOMAIN" --state "$STATE_FILE" --guests-file "$GUESTS_JSON"; then
    log_error "Failed to resolve Caddy entries."
    exit 1
fi

echo ""
log_step "Writing $LOCAL_CADDYFILE"
echo ""

if ! "$REAL_PYTHON3" "$CORE_SCRIPT" render --state "$STATE_FILE" > "$TMP_CADDYFILE"; then
    log_error "Failed to render Caddyfile."
    exit 1
fi
cat "$TMP_CADDYFILE" > "$LOCAL_CADDYFILE"

cat "$LOCAL_CADDYFILE"

# --- Push to Caddy container and reload ---
log_step "Pushing to Caddy container ($CADDY_ID)..."
pct push "$CADDY_ID" "$LOCAL_CADDYFILE" /etc/caddy/Caddyfile

log_step "Reloading Caddy..."
pct exec "$CADDY_ID" -- systemctl reload caddy

echo ""
log_success "Caddy reloaded with latest configuration."
echo ""
log_info "Next step: run ./container-annotate/annotate.sh to update container/VM descriptions with access links."
if [ -n "$CADDY_IP" ]; then
    log_info "If not already set, add a wildcard DNS record: *.$DOMAIN → $CADDY_IP"
fi
