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

## What This Project Creates

Terraform provisions:

- an OCI VCN, subnet, internet gateway, route table, and security list
- an Ubuntu VM on `VM.Standard.E2.1.Micro`, which stays on the Always Free path
- a persistent block volume for WireGuard data
- an OCI dynamic group and policy so the instance can read its runtime secrets with an instance principal

Cloud-init bootstrapping then:

- installs the OCI CLI and Docker
- fetches runtime secrets from OCI Vault Secrets at boot
- writes persistent SSH host keys locally on the instance
- hardens SSH authentication settings
- configures DuckDNS updates
- mounts the data volume at `/opt/app/vpn/config`
- starts `wg-easy` with Docker Compose

## Security Posture

- `51820/udp` is exposed for WireGuard traffic.
- `22/tcp` is exposed for SSH by design.
- `51821/tcp` is not exposed publicly in OCI.
- The instance also drops non-VPN traffic to `51821/tcp` with a host-side `iptables` rule.
- Management should happen from inside the VPN or through SSH local port forwarding.

If you plan to expose the admin UI publicly, review that risk deliberately first.

## Prerequisites

You will need:

- an Oracle Cloud account
- access to an OCI compartment where you can create compute, network, block storage, and IAM policy resources
- Terraform installed locally
- an OCI API signing key for Terraform authentication
- a DuckDNS account and subdomain
- Docker available locally if you want to generate the `wg-easy` password hash with the same container image used by the server
- the OCI CLI installed locally and authenticated against the same tenancy/compartment

## Required Accounts And Setup

### 1. Create an Oracle Cloud Account

Create an OCI account and make sure you can access the OCI console.

You will need:

- your tenancy/compartment context
- permission to create compute, network, and block storage resources
- an API signing key for Terraform authentication

### 2. Create an OCI API Key

Terraform needs OCI credentials. A common setup is:

1. Generate an API key pair.
2. Upload the public key in the OCI console for your user.
3. Keep the private key on your local machine, for example in `~/.oci/oci_api_key.pem`.
4. Record the following values for your bootstrap config:
   - `tenancy_ocid`
   - `compartment_id`
   - `user_ocid`
   - `fingerprint`
   - `private_key_path`

This project assumes you already know which compartment you want to use.

### 3. Install Terraform

Install Terraform on your local machine and verify it works:

```bash
terraform version
```

### 4. Create an SSH Key Pair

Terraform reads your local public key from `ssh_authorized_keys_path` for instance access.

If you do not already have one:

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa
```

Note: if you prefer another SSH key path, set `ssh_authorized_keys_path` in `bootstrap.tfvars`.

### 5. Create a DuckDNS Subdomain

This project uses DuckDNS so the VPN endpoint has a stable hostname even if the public IP changes.

You need:

- a DuckDNS domain name
- a DuckDNS token

These are passed into Terraform as:

- `duck_domain`
- `duck_token`

### 6. Generate A Base64-Encoded `wg-easy` Admin Password Hash

Do not store a plaintext admin password in the compose file.

Generate the bcrypt hash locally with Docker, strip the `PASSWORD_HASH=` wrapper, escape the $ with $$ and base64-encode only the hash before putting it in `bootstrap.tfvars`:

```bash
docker run --rm ghcr.io/wg-easy/wg-easy:14 wgpw 'your-strong-password' | sed -E "s/^PASSWORD_HASH='(.*)'$/\1/" | sed 's/\$/$$/g' | base64 -w0
```

Put the resulting value into:

- `wg_admin_password_hash_base64`


## One-Time Bootstrap Script

For a fresh clone, the easiest path is:

1. Copy the bootstrap template:

```bash
cp bootstrap.tfvars.example bootstrap.tfvars
```

2. Fill in your OCI account values, DuckDNS token, and base64-encoded `wg-easy` password hash in `bootstrap.tfvars`.

3. Run the setup script once:

```bash
./scripts/prepare_oci_prereqs.sh
```

The script will:

- generate `keys/host_key` and `keys/host_key.pub` if they do not already exist
- create or reuse an OCI Vault
- create or reuse an OCI KMS key
- process the four OCI secrets one at a time and report `created`, `reused`, or `rotated`
- refuse to overwrite a secret whose content drifted unless you explicitly rotate just that secret
- write a hardened `terraform.tfvars` containing the resulting secret OCIDs
- write a local manifest at `scripts/.state/oci_prereqs_manifest.env` with non-secret OCI metadata for future cleanup

You can also pass custom input/output paths:

```bash
./scripts/prepare_oci_prereqs.sh ./bootstrap.tfvars ./terraform.tfvars
```

Preview changes without mutating OCI:

```bash
./scripts/prepare_oci_prereqs.sh --dry-run
```

Rotate just one secret when your local value changed:

```bash
./scripts/prepare_oci_prereqs.sh --replace-secret wg-admin-password-hash-base64
```

## Runtime Secrets

The setup script creates the following OCI Vault Secrets for you:

- `duckdns_token_secret_ocid`
- `wg_admin_password_hash_base64_secret_ocid`
- `ssh_host_private_key_secret_ocid`
- `ssh_host_public_key_secret_ocid`

Secret behavior is intentionally conservative:

- if a named secret does not exist, the script creates it
- if a named secret exists and matches your local value, the script reuses it
- if a named secret exists and differs, the script stops and tells you which `--replace-secret` flag to use

Recommended quick-change path:

- rotate a single secret with `--replace-secret ...` instead of deleting the whole vault stack
- use the cleanup script only when you truly want to reset OCI prereqs

## Local Files You Need

Before deployment, make sure you have:

- `terraform.tfvars`
- your OCI API private key at the path referenced by `private_key_path`
- the SSH public key referenced by `ssh_authorized_keys_path`

## Example `terraform.tfvars`

After running the bootstrap script, your generated `terraform.tfvars` should look like this:

```hcl
region                    = "us-ashburn-1"
tenancy_ocid              = "ocid1.tenancy..."
compartment_id            = "ocid1.compartment..."
user_ocid                 = "ocid1.user..."
fingerprint               = "aa:bb:cc:dd:..."
private_key_path          = "~/.oci/oci_api_key.pem"
ssh_authorized_keys_path  = "~/.ssh/id_ed25519.pub"
duck_domain               = "example.duckdns.org"
duckdns_token_secret_ocid = "ocid1.vaultsecret.oc1..example"
wg_admin_password_hash_base64_secret_ocid = "ocid1.vaultsecret.oc1..example"
ssh_host_private_key_secret_ocid   = "ocid1.vaultsecret.oc1..example"
ssh_host_public_key_secret_ocid    = "ocid1.vaultsecret.oc1..example"
```

Important:

- `terraform.tfvars` should stay local and untracked
- `scripts/.state/oci_prereqs_manifest.env` should stay local and untracked
- Terraform state is still sensitive and should be stored and shared accordingly
- do not commit real OCIDs, tokens, key material, or password hashes
- `terraform.tfvars` is intentionally expected to be in `.gitignore`
- `bootstrap.tfvars` is also intentionally local and should not be committed

## Deployment

Initialize Terraform:

```bash
terraform init
```

Review the plan:

```bash
terraform plan
```

Apply the infrastructure:

```bash
terraform apply
```

Terraform should output the instance public IP and OCI instance ID when complete.

## Managing The VPN

Normal operation:

- connect to the WireGuard VPN on `51820/udp`
- manage the service from inside the VPN when possible

Break-glass web UI access with SSH local forwarding:

```bash
ssh -L 51821:127.0.0.1:51821 ubuntu@YOUR_SERVER_IP
```

Then open:

```text
http://localhost:51821
```

## State And Secret Handling

- The instance retrieves secrets from OCI at boot using an instance principal.
- Terraform state still contains infrastructure metadata and secret OCIDs, so treat it as sensitive operational data.
- The prereq script tags OCI vault resources it creates and records their OCIDs in `scripts/.state/oci_prereqs_manifest.env`.

## Cleanup

Use the cleanup helper to remove the OCI prereqs created by the bootstrap script:

```bash
./scripts/delete_oci_prereqs.sh
```

By default it runs in dry-run mode and shows what it would delete.

Execute the cleanup:

```bash
./scripts/delete_oci_prereqs.sh --execute
```

Cleanup behavior:

- schedules each known runtime secret for deletion individually first
- then attempts to schedule vault deletion for 7 days out
- refuses vault deletion if the vault is not tagged as project-managed
- refuses vault deletion if unexpected or unmanaged active secrets are still present
- leaves the key in place when vault deletion is blocked

Important OCI note:

- vault and secret deletion is scheduled, not immediate
- the script uses the minimum supported OCI retention window of 7 days

## Notes

- The current `wg-easy` image is pinned to `ghcr.io/wg-easy/wg-easy:14`.
- The block volume is mounted at `/opt/app/vpn/config`.
- DuckDNS is updated on boot and every 5 minutes after boot.

## Security Recommendations

- keep `terraform.tfvars`, host keys, and OCI private keys out of version control
- use a long, unique password for `wg-easy`
- restrict access to your OCI account with MFA
- review Terraform changes before every apply
- rotate credentials if you suspect exposure

## Contributing

This project is for people who want a low-cost, self-hosted VPN with a security-first mindset.

If you have:

- hardening ideas
- Terraform improvements
- OCI free-tier compatibility fixes
- documentation improvements
- safer operational patterns

PRs and suggestions are welcome.
