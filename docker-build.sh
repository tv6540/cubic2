#!/bin/bash
set -e

ISO_IN="/work/input.iso"
ISO_OUT="/work/output.iso"
EXTRACT_DIR="/work/extract"
SQUASH_DIR="/work/squashfs"

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

# Remove ubiquity (installer) and install git
echo "=== Configuring squashfs packages ==="
chroot "$SQUASH_DIR" /bin/bash -c "apt-get update && apt-get remove -y --purge ubiquity ubiquity-* && apt-get install -y git && apt-get clean && rm -rf /var/lib/apt/lists/*" || true

echo "=== Repacking squashfs ==="
rm -f "$SQUASHFS_PATH"
mksquashfs "$SQUASH_DIR" "$SQUASHFS_PATH" -comp xz -b 1M

echo "=== Updating filesystem.size ==="
FSSIZE_PATH=$(dirname "$SQUASHFS_PATH")/filesystem.size
printf $(du -sx --block-size=1 "$SQUASH_DIR" | cut -f1) > "$FSSIZE_PATH"

echo "=== Regenerating md5sum.txt ==="
cd "$EXTRACT_DIR"
find . -type f -print0 | xargs -0 md5sum | grep -v isolinux/boot.cat | grep -v md5sum.txt > md5sum.txt || true

echo "=== Rebuilding ISO ==="
xorriso -as mkisofs \
  -r -V "Ubuntu Custom" \
  -o "$ISO_OUT" \
  -J -joliet-long \
  -l \
  -iso-level 3 \
  -partition_offset 16 \
  --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
  -append_partition 2 0xef "$EXTRACT_DIR/boot/grub/efi.img" \
  -appended_part_as_gpt \
  -c boot/boot.cat \
  -b boot/grub/i386-pc/eltorito.img \
  -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  --grub2-boot-info \
  -eltorito-alt-boot \
  -e --interval:appended_partition_2:all:: \
  -no-emul-boot \
  "$EXTRACT_DIR" 2>/dev/null || \
xorriso -as mkisofs \
  -r -V "Ubuntu Custom" \
  -o "$ISO_OUT" \
  -J -joliet-long \
  -l \
  -b isolinux/isolinux.bin \
  -c isolinux/boot.cat \
  -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  "$EXTRACT_DIR"

echo "=== Done! Output: $ISO_OUT ==="
