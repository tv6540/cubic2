# Cubic2 - Ubuntu E6540 Live USB Builder

Automated Ubuntu Live USB builder for Dell Latitude E6540. Creates a customized ISO that auto-configures display, audio, and installs Chrome with extensions on boot.

## Requirements

- Docker
- ~10GB disk space
- curl or wget

## Quick Start

```sh
# Build the customized ISO
./make.sh build

# Write to USB
./make.sh usb /dev/sdX
```

## Commands

| Command | Description |
|---------|-------------|
| `./make.sh build` | Download Ubuntu ISO and build customized version |
| `./make.sh download` | Download Ubuntu ISO only |
| `./make.sh usb /dev/sdX` | Write ISO to USB device |
| `./make.sh clean` | Remove work directory and Docker image |

## What It Does

On boot, the live USB will automatically:

1. Set HDMI-1 as primary display (1600x900)
2. Disable built-in laptop display
3. Disable screen timeout
4. Ignore lid switch events
5. Set HDMI audio as default
6. Set timezone to Pacific
7. Install Google Chrome with extensions:
   - Adblock Plus
   - YouTube Skip Ad Trigger
   - YouTube Ad Auto-skipper

After setup completes, sign into Chrome to sync your bookmarks, passwords, and settings.

## Environment Variables

```sh
# Use a different Ubuntu version
UBUNTU_VERSION=24.04 ./make.sh build
```

## Directory Structure

```
cubic2/
├── make.sh           # Main build script (run this)
├── Dockerfile        # Docker image for ISO modification
├── docker-build.sh   # ISO modification script (runs in Docker)
├── pre-setup/        # Files injected into ISO
│   ├── setup         # Bootstrap script (runs on boot)
│   └── setup.desktop # GNOME autostart entry
└── scripts/
    ├── detect-device       # Picks the setup script from DMI info (run after clone)
    ├── setup-e6540         # Dell Latitude E6540 (HDMI); also the fallback for unknown devices
    ├── setup-optiplex7050  # Dell OptiPlex 7050 (DP/HDMI/VGA)
    ├── setup-t450          # Lenovo ThinkPad T450/T450s, live USB
    ├── setup-t450-disk     # Lenovo ThinkPad T450/T450s, Ubuntu installed on internal drive
    └── x                   # Quick display/audio reset (installed to /usr/bin/x)
```

## Installing to disk (T450)

The live USB keeps every write in RAM, which is too tight on an 8 GB machine.
For the T450, install Ubuntu on the internal drive instead, then freeze it with
overlayroot so a reboot is still a full reset.

1. Write the **stock** Ubuntu installer to a USB stick (the customised ISO has
   the installer removed):
   ```sh
   ./make.sh usb-stock
   ```
2. Boot the T450 from it and install Ubuntu. In the installer:
   - Choose **Erase disk**, or use manual partitioning with `/` (40 GB is plenty)
     and a second ext4 partition mounted at `/data` for downloads. With `/data`,
     downloads survive reboots after the freeze; without it they are wiped.
   - Create the user and tick **Log in automatically**.
3. After the first login, open a terminal and run:
   ```sh
   sudo apt install -y git
   git clone https://github.com/tv6540/cubic2.git ~/cubic2
   ~/cubic2/scripts/setup-t450-disk
   ```
4. Open Chrome from the dock, sign in, let it sync. Check the TV picture and sound.
5. Freeze it so every reboot resets to this exact state:
   ```sh
   ~/cubic2/scripts/setup-t450-disk --freeze && sudo reboot
   ```

In the installer pick **Default selection** (not Extended): it leaves out LibreOffice,
Thunderbird and the games, and the setup script removes the Firefox snap too.

Day to day: anything goes wrong, reboot. To change something on a frozen system
(update Chrome, add a package) run `sudo overlayroot-chroot`, make the change,
`exit`, reboot. To make it writable again: `~/cubic2/scripts/setup-t450-disk --unfreeze`.
If it ever fails to boot, hold Shift at GRUB, press `e` on the Ubuntu entry, add
`overlayroot=disabled` to the `linux` line and press F10.

### Factory restore image (Rescuezilla)

Two layers of reset, for different situations:

| Situation | Tool | Time |
|-----------|------|------|
| Chrome misbehaving, something got changed, "just make it like yesterday" | overlayroot: **reboot** | seconds |
| Drive replaced, baseline needs rebuilding, disk itself damaged | Rescuezilla image: **restore** | ~10 min |

overlayroot handles everyday resets on its own. The Rescuezilla image is insurance for
the rare case where the disk contents themselves must be put back. Rescuezilla is the
GUI version of Clonezilla and uses the same image format.

Prepare a **second** USB stick (any size over 2 GB):
```sh
./make.sh usb-rescuezilla
```

Take the image once, right after `--freeze` and a successful reboot:

1. Boot the T450 from the Rescuezilla stick (it starts straight into the GUI).
2. **Backup**. Source: the internal drive. Destination: your NAS over the network
   (choose *Connect to a network share*, enter the SMB path and credentials), or a
   second data stick. Name it e.g. `t450-factory`. A fresh install compresses to a
   few GB.

Restore: boot the same stick, **Restore**, pick the `t450-factory` image from the
same location, target = internal drive, confirm. Reboot.

Images are kept off the stick on purpose: the stick is just the tool, the NAS holds
the image, and either can be replaced without losing the other.
