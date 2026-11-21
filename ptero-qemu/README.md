# Pterodactyl QEMU VM runtime

Alpine image + standard egg that lets a Pterodactyl server run a full VM (QEMU, RAW disk, virtio-9p shared folder, optional guest SSH). No Panel/Wings changes. **Tests run against a fake QEMU; the image itself has not been booted with real QEMU/KVM by the author. Build it and try it on a test node first.**

## Files
`Dockerfile`, `scripts/{entrypoint,install,start,stop,check,disk,common}.sh`, `guest/provision-ssh.sh`, `egg-qemu-vm.json`, `tests/run-tests.sh`. Scripts live in `/opt/ptero-vm` (outside the persistent volume). Persistent state in `/home/container`: `disk.img`, `.installed`, `iso/`, `shared/`, `config/`.

## Build and import
```
docker build -t ghcr.io/your-org/ptero-qemu:latest .
docker push ghcr.io/your-org/ptero-qemu:latest
```
Edit the image name in `egg-qemu-vm.json`, then Admin > Nests > Import Egg. Create a server with: memory >= 1024 MB (recommend 2048+), CPU limit >= 100% per vCPU, disk >= DISK_SIZE + ISO size. Swap disabled is fine. The startup command is informational: the image ignores `$STARTUP` and never evals it. Stop command is `^C` (SIGINT -> ACPI shutdown).

## Lifecycle
1. `entrypoint.sh run` validates all env vars (no `eval`), then checks `/home/container/.installed`.
2. **Marker present** -> `start.sh normal`: disk only, no ISO attached.
3. **No marker** -> `install.sh`: print OS list, pick the ISO (existing `ISO_PATH` > `ISO_URL` > `OS_CHOICE`), validate (ISO9660/UDF signature, optional SHA-256), create a sparse RAW disk **only if absent**, then `start.sh install`.
4. Install boot: disk is `bootindex=1`, ISO is `bootindex=2`. An empty disk falls through to the installer; after the installer reboots, the installed disk wins. Works for BIOS and UEFI.
5. **`.installed` is never written automatically.** Confirm with any one of:
   - in the guest: `touch /mnt/ptero/.install-complete` (needs the 9p share mounted)
   - File Manager: create empty file `config/install-complete`
   - container shell: `ptero-vm confirm-install`
   - `INSTALL_MODE=installed` (declares an existing disk installed)
   A background watcher (every `INSTALL_WATCH_INTERVAL` s) and an exit check create the marker; the next start boots from disk only.
6. Restart before confirmation = installation resumes; disk and ISO are preserved.

Pterodactyl has no interactive prompts, so "ask the user" choices (OS, SSH) are egg variables.

## Environment variables
| Variable | Default | Notes |
|---|---|---|
| SERVER_MEMORY | from Wings | MB; also capped by the cgroup limit |
| RESERVED_RAM_MB | 100 | guest RAM = limit - reserved; 256+ safer |
| MIN_GUEST_RAM_MB | 256 | refuse to start below this |
| CPU_CORES | 2 | clamped to cgroup CPU limit and host CPUs |
| DISK_SIZE | 20G | M/G/T; used on creation |
| DISK_PATH / DISK_FORMAT | /home/container/disk.img / raw | must be inside /home/container; raw only |
| DISK_BUS | virtio | virtio, nvme, ide |
| DISK_CACHE | writeback | none, writeback, writethrough, directsync |
| AUTO_EXPAND_DISK | false | grow to DISK_SIZE at boot (never shrinks) |
| OS_CHOICE | empty | alpine, debian, ubuntu, arch, rocky (latest resolved at runtime; vendor checksum used when available) |
| ISO_URL | empty | any direct http(s) ISO; wins over OS_CHOICE |
| ISO_PATH / ISO_FILENAME | /home/container/iso/installer.iso / empty | existing file is used, never re-downloaded or deleted |
| ISO_SHA256 | empty | optional |
| VM_NAME | Linux VM | |
| BOOT_MODE | auto | auto picks UEFI if OVMF exists, then pins it in config/boot_mode |
| ACCELERATION / ALLOW_TCG_FALLBACK | kvm / true | kvm, tcg, auto |
| VNC_ENABLED / VNC_PORT / VNC_PASSWORD | true / 5900 / random | port >= 5900 and an allocation of the server; password max 8 chars |
| SHARED_DIR / SHARED_TAG | /home/container/shared / ptero_shared | |
| SHARED_SECURITY / SHARED_READONLY | mapped-xattr / false | falls back to `none` if xattrs unsupported |
| INSTALL_MODE | auto | auto, install, installed |
| ENABLE_SSH / SSH_USER / SSH_PUBLIC_KEY | false / ptero / empty | |
| PRIMARY_PORT | empty | ignored when Wings sets SERVER_PORT |
| NET_MODEL / NET_RESTRICT | virtio-net-pci / false | |
| QEMU_SANDBOX | false | enables QEMU seccomp sandbox; may conflict with some Docker profiles |
| SHUTDOWN_TIMEOUT | 60 | seconds for ACPI shutdown, then QMP quit, then SIGKILL |

## First install
1. Set `OS_CHOICE`, or `ISO_URL`, or upload an ISO to `iso/` and set `ISO_PATH`.
2. Allocate an extra port >= 5900 and set `VNC_PORT` to it. Start the server; the console prints the generated VNC password.
3. Connect a VNC client to `server-ip:VNC_PORT`, run the installer. Serial console (`-serial mon:stdio`) also works for ISOs that support `console=ttyS0`.
4. When the installed OS boots, mount the share and confirm (see above). Stop the server; later starts boot from disk.

## Normal startup
Marker + disk present: boots straight from `disk.img`. Missing disk with a marker is a hard error (a blank disk is never created over an installed VM). Delete `.installed` and set `INSTALL_MODE=install` only if you intend to reinstall; the disk is still not wiped.

## Shared folder (Linux guests)
```
mkdir -p /mnt/ptero
mount -t 9p -o trans=virtio,version=9p2000.L ptero_shared /mnt/ptero
# persistent: ptero_shared /mnt/ptero 9p trans=virtio,version=9p2000.L,_netdev,nofail 0 0
```
Needs the `9p`/`9pnet_virtio` kernel modules (in mainline Linux). Files uploaded through the File Manager appear immediately. With `mapped-xattr`, guest ownership/modes are stored as xattrs; files from the File Manager show host ownership, so use root in the guest if you hit permission errors. The root disk is never exposed: `DISK_PATH` and `config/` may not live inside `SHARED_DIR`.
**Windows:** no virtio-9p driver is shipped. Alternatives: Samba/SFTP (e.g. WinSCP over the SSH forward) or a network share served from another guest. virtio-win's virtiofs needs virtiofsd, which needs privileges this image does not have.

## SSH to the guest
`ENABLE_SSH=true` adds `hostfwd=tcp::<SERVER_PORT>-:22` (the primary allocation; nothing else is exposed). No sshd runs in the container. Wings maps that port TCP+UDP; only TCP is forwarded. In a **Linux guest** with network access, as root:
```
sh /mnt/ptero/ptero-ssh/provision-ssh.sh        # optionally PTERO_SSH_SUDO=1
ssh -p <primary-port> ptero@<server-ip>
```
Set `SSH_PUBLIC_KEY` first. The script installs OpenSSH (apt/dnf/apk/pacman/zypper), creates the user, installs the key, disables password auth, enables the service. Other guests: configure SSH manually and listen on 22. Guests with user-mode networking cannot be reached from other guests; the SSH port is the only inbound path.

## Disk expansion
`ptero-vm disk expand 40G` (container shell, VM stopped) or `AUTO_EXPAND_DISK=true` with a larger `DISK_SIZE`. Shrinking is refused. Back up first, then grow partition and filesystem in the guest.

## Limitations
- **KVM:** stock Wings has no device option. The container needs rw access to `/dev/kvm`: host `chmod 0666` (udev rule `KERNEL=="kvm", MODE="0666"`), a node Mount of `/dev/kvm`, and Docker's device cgroup must allow it (default Docker policy may block it; this is a host-admin change and I have not verified it on current Wings). Otherwise the VM runs under TCG (works, slow). Nested virtualization must be enabled on VPS hosts.
- Only allocated ports reach the container: SSH uses the primary one, VNC needs an extra one >= 5900.
- x86_64 guests only. User-mode (SLIRP) networking: outbound NAT, no ping, modest throughput.
- Memory accounting: container limit includes QEMU overhead and page cache; keep `RESERVED_RAM_MB` realistic.
- Predefined OS entries resolve "latest" from vendor directory listings at runtime; if a vendor changes layout use `ISO_URL`.
- QEMU modules: Alpine splits some QEMU devices into packages; if QEMU reports an unknown device, add the matching `qemu-hw-*` package to the Dockerfile.

## Troubleshooting
| Symptom | Fix |
|---|---|
| `Insufficient memory` | raise server memory or lower RESERVED_RAM_MB/MIN_GUEST_RAM_MB |
| `KVM is not accessible`, slow guest | see KVM limitation; or ACCELERATION=tcg |
| `No ISO available` | set OS_CHOICE/ISO_URL or upload ISO |
| `no ISO 9660/UDF signature` | URL returned an HTML page; use a direct link |
| download stalls/fails | partial file `*.iso.part` is kept and resumed on restart |
| `Primary port ... already in use` | something else binds that port; check the allocation |
| VNC unreachable | VNC_PORT must be an allocation of this server |
| installer loops after reboot | UEFI/BIOS mismatch: keep BOOT_MODE consistent |
| `.installed` never appears | do the confirmation step (guest `touch`, File Manager file, or `ptero-vm confirm-install`) |
| 9p mount fails | guest kernel lacks 9p; check tag name `ptero_shared` |
| OOM kills | increase RESERVED_RAM_MB (256-512) |
| server stuck "stopping" | guest ignores ACPI; wait SHUTDOWN_TIMEOUT or use Kill |

## Tests
`bash tests/run-tests.sh` (needs bash, coreutils, socat). Covers fresh install, interrupted/resumed install, guest-confirmed completion, existing marker, missing/invalid ISO, checksum mismatch, missing disk, disk preservation, QCOW2 refusal, expand/no-shrink, insufficient memory, cgroup limits, KVM available/unavailable/strict, restart, duplicate process, SSH forward, 9p args, env injection, graceful shutdown. Network downloads are not covered by the automated tests.
