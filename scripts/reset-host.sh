#!/usr/bin/env bash
# Sends an installed host back to the installer: overwrites the start of its
# OS disk, which holds the boot loader and the partition table, and reboots.
# The BIOS then finds nothing to boot on the disk and starts the installer
# ISO. The persistent disk is not touched.
#
# The host has to agree on who it is. The name given with --yes-wipe is
# compared with the name in the host's /etc/fleet-host, and nothing happens
# unless they are the same.
set -euo pipefail

usage() {
  cat <<'END'
Usage: reset-host [--user <user>] --yes-wipe <host> <address>

Wipes the start of the OS disk of the host at the address and reboots it,
so that it boots the installer again. Everything on the OS disk is lost.

  --yes-wipe <host>  The name of the host to wipe. It must be the name the
                     host at the address gives itself in /etc/fleet-host.
  --user <user>      The account to log in as. Default: ansible
  --help             Show this text
END
}

fail() {
  echo "reset-host: $1" >&2
  exit 1
}

user=ansible
host=
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)
      usage
      exit 0
      ;;
    --user)
      [[ $# -ge 2 ]] || fail "--user needs a value"
      user=$2
      shift 2
      ;;
    --yes-wipe)
      [[ $# -ge 2 ]] || fail "--yes-wipe needs the name of the host"
      host=$2
      shift 2
      ;;
    -*)
      fail "unknown option $1"
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done
[[ -n $host ]] || fail "--yes-wipe <host> is required, see --help"
[[ ${#positional[@]} -eq 1 ]] || fail "expected one address, see --help"
address=${positional[0]}
[[ $host =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || fail "'$host' is not a host name: letters, digits, - and _ only"
[[ $address =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ ]] || fail "'$address' is not an address"
[[ $user =~ ^[a-z_][a-z0-9_-]*$ ]] || fail "'$user' is not an account name"

ssh_options=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o ControlMaster=no
  -o ControlPath=none
  -o ForwardAgent=no
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
)

if ! name_on_host=$(ssh "${ssh_options[@]}" "$user@$address" cat /etc/fleet-host </dev/null 2>/dev/null); then
  fail "cannot read /etc/fleet-host as $user at $address, so this is not an installed host that can be reached"
fi
if [[ $name_on_host != "$host" ]]; then
  fail "the host at $address calls itself '$name_on_host', not '$host', so nothing was wiped"
fi

os_disk=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0

# The containers stop first, so that their data on the persistent disk is
# written out and closed while the host still works as usual. Stopping
# dockerd alone would leave them running, since live-restore is on.
#
# The host cannot shut down in the usual way once the start of its disk is
# gone, since any program it has not run lately can no longer be read. So
# the reboot is the kernel's own, asked for through sysrq, which needs no
# program. Before it, sysrq writes out what is still in memory (s) and
# makes every filesystem read-only (u). sleep runs once before the wipe, so
# that it is in memory when it is needed after it. The reboot waits two
# seconds in the background, which lets this login end first.
wipe="sleep 0
if systemctl cat docker.service >/dev/null 2>&1; then
  ids=\$(docker ps -q) || exit 1
  if [ -n \"\$ids\" ]; then
    docker stop \$ids >/dev/null || exit 1
  fi
  systemctl stop docker.socket docker.service || exit 1
fi
sync
dd if=/dev/zero of=$os_disk bs=1M count=16 conv=fsync status=none || exit 1
(sleep 2; echo s > /proc/sysrq-trigger; sleep 1; echo u > /proc/sysrq-trigger; sleep 1; echo b > /proc/sysrq-trigger) </dev/null >/dev/null 2>&1 &"

# shellcheck disable=SC2029 # the commands are meant to be filled in here
if ! ssh "${ssh_options[@]}" "$user@$address" "sudo sh -c '$wipe'" </dev/null; then
  fail "could not wipe the OS disk of $host at $address"
fi

echo "reset-host: wiped the start of the OS disk of $host, which now reboots into the installer"
