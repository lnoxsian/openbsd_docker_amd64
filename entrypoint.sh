#!/usr/bin/env bash
set -euo pipefail

# Entrypoint for openbsd-kvm container
# Supports:
#  - BOOT_MODE: "install" or "boot"
#  - FIRMWARE: "legacy" (default) or "uefi"
#  - GRAPHICAL: "true" or "false"
#
# The script will attempt to use UEFI (OVMF) when FIRMWARE=uefi and a suitable
# OVMF code file exists inside the container. If not found, it will fall back
# to legacy BIOS.

OPENBSD_ISO_URL="${OPENBSD_ISO_URL:-}"
ISO_NAME="${ISO_NAME:-install.iso}"
DISK_NAME="${DISK_NAME:-disk.qcow2}"
DISK_SIZE="${DISK_SIZE:-20G}"
MEMORY="${MEMORY:-2048}"   # in MB
CORES="${CORES:-2}"
HOST_SSH_PORT="${HOST_SSH_PORT:-2222}"
GRAPHICAL="${GRAPHICAL:-false}"
BOOT_MODE="${BOOT_MODE:-install}"   # "install" or "boot"
FIRMWARE="${FIRMWARE:-legacy}"      # "legacy" or "uefi"

# VNC / noVNC
VNC_DISPLAY="${VNC_DISPLAY:-1}"     # QEMU display number (1 => 5901)
NOVNC_PORT="${NOVNC_PORT:-6080}"    # Port to serve noVNC web UI inside container
VNC_PORT=$((5900 + VNC_DISPLAY))

IMAGES_DIR="/images"
ISO_PATH="${IMAGES_DIR}/${ISO_NAME}"
DISK_PATH="${IMAGES_DIR}/${DISK_NAME}"
NOVNC_WEB_DIR="/opt/noVNC"

mkdir -p "${IMAGES_DIR}"
chmod 0777 "${IMAGES_DIR}" || true

# Verify required binaries
if ! command -v qemu-img >/dev/null 2>&1; then
  echo "ERROR: qemu-img not found in the container. Ensure the image includes qemu/qemu-img."
  exit 1
fi
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
  echo "ERROR: qemu-system-x86_64 not found in the container."
  exit 1
fi

# Ensure ISO present in install mode (download if OPENBSD_ISO_URL provided)
if [ "${BOOT_MODE}" = "install" ]; then
  if [ ! -f "${ISO_PATH}" ]; then
    if [ -n "${OPENBSD_ISO_URL}" ]; then
      echo "ISO not found at ${ISO_PATH}. Downloading from ${OPENBSD_ISO_URL} ..."
      tmp_iso="${ISO_PATH}.part"
      curl -L --fail --retry 5 --retry-delay 3 -o "${tmp_iso}" "${OPENBSD_ISO_URL}"
      mv "${tmp_iso}" "${ISO_PATH}"
      echo "Downloaded ISO to ${ISO_PATH}."
    else
      echo "ERROR: BOOT_MODE=install but ISO not found at ${ISO_PATH} and OPENBSD_ISO_URL is not set."
      echo "Set OPENBSD_ISO_URL or place the ISO at ${ISO_PATH}."
      exit 1
    fi
  fi
fi

# Create disk image if missing
if [ ! -f "${DISK_PATH}" ]; then
  echo "Creating qcow2 disk ${DISK_PATH} (${DISK_SIZE}) ..."
  qemu-img create -f qcow2 "${DISK_PATH}" "${DISK_SIZE}"
fi

# KVM availability
USE_KVM="false"
if [ -e /dev/kvm ]; then
  if [ -r /dev/kvm ] || [ -w /dev/kvm ]; then
    USE_KVM="true"
  else
    echo "Warning: /dev/kvm exists but is not accessible (permissions). KVM disabled."
  fi
else
  echo "Note: /dev/kvm not present inside container; QEMU will run in emulation mode (slow)."
fi

QEMU_BIN="qemu-system-x86_64"
QEMU_ARGS=()

if [ "${USE_KVM}" = "true" ]; then
  QEMU_ARGS+=("-enable-kvm" "-cpu" "host")
  echo "KVM available: enabling -enable-kvm."
else
  echo "KVM not available: running without -enable-kvm (emulation)."
fi

QEMU_ARGS+=("-m" "${MEMORY}" "-smp" "${CORES}")
QEMU_ARGS+=("-drive" "file=${DISK_PATH},if=virtio,cache=writeback,format=qcow2")

# Firmware: legacy (BIOS) or uefi (OVMF)
if [ "${FIRMWARE}" = "uefi" ]; then
  echo "FIRMWARE=uefi requested: looking for OVMF firmware in the container..."
  OVMF_CANDIDATES=(
    "/usr/share/edk2-ovmf/OVMF_CODE.fd"
    "/usr/share/edk2/ovmf/OVMF_CODE.fd"
    "/usr/share/ovmf/OVMF_CODE.fd"
    "/usr/share/qemu/ovmf-x86_64-code.bin"
    "/usr/share/qemu/ovmf-x64-code.bin"
    "/usr/share/OVMF/OVMF_CODE.fd"
  )
  OVMF_CODE=""
  for p in "${OVMF_CANDIDATES[@]}"; do
    if [ -f "${p}" ]; then
      OVMF_CODE="${p}"
      break
    fi
  done

  if [ -n "${OVMF_CODE}" ]; then
    echo "Found OVMF code file: ${OVMF_CODE}"
    # Create a writable vars file (copy the code file to use as a template)
    OVMF_VARS="/tmp/OVMF_VARS.fd"
    if [ ! -f "${OVMF_VARS}" ]; then
      echo "Preparing writable OVMF vars file at ${OVMF_VARS}"
      cp "${OVMF_CODE}" "${OVMF_VARS}"
      chmod 666 "${OVMF_VARS}" || true
    fi
    # Add pflash drives: code (readonly) and vars (writable)
    QEMU_ARGS+=(-drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}")
    QEMU_ARGS+=(-drive "if=pflash,format=raw,file=${OVMF_VARS}")
    echo "UEFI support enabled using pflash drives."
  else
    echo "WARNING: No OVMF/EDK2 firmware found in container; falling back to legacy BIOS."
    FIRMWARE="legacy"
  fi
else
  echo "FIRMWARE=legacy (BIOS) selected."
fi

# Mode-specific boot configuration
case "${BOOT_MODE}" in
  install)
    echo "BOOT_MODE=install: attaching ISO ${ISO_PATH} as CD-ROM and setting boot to CD."
    QEMU_ARGS+=("-cdrom" "${ISO_PATH}" "-boot" "d")
    ;;
  boot)
    echo "BOOT_MODE=boot: booting from disk image."
    QEMU_ARGS+=("-boot" "c")
    ;;
  *)
    echo "ERROR: unknown BOOT_MODE='${BOOT_MODE}'. Use 'install' or 'boot'."
    exit 1
    ;;
esac

# Networking: user-mode with hostfwd for SSH (only if HOST_SSH_PORT provided)
if [ -n "${HOST_SSH_PORT:-}" ]; then
  QEMU_ARGS+=("-netdev" "user,id=net0,hostfwd=tcp::${HOST_SSH_PORT}-:22")
else
  # still create a network device without hostfwd so guest has networking
  QEMU_ARGS+=("-netdev" "user,id=net0")
fi
QEMU_ARGS+=("-device" "virtio-net-pci,netdev=net0")

# Graphics / VNC / noVNC
if [ "${GRAPHICAL}" = "true" ]; then
  QEMU_ARGS+=("-vnc" "127.0.0.1:${VNC_DISPLAY}")
  echo "Starting QEMU with VNC on 127.0.0.1:${VNC_PORT} (display ${VNC_DISPLAY})."

  if [ -d "${NOVNC_WEB_DIR}" ]; then
    if command -v websockify >/dev/null 2>&1; then
      echo "Starting websockify serving ${NOVNC_WEB_DIR} on port ${NOVNC_PORT}, proxying to 127.0.0.1:${VNC_PORT}"
      websockify --web "${NOVNC_WEB_DIR}" "0.0.0.0:${NOVNC_PORT}" "127.0.0.1:${VNC_PORT}" --heartbeat=30 &
      WEBSOCKIFY_PID=$!
      echo "websockify pid=${WEBSOCKIFY_PID}"
    else
      echo "WARNING: websockify not found. noVNC will not be available."
    fi
  else
    echo "WARNING: noVNC web directory ${NOVNC_WEB_DIR} not found. noVNC will not be available."
  fi
else
  QEMU_ARGS+=("-nographic" "-serial" "mon:stdio")
  echo "Starting QEMU in headless mode (serial console)."
fi

echo "Final QEMU command:"
echo "${QEMU_BIN} ${QEMU_ARGS[*]}"

# Execute QEMU (replace shell)
exec "${QEMU_BIN}" "${QEMU_ARGS[@]}"
