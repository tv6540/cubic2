#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$SCRIPT_DIR/work"
UBUNTU_VERSION="${UBUNTU_VERSION:-24.04.3}"
UBUNTU_URL="https://releases.ubuntu.com/${UBUNTU_VERSION}/ubuntu-${UBUNTU_VERSION}-desktop-amd64.iso"
ISO_NAME="ubuntu-${UBUNTU_VERSION}-desktop-amd64.iso"
OUTPUT_ISO="ubuntu-${UBUNTU_VERSION}-e6540.iso"
DOCKER_IMAGE="cubic2-builder"

print_usage() {
  echo "Usage: $0 [command]"
  echo ""
  echo "Commands:"
  echo "  all       Clean + Build + USB in one go (default)"
  echo "  build     Build the customized ISO only"
  echo "  download  Download Ubuntu ISO only"
  echo "  clean     Remove work directory and Docker image"
  echo "  usb       Write ISO to USB (interactive device selection)"
  echo ""
  echo "Environment variables:"
  echo "  UBUNTU_VERSION  Ubuntu version to download (default: 24.04.3)"
  echo ""
  echo "Examples:"
  echo "  $0                    # Clean, build, and write to USB"
  echo "  $0 all                # Same as above"
  echo "  $0 build              # Build ISO only"
  echo "  $0 usb                # Write to USB (shows device picker)"
  echo "  $0 usb /dev/disk4     # Write to specific device"
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
  docker build --platform linux/amd64 -t "$DOCKER_IMAGE" "$SCRIPT_DIR"
}

build_iso() {
  check_docker
  download_iso
  build_docker_image

  echo "Creating customized ISO..."
  mkdir -p "$WORK_DIR"

  # Copy pre-setup files and wallpapers to work directory
  cp -r "$SCRIPT_DIR/pre-setup" "$WORK_DIR/"
  cp -r "$SCRIPT_DIR/wallpaper" "$WORK_DIR/"

  # Run Docker container to modify ISO
  docker run --rm --privileged --platform linux/amd64 \
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

list_usb_devices() {
  case "$(uname -s)" in
    Darwin*)
      # macOS - list external physical disks
      diskutil list external 2>/dev/null | grep -E "^/dev/disk" | while read -r line; do
        local disk=$(echo "$line" | awk '{print $1}')
        local size=$(diskutil info "$disk" 2>/dev/null | grep "Disk Size" | awk -F: '{print $2}' | xargs)
        local name=$(diskutil info "$disk" 2>/dev/null | grep "Media Name" | awk -F: '{print $2}' | xargs)
        echo "$disk|$size|$name"
      done
      ;;
    Linux*)
      # Linux - list removable block devices
      lsblk -d -o NAME,SIZE,MODEL,RM 2>/dev/null | awk '$4 == "1" {print "/dev/"$1"|"$2"|"$3}'
      ;;
  esac
}

select_usb_device() {
  echo "Scanning for USB devices..."
  echo ""

  local devices=()
  while IFS= read -r line; do
    [ -n "$line" ] && devices+=("$line")
  done < <(list_usb_devices)

  if [ ${#devices[@]} -eq 0 ]; then
    echo "No USB devices found."
    echo "Please insert a USB drive and try again."
    exit 1
  fi

  echo "Available USB devices:"
  echo ""
  for i in "${!devices[@]}"; do
    IFS='|' read -r dev size name <<< "${devices[$i]}"
    printf "  [%d] %s - %s (%s)\n" $((i+1)) "$dev" "${size:-unknown size}" "${name:-unnamed}"
  done
  echo ""

  local selection
  while true; do
    read -p "Select device [1-${#devices[@]}] or 'q' to quit: " selection
    if [[ "$selection" == "q" ]]; then
      echo "Aborted"
      exit 0
    fi
    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#devices[@]} ]; then
      break
    fi
    echo "Invalid selection. Please enter a number between 1 and ${#devices[@]}"
  done

  IFS='|' read -r SELECTED_DEVICE _ _ <<< "${devices[$((selection-1))]}"
}

write_usb() {
  local device="$1"
  local skip_confirm="$2"
  local iso_path="$SCRIPT_DIR/$OUTPUT_ISO"

  if [ ! -f "$iso_path" ]; then
    echo "Error: ISO not found at $iso_path"
    echo "Run '$0 build' first"
    exit 1
  fi

  # If no device specified, show interactive selection
  if [ -z "$device" ]; then
    select_usb_device
    device="$SELECTED_DEVICE"
  fi

  # Skip confirmation if already done (e.g., from do_all)
  if [ "$skip_confirm" != "yes" ]; then
    echo ""
    echo "WARNING: This will ERASE ALL DATA on $device"
    read -p "Type 'yes' to confirm: " confirm
    if [ "$confirm" != "yes" ]; then
      echo "Aborted"
      exit 1
    fi
  fi

  echo ""
  echo "Writing ISO to $device..."

  # Detect OS and use appropriate command
  case "$(uname -s)" in
    Darwin*)
      # macOS - use raw device (rdisk) for ~10x faster writes
      diskutil unmountDisk "$device" || true
      RAW_DEVICE=$(echo "$device" | sed 's|/dev/disk|/dev/rdisk|')
      sudo dd if="$iso_path" of="$RAW_DEVICE" bs=4m status=progress
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

  # Eject the USB
  case "$(uname -s)" in
    Darwin*)
      diskutil eject "$device" 2>/dev/null || true
      ;;
    Linux*)
      sudo eject "$device" 2>/dev/null || true
      ;;
  esac

  echo ""
  echo "Done! USB is ready to boot (ejected)."

  # Audible notification
  case "$(uname -s)" in
    Darwin*)
      afplay /System/Library/Sounds/Glass.aiff 2>/dev/null &
      ;;
    Linux*)
      paplay /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null &
      ;;
  esac
  printf '\a'  # Terminal bell fallback
}

clean() {
  echo "Cleaning up build artifacts (preserving downloaded ISO)..."
  # Remove pre-setup copy but keep the downloaded ISO
  rm -rf "$WORK_DIR/pre-setup"
  rm -rf "$WORK_DIR/wallpaper"
  rm -rf "$WORK_DIR/extract"
  rm -rf "$WORK_DIR/squashfs"
  rm -f "$WORK_DIR/output.iso"
  rm -f "$SCRIPT_DIR/$OUTPUT_ISO"
  docker rmi "$DOCKER_IMAGE" 2>/dev/null || true
  echo "Clean complete (ISO preserved at $WORK_DIR/$ISO_NAME if present)"
}

do_all() {
  # Get ALL prompts/checks out of the way FIRST
  check_docker
  sudo -v || { echo "Error: sudo authentication failed"; exit 1; }

  # Keep sudo alive in background
  (while true; do sudo -n true; sleep 50; done 2>/dev/null) &
  SUDO_KEEPALIVE_PID=$!
  trap "kill $SUDO_KEEPALIVE_PID 2>/dev/null" EXIT

  # Select USB device before long build
  select_usb_device
  local target_device="$SELECTED_DEVICE"

  # Confirm destruction NOW, not after 20 min build
  echo ""
  echo "WARNING: This will ERASE ALL DATA on $target_device"
  read -p "Type 'yes' to confirm: " confirm
  if [ "$confirm" != "yes" ]; then
    echo "Aborted"
    kill $SUDO_KEEPALIVE_PID 2>/dev/null || true
    exit 0
  fi

  echo ""
  echo "=== Running: clean + build + usb ==="
  echo "Target USB: $target_device"
  echo ""

  # Clean
  echo "=== Step 1/3: Clean ==="
  clean
  echo ""

  # Build
  echo "=== Step 2/3: Build ==="
  build_iso
  echo ""

  # Write to USB
  echo "=== Step 3/3: Write to USB ==="
  write_usb "$target_device" "yes"

  # Kill sudo keepalive
  kill $SUDO_KEEPALIVE_PID 2>/dev/null || true

  echo ""
  echo "=== All done! ==="
}

# Main
case "${1:-all}" in
  all)
    do_all
    ;;
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
