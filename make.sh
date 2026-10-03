#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$SCRIPT_DIR/work"
UBUNTU_VERSION="${UBUNTU_VERSION:-24.04.5.1}"
UBUNTU_URL="https://releases.ubuntu.com/${UBUNTU_VERSION}/ubuntu-${UBUNTU_VERSION}-desktop-amd64.iso"
ISO_NAME="ubuntu-${UBUNTU_VERSION}-desktop-amd64.iso"
OUTPUT_ISO="ubuntu-${UBUNTU_VERSION}-tv.iso"
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
  echo "  usb-stock Write the unmodified Ubuntu installer to USB (for installing to disk)"
  echo ""
  echo "Environment variables:"
  echo "  UBUNTU_VERSION  Ubuntu version to download (default: 24.04.4)"
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

# Size of the Ubuntu ISO in bytes, from the server (falls back to 6 GB if unknown)
iso_size_bytes() {
  local cl
  cl=$(curl -sIL --max-time 20 "$UBUNTU_URL" 2>/dev/null | awk 'tolower($1)=="content-length:" {cl=$2} END{print cl}' | tr -d '\r')
  [[ "$cl" =~ ^[0-9]+$ ]] && [ "$cl" -gt 0 ] && echo "$cl" || echo $((6 * 1024 * 1024 * 1024))
}

# check_disk_space <bytes needed> <what for>
# Aborts before any long download/build if the volume holding this repo is short.
check_disk_space() {
  local need_bytes="$1" purpose="$2" avail_kb need_kb
  mkdir -p "$WORK_DIR"
  avail_kb=$(df -k "$WORK_DIR" | awk 'NR==2 {print $4}')
  need_kb=$(( need_bytes / 1024 ))
  if [ -z "$avail_kb" ] || [ "$avail_kb" -lt "$need_kb" ]; then
    echo "Error: not enough disk space for $purpose."
    echo "  Needed:    $(( need_kb / 1024 / 1024 )) GB"
    echo "  Available: $(( ${avail_kb:-0} / 1024 / 1024 )) GB on $(df -k "$WORK_DIR" | awk 'NR==2 {print $NF}')"
    echo "  Free up space (old ISOs in $SCRIPT_DIR and $WORK_DIR are a good start) and retry."
    exit 1
  fi
  echo "Disk space OK: $(( avail_kb / 1024 / 1024 )) GB available, $(( need_kb / 1024 / 1024 )) GB needed for $purpose"
}

download_iso() {
  mkdir -p "$WORK_DIR"

  if [ -f "$WORK_DIR/$ISO_NAME" ]; then
    echo "ISO already exists: $WORK_DIR/$ISO_NAME"
    return 0
  fi

  echo "Downloading Ubuntu $UBUNTU_VERSION..."
  echo "URL: $UBUNTU_URL"
  local iso_bytes
  iso_bytes=$(iso_size_bytes)
  check_disk_space $(( iso_bytes + iso_bytes / 10 )) "downloading the ISO ($(( iso_bytes / 1024 / 1024 / 1024 )) GB)"

  # -f makes curl fail on HTTP errors instead of saving the error page as the ISO
  if command -v curl &> /dev/null; then
    curl -fL -o "$WORK_DIR/$ISO_NAME.part" "$UBUNTU_URL"
  elif command -v wget &> /dev/null; then
    wget -O "$WORK_DIR/$ISO_NAME.part" "$UBUNTU_URL"
  else
    echo "Error: Neither curl nor wget found"
    exit 1
  fi

  # A real desktop ISO is several GB; anything small is an error page or a partial file
  local size
  size=$(stat -f%z "$WORK_DIR/$ISO_NAME.part" 2>/dev/null || stat -c%s "$WORK_DIR/$ISO_NAME.part" 2>/dev/null || echo 0)
  if [ "$size" -lt 1000000000 ]; then
    echo "Error: downloaded file is only $size bytes, not an ISO. Check UBUNTU_URL / UBUNTU_VERSION."
    rm -f "$WORK_DIR/$ISO_NAME.part"
    exit 1
  fi
  mv "$WORK_DIR/$ISO_NAME.part" "$WORK_DIR/$ISO_NAME"

  echo "Download complete: $WORK_DIR/$ISO_NAME"
}

build_docker_image() {
  echo "Building Docker image..."
  docker build --platform linux/amd64 -t "$DOCKER_IMAGE" "$SCRIPT_DIR"
}

build_iso() {
  check_docker
  # Input ISO + output ISO + Docker scratch for extract/repack: budget 3x the ISO size,
  # minus the input ISO if it is already on disk.
  local iso_bytes need_bytes
  iso_bytes=$(iso_size_bytes)
  need_bytes=$(( iso_bytes * 3 ))
  [ -f "$WORK_DIR/$ISO_NAME" ] && need_bytes=$(( iso_bytes * 2 ))
  check_disk_space "$need_bytes" "building the custom ISO"
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
    ISO_SIZE=$(du -h "$SCRIPT_DIR/$OUTPUT_ISO" | cut -f1)
    echo ""
    echo "Success! Custom ISO created: $SCRIPT_DIR/$OUTPUT_ISO ($ISO_SIZE)"
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
  local iso_path="${3:-$SCRIPT_DIR/$OUTPUT_ISO}"

  if [ ! -f "$iso_path" ]; then
    echo "Error: ISO not found at $iso_path"
    echo "Run '$0 build' first (or '$0 download' for the stock installer)"
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
  rm -f "$SCRIPT_DIR"/ubuntu-*-e6540.iso   # output name before the -tv rename
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
  usb-stock)
    # Unmodified Ubuntu installer, for installing to a machine's internal drive
    # (the customised ISO has the installer removed). See README "Installing to disk".
    download_iso
    write_usb "$2" "" "$WORK_DIR/$ISO_NAME"
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
