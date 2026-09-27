#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../common/functions.sh
source "$SCRIPT_DIR/../../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

require_root

log_step "Installing useful commands and packages for system"
apt install htop btop iotop sysstat -y # Commands to monitor disk IO
