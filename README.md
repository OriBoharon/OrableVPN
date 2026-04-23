# Oracle Always Free WireGuard VPN

This project provisions a personal WireGuard VPN on Oracle Cloud Infrastructure Always Free resources.

The goal is simple:

- run your own WireGuard VPN server on an OCI free-tier VPS
- keep recurring cost at or near zero
- prioritize security over convenience
- keep the infrastructure easy to understand and audit

The repo stays intentionally conservative:

- keep the instance on an Always Free-compatible shape
- keep the `wg-easy` admin UI off the public internet
- preserve WireGuard state on a persistent block volume
- prefer auditable Terraform and bootstrap logic over convenience shortcuts
- optionally manage tenancy-wide OCI guardrails that keep quota-covered resources inside documented Always Free limits

Security note: `51821/tcp` is intentionally not exposed publicly. Management should happen from inside the VPN or through SSH local port forwarding.

## Quick Start

Before you start, make sure you have:

- an OCI account and compartment where you can create compute, network, block storage, and IAM policy resources
- Terraform installed locally
- the OCI CLI installed locally and authenticated against the same tenancy/compartment
- an OCI API signing key for Terraform authentication
- a DuckDNS domain and token
- an SSH public key for instance access
- Docker available locally if you want to generate the `wg-easy` admin password hash with the same image used on the server

Quick reference if you need a fresh SSH key for instance access:

```bash
ssh-keygen -t ed25519 -a 100 -f ~/.ssh/id_ed25519
```

Generate the base64-encoded `wg-easy` admin password hash once and place it in `bootstrap.tfvars` as `wg_admin_password_hash_base64`:

```bash
docker run --rm ghcr.io/wg-easy/wg-easy:14 wgpw 'your-strong-password' | sed -E "s/^PASSWORD_HASH='(.*)'$/\1/" | sed 's/\$/$$/g' | base64 -w0
```

1. Copy the bootstrap template:

```bash
cp bootstrap.tfvars.example bootstrap.tfvars
```

2. Fill in `bootstrap.tfvars` with your OCI values, DuckDNS settings, and `wg-easy` password hash.

3. Create or reuse the OCI prereqs and generate `terraform.tfvars`:

```bash
./scripts/prepare_oci_prereqs.sh
```

4. Review and apply the Terraform changes:

```bash
terraform init
terraform plan
terraform apply
```

That is the supported happy path:
`bootstrap.tfvars.example` -> `bootstrap.tfvars` -> `prepare_oci_prereqs.sh` -> `terraform apply`

If you leave the default guardrail toggles enabled, Terraform will also manage tenancy-wide OCI quotas and budget alerts from the tenancy root compartment. Those settings affect more than this VPN project.

## What This Creates

Terraform provisions:

- an OCI VCN, subnet, internet gateway, route table, and security list
- an Ubuntu VM on `VM.Standard.E2.1.Micro`, which stays on the Always Free path
- a persistent block volume for WireGuard data
- an OCI dynamic group and policy so the instance can read its runtime secrets with an instance principal
- tenancy-wide quotas that mirror key documented Always Free compute and storage limits
- tenancy-wide budget alerts that notify if unexpected non-free spend appears

Cloud-init bootstrapping then:

- installs the OCI CLI and Docker
- fetches runtime secrets from OCI Vault at boot
- writes persistent SSH host keys on the instance
- hardens SSH authentication settings
- mounts the data volume at `/opt/app/vpn/config`
- configures DuckDNS updates on boot and every 5 minutes
- starts `wg-easy` with Docker Compose

## Secrets And Bootstrap

`./scripts/prepare_oci_prereqs.sh` is the one-time helper that creates or reuses the OCI Vault/KMS prereqs, generates the local host keypair if needed, and writes `terraform.tfvars` with these secret OCID inputs:

- `duckdns_token_secret_ocid`
- `wg_admin_password_hash_base64_secret_ocid`
- `ssh_host_private_key_secret_ocid`
- `ssh_host_public_key_secret_ocid`

The script is intentionally conservative:

- if a named secret does not exist, it creates it
- if a named secret already matches your local value, it reuses it
- if a named secret differs, it stops and tells you which `--replace-secret` flag to use

Useful commands:

```bash
./scripts/prepare_oci_prereqs.sh --dry-run
./scripts/prepare_oci_prereqs.sh --replace-secret wg-admin-password-hash-base64
./scripts/prepare_oci_prereqs.sh ./bootstrap.tfvars ./terraform.tfvars
```

Keep `bootstrap.tfvars`, `terraform.tfvars`, your OCI API key, and Terraform state as sensitive local operational data.

## Access And Management

- `51820/udp` is exposed for WireGuard traffic
- `22/tcp` is exposed for SSH by design
- `51821/tcp` is not exposed publicly in OCI
- the host also drops non-VPN traffic to `51821/tcp` with an `iptables` rule

Normal operation:

- connect to the VPN first
- manage `wg-easy` from inside the VPN when possible

Break-glass web UI access uses SSH local forwarding:

```bash
ssh -L 51821:127.0.0.1:51821 ubuntu@YOUR_SERVER_IP
```

Then open:

```text
http://localhost:51821
```

If you plan to expose the admin UI publicly, review that risk deliberately first.

## Tenancy Guardrails

This repo can now manage two tenancy-wide OCI safety layers from Terraform:

- hard guardrails with quota policies in the tenancy root compartment
- soft tripwires with budget alerts in the tenancy root compartment

The default quota set is intentionally conservative:

- allow `VM.Standard.E2.1.Micro` up to the documented Always Free E2 micro quota
- allow `VM.Standard.A1.Flex` up to the documented Always Free A1 core and memory quota, including the regional A1 quota names OCI may enforce during launch
- allow the shared boot-plus-block storage pool and backup count documented for Always Free
- deny common paid-prone services such as load balancers, compute autoscaling/pools, and managed database families by default

Important:

- budgets do not block spend; they only alert
- quota policies are the enforcement layer for quota-covered services
- tenancy-wide quota and budget resources affect more than this VPN stack
- OCI can change Always Free limits over time, so review these values before changing them

## Cleanup

Use the cleanup helper to remove the OCI prereqs created by the bootstrap script:

```bash
./scripts/delete_oci_prereqs.sh
./scripts/delete_oci_prereqs.sh --execute
```

By default the script runs in dry-run mode. When executed, it schedules each managed secret for deletion first, then attempts to schedule vault deletion for 7 days out. Vault and secret deletion in OCI is scheduled, not immediate.

## Notes

- The current `wg-easy` image is pinned to `ghcr.io/wg-easy/wg-easy:14`.
- The prereq script records OCI metadata for cleanup in `scripts/.state/oci_prereqs_manifest.env`.
- The block volume mount at `/opt/app/vpn/config` preserves WireGuard state across instance replacement or reboot.

## Contributing

This project is for people who want a low-cost, self-hosted VPN with a security-first mindset.

If you have:

- hardening ideas
- Terraform improvements
- OCI free-tier compatibility fixes
- documentation improvements
- safer operational patterns

PRs and suggestions are welcome.
