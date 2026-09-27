#!/bin/bash
# Enables IOMMU for PCIe passthrough on Intel processors.
# IOMMU allows direct access of PCIe devices (e.g., GPU) to virtual machines,
# improving performance for tasks like GPU passthrough.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../common/functions.sh
source "$SCRIPT_DIR/../../common/functions.sh" || { echo "Error: failed to load common/functions.sh" >&2; exit 1; }

require_root

# Add intel_iommu parameters to GRUB cmdline
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"/' /etc/default/grub

# Update GRUB to apply changes
update-grub

log_success "IOMMU enabled. Reboot required for changes to take effect."
