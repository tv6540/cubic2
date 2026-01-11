#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$SCRIPT_DIR/work"
UBUNTU_VERSION="${UBUNTU_VERSION:-24.04.1}"
UBUNTU_URL="https://releases.ubuntu.com/${UBUNTU_VERSION}/ubuntu-${UBUNTU_VERSION}-desktop-amd64.iso"
ISO_NAME="ubuntu-${UBUNTU_VERSION}-desktop-amd64.iso"
OUTPUT_ISO="ubuntu-${UBUNTU_VERSION}-e6540.iso"
DOCKER_IMAGE="cubic2-builder"

print_usage() {
  echo "Usage: $0 [command]"
  echo ""
  echo "Commands:"
  echo "  build     Build the customized ISO (default)"
  echo "  download  Download Ubuntu ISO only"
  echo "  clean     Remove work directory and Docker image"
  echo "  usb       Write ISO to USB (requires: $0 usb /dev/sdX)"
  echo ""
  echo "Environment variables:"
  echo "  UBUNTU_VERSION  Ubuntu version to download (default: 24.04.1)"
  echo ""
  echo "Examples:"
  echo "  $0                    # Build ISO"
  echo "  $0 build              # Build ISO"
  echo "  $0 download           # Download Ubuntu ISO only"
  echo "  $0 usb /dev/sdb       # Write to USB device"
  echo "  UBUNTU_VERSION=24.04 $0 build  # Use specific version"
}

check_docker() {
  if ! command -v docker &> /dev/null; then
    echo "Error: Docker is not installed."
    echo ""
    echo "Install Docker:"
    echo "  macOS: brew install --cask docker"
    echo "  Ubuntu: sudo apt install docker.io && sudo usermod -aG docker \$USER"
    exit 1
  fi

  if ! docker info &> /dev/null; then
    echo "Error: Docker daemon is not running."
    echo "Please start Docker Desktop (macOS) or run: sudo systemctl start docker (Linux)"
    exit 1
  fi
}

download_iso() {
  mkdir -p "$WORK_DIR"

  if [ -f "$WORK_DIR/$ISO_NAME" ]; then
    echo "ISO already exists: $WORK_DIR/$ISO_NAME"
    return 0
  fi

  echo "Downloading Ubuntu $UBUNTU_VERSION..."
  echo "URL: $UBUNTU_URL"

  if command -v curl &> /dev/null; then
    curl -L -o "$WORK_DIR/$ISO_NAME" "$UBUNTU_URL"
  elif command -v wget &> /dev/null; then
    wget -O "$WORK_DIR/$ISO_NAME" "$UBUNTU_URL"
  else
    echo "Error: Neither curl nor wget found"
    exit 1
  fi

  echo "Download complete: $WORK_DIR/$ISO_NAME"
}

build_docker_image() {
  echo "Building Docker image..."
  docker build -t "$DOCKER_IMAGE" "$SCRIPT_DIR"
}

build_iso() {
  check_docker
  download_iso
  build_docker_image

  echo "Creating customized ISO..."
  mkdir -p "$WORK_DIR"

  # Copy pre-setup files to work directory
  cp -r "$SCRIPT_DIR/pre-setup" "$WORK_DIR/"

  # Run Docker container to modify ISO
  docker run --rm --privileged \
    -v "$WORK_DIR/$ISO_NAME:/work/input.iso:ro" \
    -v "$WORK_DIR:/work" \
    "$DOCKER_IMAGE"

  if [ -f "$WORK_DIR/output.iso" ]; then
    mv "$WORK_DIR/output.iso" "$SCRIPT_DIR/$OUTPUT_ISO"
    echo ""
    echo "Success! Custom ISO created: $SCRIPT_DIR/$OUTPUT_ISO"
    echo ""
    echo "To write to USB:"
    echo "  $0 usb /dev/sdX"
  else
    echo "Error: ISO build failed"
    exit 1
  fi
}

write_usb() {
  local device="$1"
  local iso_path="$SCRIPT_DIR/$OUTPUT_ISO"

  if [ -z "$device" ]; then
    echo "Error: No device specified"
    echo "Usage: $0 usb /dev/sdX"
    exit 1
  fi

  if [ ! -f "$iso_path" ]; then
    echo "Error: ISO not found at $iso_path"
    echo "Run '$0 build' first"
    exit 1
  fi

  echo "WARNING: This will erase all data on $device"
  read -p "Continue? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted"
    exit 1
  fi

  echo "Writing ISO to $device..."

  # Detect OS and use appropriate command
  case "$(uname -s)" in
    Darwin*)
      # macOS
      diskutil unmountDisk "$device" || true
      sudo dd if="$iso_path" of="$device" bs=4m status=progress
      ;;
    Linux*)
      # Linux
      sudo umount "$device"* 2>/dev/null || true
      sudo dd if="$iso_path" of="$device" bs=4M status=progress conv=fsync
      ;;
    *)
      echo "Error: Unsupported OS"
      exit 1
      ;;
  esac

  sync
  echo "Done! USB is ready to boot."
}

clean() {
  echo "Cleaning up..."
  rm -rf "$WORK_DIR"
  rm -f "$SCRIPT_DIR/$OUTPUT_ISO"
  docker rmi "$DOCKER_IMAGE" 2>/dev/null || true
  echo "Clean complete"
}

# Main
case "${1:-build}" in
  build)
    build_iso
    ;;
  download)
    download_iso
    ;;
  usb)
    write_usb "$2"
    ;;
  clean)
    clean
    ;;
  help|--help|-h)
    print_usage
    ;;
  *)
    echo "Unknown command: $1"
    print_usage
    exit 1
    ;;
esac
