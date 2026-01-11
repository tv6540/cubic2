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

echo "=== Merging layered squashfs into single filesystem.squashfs ==="
# Ubuntu 24.04 uses layered squashfs - we merge ALL into single filesystem.squashfs
# Then remove layerfs-path from grub.cfg so casper uses default single-squashfs mode
# Ref: https://manpages.ubuntu.com/manpages/jammy/man7/casper.7.html
rm -rf "$SQUASH_DIR"
CASPER_DIR="$EXTRACT_DIR/casper"

# Merge layers in order: minimal (base) -> minimal.standard -> minimal.standard.live (top)
if [ -f "$CASPER_DIR/minimal.squashfs" ]; then
  echo "Extracting minimal.squashfs (base layer)..."
  unsquashfs -d "$SQUASH_DIR" "$CASPER_DIR/minimal.squashfs" || true

  if [ -f "$CASPER_DIR/minimal.standard.squashfs" ]; then
    echo "Merging minimal.standard.squashfs..."
    unsquashfs -f -d "$SQUASH_DIR" "$CASPER_DIR/minimal.standard.squashfs" || true
  fi

  if [ -f "$CASPER_DIR/minimal.standard.live.squashfs" ]; then
    echo "Merging minimal.standard.live.squashfs..."
    unsquashfs -f -d "$SQUASH_DIR" "$CASPER_DIR/minimal.standard.live.squashfs" || true
  fi

  # Remove ALL old squashfs files - we'll create single filesystem.squashfs
  echo "Removing old layered squashfs files..."
  rm -f "$CASPER_DIR"/*.squashfs
  rm -f "$CASPER_DIR"/*.squashfs.gpg
  rm -f "$CASPER_DIR"/*.manifest
  rm -f "$CASPER_DIR"/*.size

elif [ -f "$CASPER_DIR/filesystem.squashfs" ]; then
  echo "Found single filesystem.squashfs, extracting..."
  unsquashfs -d "$SQUASH_DIR" "$CASPER_DIR/filesystem.squashfs"
  rm -f "$CASPER_DIR/filesystem.squashfs"
else
  echo "ERROR: No squashfs found in $CASPER_DIR"
  exit 1
fi

echo "=== Removing layerfs-path from GRUB config ==="
# Remove layerfs-path parameter so casper uses single filesystem.squashfs
# Ref: https://manpages.ubuntu.com/manpages/jammy/man7/casper.7.html
sed -i 's/layerfs-path=[^ ]* //g' "$EXTRACT_DIR/boot/grub/grub.cfg"
sed -i 's/layerfs-path=[^ ]*//g' "$EXTRACT_DIR/boot/grub/grub.cfg"
# Also check loopback.cfg if it exists
if [ -f "$EXTRACT_DIR/boot/grub/loopback.cfg" ]; then
  sed -i 's/layerfs-path=[^ ]* //g' "$EXTRACT_DIR/boot/grub/loopback.cfg"
  sed -i 's/layerfs-path=[^ ]*//g' "$EXTRACT_DIR/boot/grub/loopback.cfg"
fi

echo "Squashfs merged to: $SQUASH_DIR"

# Validate squashfs extraction succeeded
if [ ! -d "$SQUASH_DIR/usr" ] || [ ! -d "$SQUASH_DIR/etc" ]; then
  echo "ERROR: Squashfs extraction failed - missing /usr or /etc directories!"
  exit 1
fi
echo "Validated: Squashfs extraction successful"

echo "=== Injecting setup files ==="
cp /work/pre-setup/setup "$SQUASH_DIR/usr/bin/setup"
chmod 755 "$SQUASH_DIR/usr/bin/setup"
chown root:root "$SQUASH_DIR/usr/bin/setup"

mkdir -p "$SQUASH_DIR/etc/xdg/autostart"
cp /work/pre-setup/setup.desktop "$SQUASH_DIR/etc/xdg/autostart/setup.desktop"
chmod 644 "$SQUASH_DIR/etc/xdg/autostart/setup.desktop"

echo "=== Disabling gnome-initial-setup ==="
# Ref: https://ubuntuhandbook.org/index.php/2023/01/disable-welcome-dialog-ubuntu-22-04/

# 0. Disable via GDM config (belt-and-suspenders)
# Ref: https://help.gnome.org/admin/gdm/stable/configuration.html
mkdir -p "$SQUASH_DIR/etc/gdm3"
if [ -f "$SQUASH_DIR/etc/gdm3/custom.conf" ]; then
  sed -i '/^\[daemon\]/a InitialSetupEnable=false' "$SQUASH_DIR/etc/gdm3/custom.conf"
else
  cat > "$SQUASH_DIR/etc/gdm3/custom.conf" << 'EOF'
[daemon]
InitialSetupEnable=false
EOF
fi

# 1. Mask systemd user service (symlink to /dev/null)
mkdir -p "$SQUASH_DIR/etc/systemd/user"
ln -sf /dev/null "$SQUASH_DIR/etc/systemd/user/gnome-initial-setup-first-login.service"

# 2. Override autostart desktop file
cat > "$SQUASH_DIR/etc/xdg/autostart/gnome-initial-setup-first-login.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=Disabled
Hidden=true
X-GNOME-Autostart-enabled=false
NoDisplay=true
EOF

# 3. Create done file for ubuntu user
mkdir -p "$SQUASH_DIR/home/ubuntu/.config"
echo "yes" > "$SQUASH_DIR/home/ubuntu/.config/gnome-initial-setup-done"
chown -R 1000:1000 "$SQUASH_DIR/home/ubuntu/.config"

# 4. Create done file in /etc/skel for new users
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
dconf compile "$SQUASH_DIR/home/ubuntu/.config/dconf/user" /tmp/dconf-keyfiles.d
chown -R 1000:1000 "$SQUASH_DIR/home/ubuntu/.config/dconf"
rm -rf /tmp/dconf-keyfiles.d

echo "=== Removing bloatware packages ==="
if [ -x "$SQUASH_DIR/usr/bin/apt-get" ] && [ -d "$SQUASH_DIR/var/lib/dpkg" ]; then
  cp /etc/resolv.conf "$SQUASH_DIR/etc/resolv.conf" 2>/dev/null || true
  mount --bind /dev "$SQUASH_DIR/dev" 2>/dev/null || true
  mount --bind /dev/pts "$SQUASH_DIR/dev/pts" 2>/dev/null || true
  mount -t proc proc "$SQUASH_DIR/proc" 2>/dev/null || true
  mount -t sysfs sysfs "$SQUASH_DIR/sys" 2>/dev/null || true

  chroot "$SQUASH_DIR" /bin/bash -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq 2>/dev/null || exit 0
  apt-get remove -y --purge \
    gnome-initial-setup \
    firefox \
    thunderbird \
    libreoffice-* \
    rhythmbox \
    totem \
    remmina \
    shotwell \
    software-properties-gtk \
    update-manager \
    usb-creator-gtk \
    transmission-gtk \
    yelp \
    gnome-user-docs \
    ubuntu-report \
    popularity-contest \
    2>/dev/null || true
  apt-get autoremove -y 2>/dev/null || true
  apt-get clean 2>/dev/null || true
  rm -rf /var/lib/apt/lists/* 2>/dev/null || true
  systemctl --global mask gnome-initial-setup-first-login.service 2>/dev/null || true
  ' || echo "Note: Package removal had warnings (continuing)"

  umount "$SQUASH_DIR/sys" 2>/dev/null || true
  umount "$SQUASH_DIR/proc" 2>/dev/null || true
  umount "$SQUASH_DIR/dev/pts" 2>/dev/null || true
  umount "$SQUASH_DIR/dev" 2>/dev/null || true
  rm -f "$SQUASH_DIR/etc/resolv.conf" 2>/dev/null || true
fi

# Forcefully remove gnome-initial-setup files even if apt failed
echo "=== Force-removing gnome-initial-setup files ==="
rm -f "$SQUASH_DIR/usr/libexec/gnome-initial-setup" 2>/dev/null || true
rm -f "$SQUASH_DIR/usr/libexec/gnome-initial-setup-copy-worker" 2>/dev/null || true
rm -f "$SQUASH_DIR/usr/lib/systemd/user/gnome-initial-setup"*.service 2>/dev/null || true
rm -f "$SQUASH_DIR/usr/lib/systemd/user/gnome-initial-setup"*.target 2>/dev/null || true
rm -f "$SQUASH_DIR/usr/share/applications/gnome-initial-setup"*.desktop 2>/dev/null || true
rm -rf "$SQUASH_DIR/usr/share/gnome-initial-setup" 2>/dev/null || true
# Remove any autostart entries that might exist in other locations
find "$SQUASH_DIR/etc/xdg" -name "*gnome-initial-setup*" ! -name "gnome-initial-setup-first-login.desktop" -delete 2>/dev/null || true
find "$SQUASH_DIR/usr/share/gdm" -name "*initial-setup*" -delete 2>/dev/null || true

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
sed -i 's/quiet splash/nomodeset/' "$EXTRACT_DIR/boot/grub/grub.cfg"

echo "=== Removing unused files ==="
rm -rf "$EXTRACT_DIR/pool"
rm -rf "$EXTRACT_DIR/dists"

echo "=== Validating configuration ==="
# Check gnome-initial-setup is disabled
if [ ! -L "$SQUASH_DIR/etc/systemd/user/gnome-initial-setup-first-login.service" ]; then
  echo "ERROR: systemd service not masked!"
  exit 1
fi
if [ ! -f "$SQUASH_DIR/home/ubuntu/.config/gnome-initial-setup-done" ]; then
  echo "ERROR: done file not created!"
  exit 1
fi
# Check setup.desktop exists
if [ ! -f "$SQUASH_DIR/etc/xdg/autostart/setup.desktop" ]; then
  echo "ERROR: setup.desktop not found!"
  exit 1
fi
# Check wallpapers copied
if [ ! -f "$SQUASH_DIR/usr/share/backgrounds/custom/wp-01.jpg" ]; then
  echo "ERROR: wallpapers not copied!"
  exit 1
fi
# Check layerfs-path removed from grub
if grep -q "layerfs-path" "$EXTRACT_DIR/boot/grub/grub.cfg"; then
  echo "ERROR: layerfs-path still in grub.cfg!"
  exit 1
fi
echo "VALIDATED: All configurations applied"

echo "=== Creating filesystem.squashfs ==="
mksquashfs "$SQUASH_DIR" "$CASPER_DIR/filesystem.squashfs" -comp xz -b 1M
echo "Created: $CASPER_DIR/filesystem.squashfs"

echo "=== Updating filesystem.size ==="
printf $(du -sx --block-size=1 "$SQUASH_DIR" | cut -f1) > "$CASPER_DIR/filesystem.size"

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
# Verify ISO has filesystem.squashfs
if ! xorriso -indev "$ISO_OUT" -find /casper -name "filesystem.squashfs" 2>/dev/null | grep -q squashfs; then
  echo "ERROR: filesystem.squashfs not in final ISO!"
  exit 1
fi
echo "VERIFIED: filesystem.squashfs present in ISO"

echo "=== Cleaning up ==="
rm -rf "$EXTRACT_DIR" "$SQUASH_DIR" "$EFI_IMG"

ISO_SIZE=$(du -h "$ISO_OUT" | cut -f1)
echo "=== Done! Output: $ISO_OUT ($ISO_SIZE) ==="
