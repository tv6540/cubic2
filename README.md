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
    ├── setup-e6540   # Main configuration script
    └── x             # Quick display/audio reset (installed to /usr/bin/x)
```

## Use Case

Perfect for a "TV box" setup where:
- Laptop is connected to a TV via HDMI
- Lid stays closed
- If system becomes unstable, just reboot for a fresh start
- Sign into Chrome once to sync everything
