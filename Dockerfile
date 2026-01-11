FROM --platform=linux/amd64 ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    xorriso \
    squashfs-tools \
    wget \
    ca-certificates \
    isolinux \
    syslinux-utils \
    grub-pc-bin \
    grub-efi-amd64-bin \
    dconf-cli \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work

COPY docker-build.sh /docker-build.sh
RUN chmod +x /docker-build.sh

ENTRYPOINT ["/docker-build.sh"]
