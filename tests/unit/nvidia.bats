#!/usr/bin/env bats

setup() {
  export MOCK_TMPDIR=$(mktemp -d)
  export MOCK_LOG="$MOCK_TMPDIR/mock.log"
  export PATH="$BATS_TEST_DIRNAME/../helpers/mocks:$PATH"
  export REPO_ROOT="$BATS_TEST_DIRNAME/../.."
  export BASH_ENV="$BATS_TEST_DIRNAME/../helpers/bypass_root.sh"
  export NVIDIA_DEBIAN_SOURCES="$MOCK_TMPDIR/debian.sources"
  export NVIDIA_MODPROBE_CONF="$MOCK_TMPDIR/blacklist-nouveau-nvidia.conf"
  export NVIDIA_DEV_DIR="$MOCK_TMPDIR/dev"
  export NVIDIA_PVE_DIR="$MOCK_TMPDIR/pve"
  export NVIDIA_UNAME_R="7.0.14-17-pve"
  /bin/mkdir -p "$MOCK_TMPDIR/dev" "$MOCK_TMPDIR/pve"
  unset MOCK_LSPCI_OUTPUT
  unset MOCK_LSPCI_NNK_OUTPUT
  unset MOCK_NVIDIA_SMI_FAIL
  unset MOCK_SYSTEMCTL_FAIL
}

teardown() {
  rm -rf "$MOCK_TMPDIR"
  unset NVIDIA_DEBIAN_SOURCES NVIDIA_MODPROBE_CONF NVIDIA_DEV_DIR
  unset NVIDIA_PVE_DIR NVIDIA_UNAME_R
}

_write_sources_fixture() {
  /bin/cat > "$NVIDIA_DEBIAN_SOURCES" <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian/
Suites: trixie trixie-updates
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
}

_nvidia_present() {
  export MOCK_LSPCI_OUTPUT=$'00:02.0 VGA compatible controller [0300]: Intel Corporation Raptor Lake-S UHD Graphics [8086:a782] (rev 04)\n01:00.0 VGA compatible controller [0300]: NVIDIA Corporation AD104 [GeForce RTX 4060 Ti] [10de:2788] (rev a1)'
}

_no_nvidia() {
  export MOCK_LSPCI_OUTPUT='00:02.0 VGA compatible controller [0300]: Intel Corporation Raptor Lake-S UHD Graphics [8086:a782] (rev 04)'
}

_driver_in_use() {
  export MOCK_LSPCI_NNK_OUTPUT=$'01:00.0 VGA compatible controller [0300]: NVIDIA Corporation AD104 [GeForce RTX 4060 Ti] [10de:2788] (rev a1)\n\tKernel driver in use: nvidia'
}

_fake_dev_nodes() {
  /usr/bin/touch "$NVIDIA_DEV_DIR/nvidia0" "$NVIDIA_DEV_DIR/nvidiactl" "$NVIDIA_DEV_DIR/nvidia-uvm"
}

# -------------------------------------------------------------------
# nvidia/install.sh — stage 1 (pre-reboot)
# -------------------------------------------------------------------

@test "nvidia install fails fast without an NVIDIA GPU" {
  _no_nvidia
  export MOCK_NVIDIA_SMI_FAIL="1"
  _write_sources_fixture

  run bash "$REPO_ROOT/nvidia/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"NVIDIA"* ]]
  run /bin/grep "apt-get install" "$MOCK_LOG"
  [ "$status" -ne 0 ]
}

@test "nvidia install enables non-free and installs the driver stack" {
  _nvidia_present
  export MOCK_NVIDIA_SMI_FAIL="1"
  _write_sources_fixture

  run bash "$REPO_ROOT/nvidia/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"eboot"* ]]
  [[ "$output" == *"configure.sh"* ]]
  /bin/grep -q "apt-get update" "$MOCK_LOG"
  /bin/grep -q "nvidia-driver" "$MOCK_LOG"
  /bin/grep -q "proxmox-headers-7.0.14-17-pve" "$MOCK_LOG"
  /bin/grep -q "pve-headers" "$MOCK_LOG"
  /bin/grep -q "firmware-nvidia-graphics" "$MOCK_LOG"
  /bin/grep -q "update-initramfs -u" "$MOCK_LOG"
  /bin/grep -Eq '(^|[[:space:]])non-free($|[[:space:]])' "$NVIDIA_DEBIAN_SOURCES"
  /bin/grep -q "blacklist nouveau" "$NVIDIA_MODPROBE_CONF"
}

@test "nvidia install adds non-free idempotently" {
  _nvidia_present
  export MOCK_NVIDIA_SMI_FAIL="1"
  _write_sources_fixture

  run bash "$REPO_ROOT/nvidia/install.sh"
  [ "$status" -eq 0 ]
  run bash "$REPO_ROOT/nvidia/install.sh"
  [ "$status" -eq 0 ]
  count=$(/bin/grep -o "non-free" "$NVIDIA_DEBIAN_SOURCES" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  [ "$count" -eq 2 ]
}

@test "nvidia install skips apt when the driver already works" {
  _nvidia_present
  _driver_in_use
  _fake_dev_nodes
  _write_sources_fixture

  run bash "$REPO_ROOT/nvidia/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"configure.sh"* ]]
  run /bin/grep "apt-get install" "$MOCK_LOG"
  [ "$status" -ne 0 ]
}

# -------------------------------------------------------------------
# nvidia/configure.sh — stage 2 (post-reboot)
# -------------------------------------------------------------------

@test "nvidia configure fails when the driver is not loaded" {
  _nvidia_present
  export MOCK_NVIDIA_SMI_FAIL="1"

  run bash "$REPO_ROOT/nvidia/configure.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nvidia-smi"* ]] || [[ "$output" == *"driver"* ]]
}

@test "nvidia configure verifies a healthy driver and sharing model" {
  _nvidia_present
  _driver_in_use
  _fake_dev_nodes

  run bash "$REPO_ROOT/nvidia/configure.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nvidia-smi"* ]]
  /bin/grep -q "nvidia-persistenced" "$MOCK_LOG"
}

@test "nvidia configure tolerates a missing persistenced unit" {
  _nvidia_present
  _driver_in_use
  _fake_dev_nodes
  export MOCK_SYSTEMCTL_FAIL="1"

  run bash "$REPO_ROOT/nvidia/configure.sh"
  [ "$status" -eq 0 ]
}

@test "nvidia configure fails when device nodes are missing" {
  _nvidia_present
  _driver_in_use

  run bash "$REPO_ROOT/nvidia/configure.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"/dev"* ]]
}

# -------------------------------------------------------------------
# nvidia/update.sh
# -------------------------------------------------------------------

@test "nvidia update refreshes headers and driver and verifies" {
  _nvidia_present
  _driver_in_use
  _fake_dev_nodes
  _write_sources_fixture

  run bash "$REPO_ROOT/nvidia/update.sh"
  [ "$status" -eq 0 ]
  /bin/grep -q "apt-get update" "$MOCK_LOG"
  /bin/grep -q "nvidia-driver" "$MOCK_LOG"
  /bin/grep -q "proxmox-headers-7.0.14-17-pve" "$MOCK_LOG"
  /bin/grep -q "nvidia-smi" "$MOCK_LOG"
}

# -------------------------------------------------------------------
# nvidia/lib.sh helpers
# -------------------------------------------------------------------

@test "nvidia lib detects GPU presence from lspci" {
  _nvidia_present
  run bash -c 'source "$REPO_ROOT/nvidia/lib.sh"; nvidia_detect_gpu'
  [ "$status" -eq 0 ]
  _no_nvidia
  run bash -c 'source "$REPO_ROOT/nvidia/lib.sh"; nvidia_detect_gpu'
  [ "$status" -ne 0 ]
}

# -------------------------------------------------------------------
# nvidia/README.md — operator contract
# -------------------------------------------------------------------

@test "nvidia README documents two stages, sharing model, and no Caddy" {
  /bin/grep -q "install.sh" "$REPO_ROOT/nvidia/README.md"
  /bin/grep -q "configure.sh" "$REPO_ROOT/nvidia/README.md"
  /bin/grep -q "update.sh" "$REPO_ROOT/nvidia/README.md"
  /bin/grep -q "LXC" "$REPO_ROOT/nvidia/README.md"
  /bin/grep -q "Caddy" "$REPO_ROOT/nvidia/README.md"
  /bin/grep -q "NVIDIA_DEBIAN_SOURCES" "$REPO_ROOT/nvidia/README.md"
}
