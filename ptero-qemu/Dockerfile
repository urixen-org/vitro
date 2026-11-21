# Pterodactyl QEMU VM runtime (x86_64 guests).
FROM alpine:3.20

LABEL org.opencontainers.image.title="ptero-qemu" \
      org.opencontainers.image.description="QEMU VM runtime for Pterodactyl (RAW disk, virtio-9p share, optional guest SSH)"

# qemu-system-x86_64 : hypervisor        qemu-img : image utilities
# socat              : QMP control       attr     : setfattr (9p mapped-xattr probe)
# coreutils          : GNU stat/truncate/realpath/sha256sum used by the scripts
# tini               : PID 1 / zombie reaping (signals are forwarded to the entrypoint only)
RUN apk add --no-cache bash coreutils curl ca-certificates socat attr tini \
        qemu-system-x86_64 qemu-img \
 && (apk add --no-cache ovmf || apk add --no-cache edk2-ovmf || echo "WARNING: no OVMF package; BOOT_MODE=uefi unavailable")

# Pterodactyl (Wings) runs containers as uid 988 with /home/container mounted.
RUN adduser -D -u 988 -h /home/container container

COPY scripts/ /opt/ptero-vm/scripts/
COPY guest/   /opt/ptero-vm/guest/
RUN chmod 0755 /opt/ptero-vm/scripts/*.sh /opt/ptero-vm/guest/*.sh \
 && ln -s /opt/ptero-vm/scripts/entrypoint.sh /usr/local/bin/ptero-vm

USER container
ENV USER=container HOME=/home/container
WORKDIR /home/container

STOPSIGNAL SIGINT
# Wings passes its STARTUP string in $STARTUP; this image intentionally never evals it.
ENTRYPOINT ["/sbin/tini", "--", "/opt/ptero-vm/scripts/entrypoint.sh"]
CMD ["run"]
