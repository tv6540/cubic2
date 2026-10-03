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
    ├── setup-t450          # Lenovo ThinkPad T450/T450s (mini-DP/VGA, no HDMI)
    └── x                   # Quick display/audio reset (installed to /usr/bin/x)
```

## Supported Devices

Device detection reads `/sys/class/dmi/id/{product_name,product_version,product_family}`.
Dell reports the model in `product_name`; Lenovo reports a machine-type code there
(e.g. `20BUS61X00`) and the model in `product_version`.

| Device | DMI match | Script |
|--------|-----------|--------|
| Dell Latitude E6540 | `Latitude E6540` | `setup-e6540` |
| Dell OptiPlex 7050 | `OptiPlex 7050` | `setup-optiplex7050` |
| Lenovo ThinkPad T450 / T450s | `ThinkPad T450` | `setup-t450` |
| Anything else | – | `setup-e6540` (which re-runs detection and hands off) |

To add a device: add a case to `scripts/detect-device`, add a `scripts/setup-<name>`,
and push. Existing USB sticks pick it up on next boot because the scripts are cloned
from GitHub at runtime; no ISO rebuild is needed.

## Use Case

Perfect for a "TV box" setup where:
- Laptop is connected to a TV via HDMI
- Lid stays closed
- If system becomes unstable, just reboot for a fresh start
- Sign into Chrome once to sync everything
