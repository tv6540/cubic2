#!/bin/bash
set -e

ISO_IN="/work/input.iso"
ISO_OUT="/work/output.iso"
# Use container's native filesystem for operations that need full Linux support
EXTRACT_DIR="/tmp/extract"
SQUASH_DIR="/tmp/squashfs"
EFI_IMG="/tmp/efi.img"

echo "=== Extracting EFI partition from original ISO ==="
# Get EFI partition info using xorriso report
EFI_INFO=$(xorriso -indev "$ISO_IN" -report_el_torito as_mkisofs 2>&1 | grep -A1 "append_partition 2")
# Extract the interval range (e.g., 12105120d-12115263d)
INTERVAL=$(echo "$EFI_INFO" | grep -oP '\d+d-\d+d' | head -1)
if [ -n "$INTERVAL" ]; then
  START_SECTOR=$(echo "$INTERVAL" | cut -d'-' -f1 | tr -d 'd')
  END_SECTOR=$(echo "$INTERVAL" | cut -d'-' -f2 | tr -d 'd')
  COUNT=$((END_SECTOR - START_SECTOR + 1))
  echo "Extracting EFI partition: sectors $START_SECTOR to $END_SECTOR ($COUNT sectors)"
  dd if="$ISO_IN" of="$EFI_IMG" bs=512 skip="$START_SECTOR" count="$COUNT" status=progress
else
  echo "Warning: Could not find EFI partition info, creating minimal EFI image"
  # Create a minimal EFI boot image as fallback
  dd if=/dev/zero of="$EFI_IMG" bs=1M count=5
fi

echo "=== Extracting ISO ==="
mkdir -p "$EXTRACT_DIR"
xorriso -osirrox on -indev "$ISO_IN" -extract / "$EXTRACT_DIR"
chmod -R u+w "$EXTRACT_DIR"

echo "=== Finding and extracting squashfs ==="
SQUASHFS_PATH=$(find "$EXTRACT_DIR" -name "*.squashfs" -o -name "filesystem.squashfs" 2>/dev/null | head -1)
if [ -z "$SQUASHFS_PATH" ]; then
  SQUASHFS_PATH="$EXTRACT_DIR/casper/filesystem.squashfs"
fi
echo "Found squashfs at: $SQUASHFS_PATH"

rm -rf "$SQUASH_DIR"
unsquashfs -d "$SQUASH_DIR" "$SQUASHFS_PATH"

echo "=== Injecting setup files ==="
# Copy setup script
cp /work/pre-setup/setup "$SQUASH_DIR/usr/bin/setup"
chmod 755 "$SQUASH_DIR/usr/bin/setup"
chown root:root "$SQUASH_DIR/usr/bin/setup"

# Copy autostart desktop file
mkdir -p "$SQUASH_DIR/etc/xdg/autostart"
cp /work/pre-setup/setup.desktop "$SQUASH_DIR/etc/xdg/autostart/setup.desktop"
chmod 644 "$SQUASH_DIR/etc/xdg/autostart/setup.desktop"

# Disable gnome-initial-setup (Welcome to Ubuntu wizard)
rm -f "$SQUASH_DIR/etc/xdg/autostart/gnome-initial-setup-first-login.desktop"
# For existing ubuntu user (not /etc/skel which only works for new users)
mkdir -p "$SQUASH_DIR/home/ubuntu/.config"
echo "yes" > "$SQUASH_DIR/home/ubuntu/.config/gnome-initial-setup-done"
chown -R 1000:1000 "$SQUASH_DIR/home/ubuntu/.config"

# VLC - disable metadata popup AND network access
# Ref: https://wiki.videolan.org/VLC_HowTo/Disable_%22Privacy_Network_Policies%22_(Qt4)/
# Ref: https://forums.whonix.org/t/disable-vlc-metadata-collection-by-default/18674
mkdir -p "$SQUASH_DIR/home/ubuntu/.config/vlc"
cat > "$SQUASH_DIR/home/ubuntu/.config/vlc/vlcrc" << 'EOF'
[qt]
qt-privacy-ask=0
metadata-network-access=0
EOF
chown -R 1000:1000 "$SQUASH_DIR/home/ubuntu/.config/vlc"

# Pre-configure GNOME settings via dconf database (gsettings won't work at runtime)
# Ref: https://help.gnome.org/system-admin-guide/dconf-keyfiles.html
# Ref: https://manpages.ubuntu.com/manpages/focal/man1/dconf.1.html
# dconf compile expects a DIRECTORY of keyfiles, not a single file
mkdir -p "$SQUASH_DIR/home/ubuntu/.config/dconf"
mkdir -p /tmp/dconf-keyfiles.d
cat > /tmp/dconf-keyfiles.d/00-settings << 'EOF'
[org/gnome/shell]
favorite-apps=['google-chrome.desktop', 'vlc.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Terminal.desktop']

[org/gnome/desktop/interface]
color-scheme='prefer-dark'
gtk-theme='Yaru-dark'

[org/gnome/desktop/screensaver]
lock-enabled=true
lock-delay=uint32 0

[org/gnome/desktop/session]
idle-delay=uint32 300

[org/gnome/desktop/remote-desktop/rdp]
enable=false

[org/gnome/desktop/remote-desktop/vnc]
enable=false
EOF
# Compile dconf database from keyfile directory
dconf compile "$SQUASH_DIR/home/ubuntu/.config/dconf/user" /tmp/dconf-keyfiles.d
chown -R 1000:1000 "$SQUASH_DIR/home/ubuntu/.config/dconf"
rm -rf /tmp/dconf-keyfiles.d

# Note: Package modification (removing ubiquity, installing git) is skipped
# because Docker containers typically don't have network access for apt.
# The live system will have network at boot time - setup script handles git clone.
echo "=== Skipping package modification (no network in build container) ==="

echo "=== Configuring GRUB ==="
# Set timeout to 5 seconds
sed -i 's/set timeout=30/set timeout=5/' "$EXTRACT_DIR/boot/grub/grub.cfg"
# Remove quiet splash to show boot progress, add nomodeset for compatibility
sed -i 's/quiet splash/nomodeset/' "$EXTRACT_DIR/boot/grub/grub.cfg"

echo "=== Removing unused files to reduce ISO size ==="
# Remove offline package pool (~1.9GB) - not needed with internet access
rm -rf "$EXTRACT_DIR/pool"
rm -rf "$EXTRACT_DIR/dists"

# Keep only core squashfs layers, remove all variants (language, secureboot, etc.)
# Required: minimal.squashfs, minimal.standard.squashfs, minimal.standard.live.squashfs
find "$EXTRACT_DIR/casper" -name "*.squashfs" \
  ! -name "minimal.squashfs" \
  ! -name "minimal.standard.squashfs" \
  ! -name "minimal.standard.live.squashfs" \
  -delete
# Clean up related metadata files
find "$EXTRACT_DIR/casper" -name "*.squashfs.gpg" -delete
find "$EXTRACT_DIR/casper" -name "*.manifest" \
  ! -name "minimal.squashfs.manifest" \
  ! -name "minimal.standard.squashfs.manifest" \
  ! -name "minimal.standard.live.squashfs.manifest" \
  -delete
find "$EXTRACT_DIR/casper" -name "*.size" \
  ! -name "minimal.size" \
  ! -name "minimal.standard.size" \
  ! -name "minimal.standard.live.size" \
  -delete

echo "=== Repacking squashfs ==="
rm -f "$SQUASHFS_PATH"
mksquashfs "$SQUASH_DIR" "$SQUASHFS_PATH" -comp xz -b 1M

echo "=== Updating filesystem.size ==="
FSSIZE_PATH=$(dirname "$SQUASHFS_PATH")/filesystem.size
printf $(du -sx --block-size=1 "$SQUASH_DIR" | cut -f1) > "$FSSIZE_PATH"

echo "=== Regenerating md5sum.txt ==="
(cd "$EXTRACT_DIR" && find . -type f -print0 | xargs -0 md5sum | grep -v isolinux/boot.cat | grep -v md5sum.txt > md5sum.txt) || true

echo "=== Rebuilding ISO ==="
# Get EFI image size in 512-byte sectors for boot-load-size
EFI_SIZE_SECTORS=$(( $(stat -c%s "$EFI_IMG") / 512 ))
echo "EFI image size: $EFI_SIZE_SECTORS sectors"

xorriso -as mkisofs \
  -r -V "Ubuntu Custom" \
  -o "$ISO_OUT" \
  -J -joliet-long \
  -l \
  -iso-level 3 \
  -partition_cyl_align off \
  -partition_offset 16 \
  --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
  --protective-msdos-label \
  --mbr-force-bootable \
  -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b "$EFI_IMG" \
  -appended_part_as_gpt \
  -iso_mbr_part_type a2a0d0ebe5b9334487c068b6b72699c7 \
  -c '/boot.catalog' \
  -b 'boot/grub/i386-pc/eltorito.img' \
  -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  --grub2-boot-info \
  -eltorito-alt-boot \
  -e --interval:appended_partition_2:all:: \
  -no-emul-boot \
  -boot-load-size "$EFI_SIZE_SECTORS" \
  "$EXTRACT_DIR"

echo "=== Cleaning up ==="
rm -rf "$EXTRACT_DIR" "$SQUASH_DIR" "$EFI_IMG"

ISO_SIZE=$(du -h "$ISO_OUT" | cut -f1)
echo "=== Done! Output: $ISO_OUT ($ISO_SIZE) ==="
