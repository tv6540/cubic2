#!/bin/bash
set -e

ISO_IN="/work/input.iso"
ISO_OUT="/work/output.iso"
EXTRACT_DIR="/tmp/extract"
SQUASH_DIR="/tmp/squashfs"
EFI_IMG="/tmp/efi.img"

echo "=== Extracting EFI partition from original ISO ==="
EFI_INFO=$(xorriso -indev "$ISO_IN" -report_el_torito as_mkisofs 2>&1 | grep -A1 "append_partition 2")
INTERVAL=$(echo "$EFI_INFO" | grep -oP '\d+d-\d+d' | head -1)
if [ -n "$INTERVAL" ]; then
  START_SECTOR=$(echo "$INTERVAL" | cut -d'-' -f1 | tr -d 'd')
  END_SECTOR=$(echo "$INTERVAL" | cut -d'-' -f2 | tr -d 'd')
  COUNT=$((END_SECTOR - START_SECTOR + 1))
  echo "Extracting EFI partition: sectors $START_SECTOR to $END_SECTOR ($COUNT sectors)"
  dd if="$ISO_IN" of="$EFI_IMG" bs=512 skip="$START_SECTOR" count="$COUNT" status=progress
else
  echo "Warning: Could not find EFI partition info, creating minimal EFI image"
  dd if=/dev/zero of="$EFI_IMG" bs=1M count=5
fi

echo "=== Extracting ISO ==="
mkdir -p "$EXTRACT_DIR"
xorriso -osirrox on -indev "$ISO_IN" -extract / "$EXTRACT_DIR"
chmod -R u+w "$EXTRACT_DIR"

CASPER_DIR="$EXTRACT_DIR/casper"

echo "=== Finding and removing welcome/initial-setup from ALL squashfs layers ==="
# Ubuntu 24.04 uses layered squashfs: minimal -> minimal.standard -> minimal.standard.live
# The welcome wizard could be: gnome-initial-setup, ubuntu-desktop-provision, gnome-tour, etc.
# We check ALL layers and remove from ANY that contain matching files
# Ref: https://manpages.ubuntu.com/manpages/noble/man7/casper.7.html

if [ -f "$CASPER_DIR/minimal.standard.live.squashfs" ]; then
  echo "Layered squashfs detected. Checking ALL layers..."

  # Check and clean EACH layer (except top layer which we handle separately)
  for layer in minimal minimal.standard; do
    LAYER_FILE="$CASPER_DIR/${layer}.squashfs"
    if [ -f "$LAYER_FILE" ]; then
      echo ""
      echo "  === Checking $layer.squashfs ==="

      # Use unsquashfs -l to LIST files without extracting (FAST)
      # Search for gnome-initial-setup, gnome-tour, desktop-provision, ubuntu-desktop-bootstrap
      FOUND_FILES=$(unsquashfs -l "$LAYER_FILE" 2>/dev/null | grep -E "gnome-initial-setup|desktop-provision|gnome-tour|org.gnome.Tour|ubuntu-desktop-bootstrap|desktop-bootstrap" | grep -v "ibus-mozc" | grep -v "icons" || true)

      if [ -n "$FOUND_FILES" ]; then
        echo "  >>> FOUND gnome-initial-setup in $layer.squashfs:"
        echo "$FOUND_FILES" | head -10

        echo ""
        echo "  === Removing from ${layer}.squashfs ==="
        TEMP_LAYER="/tmp/layer_${layer}"
        rm -rf "$TEMP_LAYER"
        unsquashfs -d "$TEMP_LAYER" "$LAYER_FILE"

        # Remove gnome-initial-setup, gnome-tour, desktop-provision, ubuntu-desktop-bootstrap files
        echo "  Removing files..."
        find "$TEMP_LAYER" -type f -name "*gnome-initial-setup*" ! -name "*ibus-mozc*" -exec rm -rfv {} \; 2>/dev/null || true
        find "$TEMP_LAYER" -type f -name "*desktop-provision*" -exec rm -rfv {} \; 2>/dev/null || true
        find "$TEMP_LAYER" -type f -name "*gnome-tour*" -exec rm -rfv {} \; 2>/dev/null || true
        find "$TEMP_LAYER" -type f -name "*org.gnome.Tour*" -exec rm -rfv {} \; 2>/dev/null || true
        find "$TEMP_LAYER" -type f -name "*ubuntu-desktop-bootstrap*" -exec rm -rfv {} \; 2>/dev/null || true
        find "$TEMP_LAYER" -type f -name "*desktop-bootstrap*" -exec rm -rfv {} \; 2>/dev/null || true
        find "$TEMP_LAYER" -type d -name "*gnome-initial-setup*" -exec rm -rfv {} \; 2>/dev/null || true
        find "$TEMP_LAYER" -type d -name "*desktop-provision*" -exec rm -rfv {} \; 2>/dev/null || true
        find "$TEMP_LAYER" -type d -name "*gnome-tour*" -exec rm -rfv {} \; 2>/dev/null || true
        find "$TEMP_LAYER" -type d -name "*ubuntu-desktop-bootstrap*" -exec rm -rfv {} \; 2>/dev/null || true

        echo "  CONFIRMED: gnome-initial-setup removed from ${layer}.squashfs"

        # Repack this layer
        rm -f "$LAYER_FILE"
        mksquashfs "$TEMP_LAYER" "$LAYER_FILE" -comp xz -b 1M
        echo "  Repacked: ${layer}.squashfs"
        rm -rf "$TEMP_LAYER"
      else
        echo "  (no gnome-initial-setup found)"
      fi
    fi
  done

  # Now work on the TOP layer for our customizations
  TOP_LAYER="minimal.standard.live"
  echo ""
  echo "=== Extracting top layer for customizations: ${TOP_LAYER}.squashfs ==="

else
  # Single squashfs mode
  TOP_LAYER="filesystem"
  echo "Single squashfs mode detected."
  echo ""
  echo "=== Extracting ${TOP_LAYER}.squashfs ==="
fi

rm -rf "$SQUASH_DIR"
LAYER_FILE="$CASPER_DIR/${TOP_LAYER}.squashfs"
unsquashfs -d "$SQUASH_DIR" "$LAYER_FILE"
rm -f "$LAYER_FILE"

if [ ! -d "$SQUASH_DIR" ]; then
  echo "ERROR: Squashfs extraction failed!"
  exit 1
fi
echo "Extracted to: $SQUASH_DIR"

# Always remove welcome/setup programs from top layer (in case they exist here too)
echo "=== Removing welcome/setup programs from top layer ==="
find "$SQUASH_DIR" -type f \( \
  -name "*initial-setup*" -o \
  -name "*gnome-tour*" -o \
  -name "*org.gnome.Tour*" -o \
  -name "*ubuntu-welcome*" -o \
  -name "*desktop-provision*" -o \
  -name "*desktop-bootstrap*" -o \
  -name "*first-run*" \
\) ! -name "*ibus-mozc*" -exec rm -rfv {} \; 2>/dev/null || true

find "$SQUASH_DIR" -type d \( \
  -name "*initial-setup*" -o \
  -name "*gnome-tour*" -o \
  -name "*ubuntu-welcome*" -o \
  -name "*desktop-provision*" -o \
  -name "*desktop-bootstrap*" \
\) -exec rm -rfv {} \; 2>/dev/null || true

# Also hide the ubuntu-desktop-bootstrap snap autostart
cat > "$SQUASH_DIR/etc/xdg/autostart/ubuntu-desktop-bootstrap.desktop" << 'EOF' 2>/dev/null || true
[Desktop Entry]
Type=Application
Name=Disabled
Hidden=true
X-GNOME-Autostart-enabled=false
NoDisplay=true
EOF

echo "welcome/setup removal from top layer complete"

echo "=== Injecting setup files ==="
cp /work/pre-setup/setup "$SQUASH_DIR/usr/bin/setup"
chmod 755 "$SQUASH_DIR/usr/bin/setup"
chown root:root "$SQUASH_DIR/usr/bin/setup"

mkdir -p "$SQUASH_DIR/etc/xdg/autostart"
cp /work/pre-setup/setup.desktop "$SQUASH_DIR/etc/xdg/autostart/setup.desktop"
chmod 644 "$SQUASH_DIR/etc/xdg/autostart/setup.desktop"

echo "=== Configuring NetworkManager to ignore carrier state ==="
# Intel e1000e NICs often don't report carrier until connection is activated
# This allows NetworkManager to activate connections even without carrier
# Ref: https://networkmanager.pages.freedesktop.org/NetworkManager/NetworkManager/NetworkManager.conf.html
mkdir -p "$SQUASH_DIR/etc/NetworkManager/conf.d"
cat > "$SQUASH_DIR/etc/NetworkManager/conf.d/10-ignore-carrier.conf" << 'EOF'
[main]
# Allow activating ethernet connections even when no carrier is detected
# This fixes Intel e1000e NICs that don't detect link until NM activates
ignore-carrier=*
EOF

echo "=== Disabling gnome-initial-setup (belt and suspenders) ==="
# Even though we removed the binary, add config overrides in case package gets reinstalled

# 1. GDM config - disable initial setup AND enable auto-login
mkdir -p "$SQUASH_DIR/etc/gdm3"
cat > "$SQUASH_DIR/etc/gdm3/custom.conf" << 'EOF'
[daemon]
InitialSetupEnable=false
AutomaticLoginEnable=true
AutomaticLogin=ubuntu
EOF

# 2. Mask systemd user service
mkdir -p "$SQUASH_DIR/etc/systemd/user"
ln -sf /dev/null "$SQUASH_DIR/etc/systemd/user/gnome-initial-setup-first-login.service"

# 3. Override autostart desktop file
cat > "$SQUASH_DIR/etc/xdg/autostart/gnome-initial-setup-first-login.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=Disabled
Hidden=true
X-GNOME-Autostart-enabled=false
NoDisplay=true
EOF

# 4. Disable gnome-tour (the "Welcome to Ubuntu" tour app)
cat > "$SQUASH_DIR/etc/xdg/autostart/org.gnome.Tour.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=Disabled
Hidden=true
X-GNOME-Autostart-enabled=false
NoDisplay=true
EOF

# Also mask gnome-tour via systemd if it exists
ln -sf /dev/null "$SQUASH_DIR/etc/systemd/user/org.gnome.Tour.service" 2>/dev/null || true

# 4. Create done file for ubuntu user
mkdir -p "$SQUASH_DIR/home/ubuntu/.config"
echo "yes" > "$SQUASH_DIR/home/ubuntu/.config/gnome-initial-setup-done"
chown -R 1000:1000 "$SQUASH_DIR/home/ubuntu"

# 5. Create done file in /etc/skel
mkdir -p "$SQUASH_DIR/etc/skel/.config"
echo "yes" > "$SQUASH_DIR/etc/skel/.config/gnome-initial-setup-done"

echo "=== Configuring VLC ==="
mkdir -p "$SQUASH_DIR/home/ubuntu/.config/vlc"
cat > "$SQUASH_DIR/home/ubuntu/.config/vlc/vlcrc" << 'EOF'
[qt]
qt-privacy-ask=0
metadata-network-access=0
EOF
chown -R 1000:1000 "$SQUASH_DIR/home/ubuntu/.config/vlc"

echo "=== Configuring GNOME settings via dconf ==="
mkdir -p "$SQUASH_DIR/home/ubuntu/.config/dconf"
mkdir -p /tmp/dconf-keyfiles.d
cat > /tmp/dconf-keyfiles.d/00-settings << 'EOF'
# Note: favorite-apps set at runtime in setup-e6540 after Chrome/VLC install

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
dconf compile "$SQUASH_DIR/home/ubuntu/.config/dconf/user" /tmp/dconf-keyfiles.d
chown -R 1000:1000 "$SQUASH_DIR/home/ubuntu/.config/dconf"
rm -rf /tmp/dconf-keyfiles.d

echo "=== Copying wallpapers ==="
mkdir -p "$SQUASH_DIR/usr/share/backgrounds/custom"
cp /work/wallpaper/wp-*.jpg "$SQUASH_DIR/usr/share/backgrounds/custom/"
chmod 644 "$SQUASH_DIR/usr/share/backgrounds/custom/"*.jpg

echo "=== Adding Chrome policy ==="
mkdir -p "$SQUASH_DIR/etc/opt/chrome/policies/managed"
cat > "$SQUASH_DIR/etc/opt/chrome/policies/managed/custom_policy.json" << 'EOF'
{
  "PrivacySandboxPromptEnabled": false,
  "PrivacySandboxAdMeasurementEnabled": false,
  "PrivacySandboxAdTopicsEnabled": false,
  "PrivacySandboxSiteEnabledAdsEnabled": false
}
EOF

echo "=== Configuring GRUB ==="
sed -i 's/set timeout=30/set timeout=5/' "$EXTRACT_DIR/boot/grub/grub.cfg"
sed -i 's/quiet splash/quiet/' "$EXTRACT_DIR/boot/grub/grub.cfg"

echo "=== Validating configuration ==="
if [ ! -L "$SQUASH_DIR/etc/systemd/user/gnome-initial-setup-first-login.service" ]; then
  echo "ERROR: systemd service not masked!"
  exit 1
fi
if [ ! -f "$SQUASH_DIR/home/ubuntu/.config/gnome-initial-setup-done" ]; then
  echo "ERROR: done file not created!"
  exit 1
fi
if [ ! -f "$SQUASH_DIR/etc/xdg/autostart/setup.desktop" ]; then
  echo "ERROR: setup.desktop not found!"
  exit 1
fi
if [ ! -f "$SQUASH_DIR/usr/share/backgrounds/custom/wp-01.jpg" ]; then
  echo "ERROR: wallpapers not copied!"
  exit 1
fi
echo "VALIDATED: All configurations applied"

echo "=== Repacking top layer: ${TOP_LAYER}.squashfs ==="
mksquashfs "$SQUASH_DIR" "$CASPER_DIR/${TOP_LAYER}.squashfs" -comp xz -b 1M
echo "Created: $CASPER_DIR/${TOP_LAYER}.squashfs"

echo "=== Regenerating md5sum.txt ==="
(cd "$EXTRACT_DIR" && find . -type f -print0 | xargs -0 md5sum | grep -v isolinux/boot.cat | grep -v md5sum.txt > md5sum.txt) || true

echo "=== Rebuilding ISO ==="
EFI_SIZE_SECTORS=$(( $(stat -c%s "$EFI_IMG") / 512 ))

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

echo "=== Final validation ==="
# Verify all required squashfs files are in the ISO
if [ -f "$CASPER_DIR/minimal.squashfs" ]; then
  # Layered mode - check all 3 layers exist
  for layer in minimal.squashfs minimal.standard.squashfs minimal.standard.live.squashfs; do
    if ! xorriso -indev "$ISO_OUT" -find /casper -name "$layer" 2>/dev/null | grep -q "$layer"; then
      echo "ERROR: $layer not in final ISO!"
      exit 1
    fi
    echo "VERIFIED: $layer present"
  done
else
  # Single squashfs mode
  if ! xorriso -indev "$ISO_OUT" -find /casper -name "filesystem.squashfs" 2>/dev/null | grep -q squashfs; then
    echo "ERROR: filesystem.squashfs not in final ISO!"
    exit 1
  fi
  echo "VERIFIED: filesystem.squashfs present"
fi

echo "=== Cleaning up ==="
rm -rf "$EXTRACT_DIR" "$SQUASH_DIR" "$EFI_IMG"

ISO_SIZE=$(du -h "$ISO_OUT" | cut -f1)
echo "=== Done! Output: $ISO_OUT ($ISO_SIZE) ==="
