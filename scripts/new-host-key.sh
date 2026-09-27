#!/usr/bin/env bash
# Makes the SSH host keys of a host that does not exist yet, and lets that
# host read the fleet's secrets.
#
# The keys are made here, not on the host, because the host's age key
# follows from its ed25519 key. With the keys known in advance, the fleet's
# secrets can be encrypted for the host before it boots for the first time.
#
# In order:
#   1. makes an ed25519 and an RSA key pair, and stores them encrypted in
#      secrets/host-keys/<host>.yaml. Keys that are already there are kept.
#   2. adds the host's age key to .sops.yaml: under keys, to the rule for
#      secrets/fleet.yaml, and in a rule for secrets/hosts/<host>.yaml
#   3. encrypts secrets/fleet.yaml, and the host's own file when there is
#      one, again, for the keys that are now named
#
# Running it a second time for the same host changes nothing.
set -euo pipefail

usage() {
  cat <<'END'
Usage: new-host-key --fleet <fleet-dir> <host>

Makes the SSH host keys of <host>, stores them encrypted in the fleet
checkout, adds the host to .sops.yaml, and encrypts the fleet's secrets
again so that the host can read them.

  --fleet <fleet-dir>  Checkout of the repository that describes the fleet
  --help               Show this text

Needs the admin key or the deploy key, in SOPS_AGE_KEY or SOPS_AGE_KEY_FILE.
Commit what changed in the checkout afterwards.
END
}

fail() {
  echo "new-host-key: $1" >&2
  exit 1
}

fleet_directory=
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)
      usage
      exit 0
      ;;
    --fleet)
      [[ $# -ge 2 ]] || fail "--fleet needs a value"
      fleet_directory=$2
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
[[ -n $fleet_directory ]] || fail "--fleet <fleet-dir> is required, see --help"
[[ ${#positional[@]} -eq 1 ]] || fail "expected one host, see --help"
host=${positional[0]}
[[ $host =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || fail "'$host' is not a host name: letters, digits, - and _ only"

[[ -d $fleet_directory ]] || fail "$fleet_directory is not a folder"
cd "$fleet_directory"
rules=.sops.yaml
[[ -f $rules ]] || fail "$fleet_directory has no .sops.yaml"

fleet_secrets=secrets/fleet.yaml
host_secrets=secrets/hosts/$host.yaml
host_keys=secrets/host-keys/$host.yaml

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chmod 0700 "$work"
export work

# Prints the index of the first rule in .sops.yaml whose path_regex matches
# the path, which is the rule sops itself would use. Prints null when no
# rule matches.
rule_for() {
  # shellcheck disable=SC2016 # $regex is a variable of yq, not of the shell
  path=$1 yq '
    .creation_rules
    | to_entries
    | map(select(.value.path_regex != null))
    | map(select(.value.path_regex as $regex | strenv(path) | test($regex)))
    | .[0].key
  ' "$rules"
}

# Adds the host's key to the rule with the given index, unless it is there.
add_to_rule() {
  local index=$1
  if [[ $(index=$index yq '.creation_rules[env(index)].key_groups[0].age | type' "$rules") != "!!seq" ]]; then
    fail "rule $index in .sops.yaml has no list at key_groups[0].age"
  fi
  if [[ $(index=$index yq 'explode(.) | .creation_rules[env(index)].key_groups[0].age | any_c(. == strenv(recipient))' "$rules") == true ]]; then
    return
  fi
  index=$index yq -i '.creation_rules[env(index)].key_groups[0].age += [strenv(recipient)]' "$rules"
  if [[ $uses_anchors == true ]]; then
    index=$index yq -i '.creation_rules[env(index)].key_groups[0].age[-1] alias = strenv(host)' "$rules"
  fi
}

# Nothing is changed unless the last step can succeed: encrypting a file
# again takes a key that can decrypt it.
for secrets in "$fleet_secrets" "$host_secrets"; do
  [[ -f $secrets ]] || continue
  if ! sops --config "$rules" decrypt "$secrets" >/dev/null 2>&1; then
    fail "cannot decrypt $secrets, check SOPS_AGE_KEY or SOPS_AGE_KEY_FILE"
  fi
done

# 1. The keys.
keys_rule=$(rule_for "$host_keys")
[[ $keys_rule != null ]] || fail "no rule in .sops.yaml matches $host_keys"

if [[ -f $host_keys ]]; then
  if ! public_key=$(sops --config "$rules" decrypt --extract '["ssh_host_ed25519_key.pub"]' "$host_keys" 2>/dev/null); then
    fail "cannot decrypt the $host_keys that is already there, check SOPS_AGE_KEY or SOPS_AGE_KEY_FILE"
  fi
  echo "new-host-key: kept the keys in $host_keys"
else
  ssh-keygen -q -t ed25519 -N "" -C "root@$host" -f "$work/ssh_host_ed25519_key"
  ssh-keygen -q -t rsa -b 4096 -N "" -C "root@$host" -f "$work/ssh_host_rsa_key"
  (
    umask 077
    yq --null-input '
      .ssh_host_ed25519_key = load_str(strenv(work) + "/ssh_host_ed25519_key")
      | .["ssh_host_ed25519_key.pub"] = load_str(strenv(work) + "/ssh_host_ed25519_key.pub")
      | .ssh_host_rsa_key = load_str(strenv(work) + "/ssh_host_rsa_key")
      | .["ssh_host_rsa_key.pub"] = load_str(strenv(work) + "/ssh_host_rsa_key.pub")
    ' >"$work/keys.yaml"
  )
  if ! sops --config "$rules" encrypt --filename-override "$host_keys" "$work/keys.yaml" >"$work/keys.encrypted.yaml"; then
    fail "sops could not encrypt the keys for $host_keys"
  fi
  mkdir -p secrets/host-keys
  mv "$work/keys.encrypted.yaml" "$host_keys"
  chmod 0644 "$host_keys"
  public_key=$(<"$work/ssh_host_ed25519_key.pub")
  echo "new-host-key: made $host_keys"
fi

if ! recipient=$(ssh-to-age <<<"$public_key"); then
  fail "could not turn the ed25519 key of $host into an age key"
fi
export host recipient

# 2. The rules. Where .sops.yaml lists its keys under keys, each with a
# name, the host's key is added there under the host's name and the rules
# refer to it by that name. Otherwise the rules hold the key itself.
uses_anchors=$(yq '.keys | type == "!!seq"' "$rules")
if [[ $uses_anchors == true ]]; then
  if [[ $(yq '[.keys[] | select(anchor == strenv(host))] | length' "$rules") -gt 0 ]]; then
    yq -i '(.keys[] | select(anchor == strenv(host))) |= strenv(recipient)' "$rules"
  else
    yq -i '.keys += [strenv(recipient)] | .keys[-1] anchor = strenv(host)' "$rules"
  fi
fi

fleet_rule=$(rule_for "$fleet_secrets")
[[ $fleet_rule != null ]] || fail "no rule in .sops.yaml matches $fleet_secrets"
add_to_rule "$fleet_rule"

# The host's own rule names the people and the deploy key, as the rule for
# the host keys does, and the host. It goes right before that rule, so the
# hosts stay in the order they were added in.
host_rule=$(rule_for "$host_secrets")
if [[ $host_rule == null ]]; then
  host_rule=$keys_rule
  # shellcheck disable=SC2016 # $people is a variable of yq, not of the shell
  host_rule=$host_rule regex="^secrets/hosts/$host\\.yaml\$" yq -i '
    .creation_rules[env(host_rule)].key_groups[0].age as $people
    | .creation_rules = .creation_rules[:env(host_rule)]
      + [{"path_regex": strenv(regex), "key_groups": [{"age": $people}]}]
      + .creation_rules[env(host_rule):]
  ' "$rules"
fi
add_to_rule "$host_rule"
echo "new-host-key: $host is in .sops.yaml as $recipient"

# 3. The files the host may now read.
for secrets in "$fleet_secrets" "$host_secrets"; do
  [[ -f $secrets ]] || continue
  cp "$secrets" "$work/before"
  if ! sops --config "$rules" updatekeys --yes "$secrets" >/dev/null 2>&1; then
    fail "sops could not encrypt $secrets again for the keys in .sops.yaml"
  fi
  if cmp --silent "$secrets" "$work/before"; then
    echo "new-host-key: $secrets was already encrypted for the keys .sops.yaml names"
  else
    echo "new-host-key: encrypted $secrets again, for the keys .sops.yaml names"
  fi
done
