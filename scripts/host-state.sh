#!/usr/bin/env bash
# Prints one word that says what answers at an address:
#
#   installer    the fleet's installer ISO
#   installed    a host this flake installed
#   unreachable  nothing answers, or what answers is neither of the two
#
# The exit code is 0 for all three, so a caller reads the word, not the code.
set -euo pipefail

usage() {
  cat <<'END'
Usage: host-state [--user <user>] <address>

Prints installer, installed, or unreachable for the address.

  --user <user>  The account to log in to an installed host as. Default: ansible
  --help         Show this text
END
}

fail() {
  echo "host-state: $1" >&2
  exit 1
}

user=ansible
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
    -*)
      fail "unknown option $1"
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done
[[ ${#positional[@]} -eq 1 ]] || fail "expected one address, see --help"
address=${positional[0]}
[[ $user =~ ^[a-z_][a-z0-9_-]*$ ]] || fail "'$user' is not an account name"
[[ $address =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ ]] || fail "'$address' is not an address"

# The host key is not checked. This is a probe that sends nothing secret,
# and it runs before anyone knows whether a host or the installer answers.
ssh_options=(
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o ForwardAgent=no
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
)

# One short look at the SSH port first, so an address where nothing answers
# costs one timeout and not one per login below.
# shellcheck disable=SC2016 # $0 is for the inner shell, which gets the address as it
if ! timeout 5 bash -c 'exec 3<>"/dev/tcp/$0/22"' "$address" 2>/dev/null; then
  echo unreachable
  exit 0
fi

if ssh "${ssh_options[@]}" "root@$address" test -e /etc/fleet-installer 2>/dev/null </dev/null; then
  echo installer
elif ssh "${ssh_options[@]}" "$user@$address" test -e /etc/fleet-host 2>/dev/null </dev/null; then
  echo installed
else
  echo unreachable
fi
