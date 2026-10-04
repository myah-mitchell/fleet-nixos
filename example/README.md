# Example fleet

A complete fleet with made-up values, in the layout a real one has. It is the flake's default `fleet` input, so the flake evaluates and its checks run with no access to a real fleet.

> [!WARNING]
> Every private key of this fleet is committed under `keys/`. The keys are public test keys and protect nothing. Never use one of them, or a secret encrypted for one of them, on a real host.

## Layout

```text
nixos/fleet.json                 values every host shares
nixos/hosts/ex01.json            a Docker host with every feature on
nixos/hosts/ex02.json            a host without Docker
secrets/fleet.yaml               sops file, the secrets every host reads
secrets/host-keys/ex01.yaml      sops file, the SSH host keys of ex01
secrets/host-keys/ex02.yaml      sops file, the SSH host keys of ex02
.sops.yaml                       who can decrypt which file
keys/                            the private halves of every key, in the open
```

A real fleet also holds the Ansible inventory, the OpenTofu variables and the Komodo stack files. The flake reads none of them, so they are left out here.

## Values

| Value | Example |
| --- | --- |
| Addresses | `192.0.2.110` and `192.0.2.111`, from a range reserved for documentation |
| Domain | `h.example.com` |
| Password of the accounts | `example` |
| `komodo-onboarding-key` | A placeholder that no Komodo Core accepts |
| SSH keys of the admin, deploy and client accounts | Made for this example. Their private halves were thrown away |
| Komodo Core's public key | Made for this example. Its private half was thrown away |
| CA certificate | Made for this example. Its private key was thrown away |

The two JSON files under `nixos/hosts/` have the form that the fleet-ansible repo's `nixos-sync.yml` writes: sorted keys, two spaces of indentation, and a newline at the end.

## Read a secret

```bash
cd example
SOPS_AGE_KEY_FILE=keys/age-deploy.txt nix shell nixpkgs#sops -c sops decrypt secrets/fleet.yaml
```

See [keys/README.md](keys/README.md) for what each key file is.
