#!/usr/bin/env bash
# run_in_docker.sh
# Interactive helper to build the OpenBSD-in-Docker image and run a container in either
# "install" mode (boot installer ISO) or "boot" mode (boot from qcow2 disk).
# This version prompts for firmware choice (legacy|uefi) and passes FIRMWARE into the container.
set -euo pipefail

DEFAULT_IMAGE_TAG="openbsd_docker_amd64:latest"
DEFAULT_BOOT_MODE="install"   # install or boot
DEFAULT_GRAPHICAL="true"
DEFAULT_VNC_DISPLAY="1"
DEFAULT_NOVNC_PORT="6080"
DEFAULT_HOST_VNC_PORT="6080"
DEFAULT_HOST_VNC_RAW_PORT="5901"
DEFAULT_HOST_SSH_PORT="2222"
DEFAULT_MEMORY="2048"
DEFAULT_CORES="2"
DEFAULT_DISK_SIZE="20G"
DEFAULT_OPENBSD_ISO_URL="https://cdn.openbsd.org/pub/OpenBSD/7.4/amd64/install74.iso"
DEFAULT_FIRMWARE="legacy"     # legacy or uefi

NONINTERACTIVE=0
for arg in "$@"; do
  case "$arg" in
    --non-interactive|-n) NONINTERACTIVE=1 ;;
    --help|-h)
      cat <<EOF
Usage: $0 [--non-interactive|-n]

Interactive script that:
 - builds the docker image (Dockerfile in openbsd_docker_amd64)
 - runs a docker container with sensible defaults and env vars for BOOT_MODE, FIRMWARE, etc.

Options:
  --non-interactive, -n   Use defaults and do not prompt.
  --help, -h              Show this help.

EOF
      exit 0
      ;;
  esac
done

prompt() {
  local var_name="$1"
  local default="$2"
  local prompt_text="$3"
  local result
  if [ "$NONINTERACTIVE" -eq 1 ]; then
    result="$default"
  else
    read -r -p "$prompt_text [$default]: " result
    result="${result:-$default}"
  fi
  eval "$var_name=\"\$result\""
}

# Basic checks
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker command not found. Install Docker and ensure the daemon is running."
  exit 1
fi

echo "== openbsd Docker build & run helper =="
echo

prompt IMAGE_TAG "$DEFAULT_IMAGE_TAG" "Image tag to build"
prompt BOOT_MODE "$DEFAULT_BOOT_MODE" "BOOT_MODE (install|boot)"
if [ "$BOOT_MODE" = "install" ]; then
  prompt OPENBSD_ISO_URL "$DEFAULT_OPENBSD_ISO_URL" "OpenBSD installer ISO URL (leave blank to place ISO in ./images manually)"
else
  prompt OPENBSD_ISO_URL "" "OpenBSD installer ISO URL (optional, only used with BOOT_MODE=install)"
fi
prompt ISO_NAME "install.iso" "ISO filename in ./images"
prompt DISK_NAME "disk.qcow2" "Disk image filename in ./images"
prompt DISK_SIZE "$DEFAULT_DISK_SIZE" "Disk size for new qcow2 (e.g. 20G)"
prompt MEMORY "$DEFAULT_MEMORY" "Memory (MB) for VM"
prompt CORES "$DEFAULT_CORES" "CPU cores for VM"
prompt GRAPHICAL "$DEFAULT_GRAPHICAL" "GRAPHICAL (true|false) - use VNC/noVNC or serial"
prompt VNC_DISPLAY "$DEFAULT_VNC_DISPLAY" "VNC display number (1 => 5901)"
prompt NOVNC_PORT "$DEFAULT_NOVNC_PORT" "noVNC web UI port inside container"
prompt HOST_VNC_PORT "$DEFAULT_HOST_VNC_PORT" "Host port mapped to noVNC web UI"
prompt expose_raw_vnc "no" "Expose raw VNC TCP port to host? (yes|no)"
if [ "${expose_raw_vnc,,}" = "yes" ] || [ "${expose_raw_vnc,,}" = "y" ]; then
  prompt HOST_VNC_RAW_PORT "$DEFAULT_HOST_VNC_RAW_PORT" "Host raw VNC TCP port"
else
  HOST_VNC_RAW_PORT=""
fi

# Prompt for firmware choice
prompt FIRMWARE "$DEFAULT_FIRMWARE" "Firmware (legacy|uefi) - default legacy BIOS"

# Ask whether to expose SSH
prompt expose_ssh "no" "Expose guest SSH port to Docker host? (yes|no)"
if [ "${expose_ssh,,}" = "yes" ] || [ "${expose_ssh,,}" = "y" ]; then
  prompt HOST_SSH_PORT "$DEFAULT_HOST_SSH_PORT" "Host port forwarded to guest SSH (guest:22)"
else
  HOST_SSH_PORT=""
fi

prompt DETACHED "no" "Run container detached? (yes|no)"

VNC_PORT=$((5900 + VNC_DISPLAY))

IMAGES_DIR="$(pwd)/images"
if [ ! -d "$IMAGES_DIR" ]; then
  echo "Creating images directory at $IMAGES_DIR"
  mkdir -p "$IMAGES_DIR"
  chmod 0777 "$IMAGES_DIR" || true
fi

echo
echo "Summary of settings:"
cat <<EOF
 Image tag:         $IMAGE_TAG
 BOOT_MODE:         $BOOT_MODE
 OPENBSD_ISO_URL:   ${OPENBSD_ISO_URL:-<not set>}
 ISO path:          $IMAGES_DIR/$ISO_NAME
 Disk path:         $IMAGES_DIR/$DISK_NAME
 Disk size:         $DISK_SIZE
 Memory:            $MEMORY MB
 CPU cores:         $CORES
 GRAPHICAL:         $GRAPHICAL
 VNC display:       $VNC_DISPLAY (TCP port $VNC_PORT)
 noVNC port (ctr):  $NOVNC_PORT
 noVNC port (host): $HOST_VNC_PORT
 Raw VNC host port: ${HOST_VNC_RAW_PORT:-<not exposed>}
 Firmware:          $FIRMWARE
 SSH host port:     ${HOST_SSH_PORT:-<not exposed>}
 Run detached:      $DETACHED
EOF

if [ "$NONINTERACTIVE" -eq 0 ]; then
  read -r -p "Proceed to build and run the container? (Y/n) " proceed
  proceed="${proceed:-Y}"
  if [[ ! "$proceed" =~ ^[Yy] ]]; then
    echo "Aborted by user."
    exit 0
  fi
fi

echo
echo "Building Docker image: $IMAGE_TAG"
docker build -t "$IMAGE_TAG" .

if docker ps -a --format '{{.Names}}' | grep -q "^openbsd-kvm$"; then
  echo "Found existing container named openbsd-kvm - removing it."
  docker rm -f openbsd-kvm >/dev/null 2>&1 || true
fi

RUN_ARGS=()
RUN_ARGS+=(--rm)
if [ "${DETACHED,,}" = "yes" ] || [ "${DETACHED,,}" = "y" ]; then
  RUN_ARGS+=(-d)
fi
RUN_ARGS+=(--name openbsd-kvm)
if [ -e /dev/kvm ]; then
  RUN_ARGS+=(--device /dev/kvm:/dev/kvm)
else
  echo "Note: running without --device /dev/kvm (no KVM available)."
fi
RUN_ARGS+=(--security-opt seccomp=unconfined)
RUN_ARGS+=(-v "$IMAGES_DIR":/images)
RUN_ARGS+=(-p "${HOST_VNC_PORT}:${NOVNC_PORT}")

if [ -n "$HOST_VNC_RAW_PORT" ]; then
  RUN_ARGS+=(-p "${HOST_VNC_RAW_PORT}:${VNC_PORT}")
fi

if [ -n "$HOST_SSH_PORT" ]; then
  RUN_ARGS+=(-p "${HOST_SSH_PORT}:${HOST_SSH_PORT}")
fi

ENV_ARGS=(
  -e "BOOT_MODE=${BOOT_MODE}"
  -e "OPENBSD_ISO_URL=${OPENBSD_ISO_URL}"
  -e "ISO_NAME=${ISO_NAME}"
  -e "DISK_NAME=${DISK_NAME}"
  -e "DISK_SIZE=${DISK_SIZE}"
  -e "MEMORY=${MEMORY}"
  -e "CORES=${CORES}"
  -e "GRAPHICAL=${GRAPHICAL}"
  -e "VNC_DISPLAY=${VNC_DISPLAY}"
  -e "NOVNC_PORT=${NOVNC_PORT}"
  -e "FIRMWARE=${FIRMWARE}"
)
if [ -n "$HOST_SSH_PORT" ]; then
  ENV_ARGS+=(-e "HOST_SSH_PORT=${HOST_SSH_PORT}")
fi

DOCKER_CMD=(docker run "${RUN_ARGS[@]}" "${ENV_ARGS[@]}" "$IMAGE_TAG")

echo
echo "Running container:"
printf '%q ' "${DOCKER_CMD[@]}"
echo
echo

"${DOCKER_CMD[@]}"

echo
echo "Container started."
if [ "${DETACHED,,}" = "yes" ] || [ "${DETACHED,,}" = "y" ]; then
  echo "Use: docker logs -f openbsd-kvm"
else
  echo "QEMU output is attached to this terminal (unless you used detached mode)."
fi

echo
echo "Access information:"
if [ "${GRAPHICAL,,}" = "true" ]; then
  echo " - noVNC web UI: http://<docker-host>:${HOST_VNC_PORT}/vnc.html"
  if [ -n "$HOST_VNC_RAW_PORT" ]; then
    echo " - Raw VNC (if exposed): vnc://<docker-host>:${HOST_VNC_RAW_PORT}"
  fi
else
  echo " - Running headless. QEMU serial console is attached to the container's logs/stdout."
fi

if [ -n "$HOST_SSH_PORT" ]; then
  echo " - SSH (after guest sshd running): ssh -p ${HOST_SSH_PORT} user@<docker-host>"
else
  echo " - SSH port not exposed on the Docker host."
fi

echo
echo "Images and disk are stored on host at: $IMAGES_DIR"
