#!/bin/sh
# provision-ssh.sh - run INSIDE a Linux guest, as root, to enable key-only SSH.
#   sh /mnt/ptero/ptero-ssh/provision-ssh.sh [username]
# Needs: network access in the guest, and authorized_keys next to this script
# (written by the host runtime when SSH_PUBLIC_KEY is set). Set PTERO_SSH_SUDO=1
# to give the user passwordless sudo. Supports apt, dnf, apk, pacman, zypper.
set -eu

DIR=$(cd "$(dirname "$0")" && pwd)
USER_NAME=${1:-$(cat "$DIR/user" 2>/dev/null || echo ptero)}
KEYFILE="$DIR/authorized_keys"

[ "$(id -u)" = 0 ] || { echo "Run as root." >&2; exit 1; }
[ -s "$KEYFILE" ] || { echo "No $KEYFILE - set SSH_PUBLIC_KEY in the Pterodactyl startup tab and restart the VM." >&2; exit 1; }
case "$USER_NAME" in ''|[0-9-]*|*[!a-z0-9_-]*) echo "Invalid user name: $USER_NAME" >&2; exit 1 ;; esac

echo "==> Installing OpenSSH server"
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y openssh-server sudo
elif command -v dnf >/dev/null 2>&1; then dnf install -y openssh-server sudo
elif command -v apk >/dev/null 2>&1; then apk add --no-cache openssh sudo shadow
elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm openssh sudo
elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive install openssh sudo
else echo "Unsupported distribution: install and enable OpenSSH manually." >&2; exit 1; fi

echo "==> Preparing user $USER_NAME"
if ! id "$USER_NAME" >/dev/null 2>&1; then
  if command -v useradd >/dev/null 2>&1; then useradd -m -s /bin/sh "$USER_NAME"; else adduser -D -s /bin/sh "$USER_NAME"; fi
  # unlock the account for key login without enabling any known password
  RAND=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
  echo "$USER_NAME:$RAND" | chpasswd
fi
HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)
install -d -m 700 -o "$USER_NAME" "$HOME_DIR/.ssh"
touch "$HOME_DIR/.ssh/authorized_keys"
while IFS= read -r line; do
  [ -n "$line" ] && { grep -qxF "$line" "$HOME_DIR/.ssh/authorized_keys" || echo "$line" >> "$HOME_DIR/.ssh/authorized_keys"; }
done < "$KEYFILE"
chown "$USER_NAME" "$HOME_DIR/.ssh/authorized_keys"; chmod 600 "$HOME_DIR/.ssh/authorized_keys"

if [ "${PTERO_SSH_SUDO:-0}" = 1 ]; then
  echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-ptero-$USER_NAME"; chmod 440 "/etc/sudoers.d/90-ptero-$USER_NAME"
fi

echo "==> Configuring sshd (port 22, keys only)"
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/50-ptero.conf <<CONF
Port 22
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
CONF
# sshd uses the FIRST value it sees, so the Include must come first.
if ! grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d' /etc/ssh/sshd_config; then
  cp /etc/ssh/sshd_config /etc/ssh/sshd_config.ptero-bak
  { echo "Include /etc/ssh/sshd_config.d/*.conf"; cat /etc/ssh/sshd_config.ptero-bak; } > /etc/ssh/sshd_config
fi
ssh-keygen -A >/dev/null 2>&1 || true
SSHD=$(command -v sshd || echo /usr/sbin/sshd)
mkdir -p /run/sshd
"$SSHD" -t || { echo "sshd configuration test failed" >&2; exit 1; }

echo "==> Enabling and starting the service"
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd
elif command -v rc-update >/dev/null 2>&1; then
  rc-update add sshd default; rc-service sshd restart
else
  echo "No known init system: start $SSHD manually and enable it at boot." >&2
fi
echo "Done. From your computer: ssh -p <server primary port> $USER_NAME@<server ip>"
