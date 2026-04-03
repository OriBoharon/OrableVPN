# Oracle Always Free WireGuard VPN

This project builds a personal VPN on Oracle Cloud Infrastructure (OCI) Always Free resources instead of paying for a commercial VPN such as NordVPN or ExpressVPN.

The goal is simple:

- run your own WireGuard VPN server on an OCI free-tier VPS
- keep recurring cost at or near zero
- prioritize security over convenience
- keep the infrastructure easy to understand and audit

This repository is intentionally conservative. The WireGuard admin UI is not exposed publicly, and remote management is expected to happen from inside the VPN or through SSH port forwarding when needed.

Security-focused improvements, hardening ideas, and pull requests are welcome.

## What This Project Creates

Terraform provisions:

- an OCI VCN
- a subnet
- an internet gateway
- a route table
- a security list
- an Ubuntu VM on an Always Free-compatible shape
- a persistent block volume for WireGuard data

Cloud-init bootstrapping then:

- installs Docker
- sets persistent SSH host keys
- configures DuckDNS updates
- formats and mounts the data volume
- starts `wg-easy` with Docker Compose

## Architecture

- Terraform file: [main.tf]
- Bootstrapping script: [setup.tftpl]
- Container stack: [docker-compose.yaml]
- Local variables and secrets: `terraform.tfvars`

## Security Posture

- `51820/udp` is exposed for WireGuard traffic.
- `22/tcp` is exposed for SSH.
- The `wg-easy` web UI port `51821/tcp` is intentionally not exposed to the public internet.
- The intended management path is:
  - connect from inside the VPN, or
  - use SSH local port forwarding as a break-glass option

If you plan to change that behavior, do it deliberately and review the risk first.

## Prerequisites

You will need:

- an Oracle Cloud account
- access to an OCI compartment where you can create networking, compute, and block volume resources
- Terraform installed locally
- the OCI CLI or another way to create and manage API keys
- an SSH key pair for logging into the VM
- a DuckDNS account and subdomain
- Docker available locally if you want to generate the `wg-easy` password hash the same way shown below

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
4. Record the following values for `terraform.tfvars`:
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

Terraform reads your local public key from `~/.ssh/id_rsa.pub` for instance access.

If you do not already have one:

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa
```

Note: if you prefer another SSH key path, update [main.tf] accordingly.

### 5. Create Persistent SSH Host Keys For The Server

This project injects static SSH host keys into the instance so the host identity stays stable across rebuilds.

Create the `keys` directory and generate the expected files:

```bash
mkdir -p keys
ssh-keygen -t ed25519 -f keys/host_key -N ""
```

That should create:

- `keys/host_key`
- `keys/host_key.pub`

These files are consumed by [main.tf] and [setup.tftpl].

### 6. Create a DuckDNS Subdomain

This project uses DuckDNS so the VPN endpoint has a stable hostname even if the public IP changes.

You need:

- a DuckDNS domain name
- a DuckDNS token

These are passed into Terraform as:

- `duck_domain`
- `duck_token`

### 7. Generate a `wg-easy` Admin Password Hash

Do not store a plaintext admin password in the compose file.

Generate a bcrypt hash locally with Docker:

```bash
docker run --rm ghcr.io/wg-easy/wg-easy:14 wgpw 'your-strong-password'
```

Put the resulting hash into:

- `wg_admin_password_hash`

Terraform accepts the hash as-is in `terraform.tfvars`. This repo escapes `$` characters only when rendering `docker-compose.yaml`, so you should not pre-escape the bcrypt hash yourself.

## Local Files You Need

Before deployment, make sure you have:

- `terraform.tfvars`
- `keys/host_key`
- `keys/host_key.pub`
- `~/.ssh/id_rsa.pub`
- your OCI API private key at the path referenced by `private_key_path`

## Create Your Local `terraform.tfvars`

Start by copying the example file:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Then edit `terraform.tfvars` and replace every placeholder with your real values.

Important:

- `terraform.tfvars` should stay local and untracked
- `terraform.tfvars` is intentionally expected to be in `.gitignore`
- do not commit real OCIDs, tokens, key paths, or password hashes
- `terraform.tfvars.example` is only a template

## Example `terraform.tfvars`

Do not commit real secrets. Use your own values:

```hcl
region                  = "us-ashburn-1"
compartment_id          = "ocid1.compartment..."
tenancy_ocid            = "ocid1.tenancy..."
user_ocid                 = "ocid1.user..."
fingerprint             = "aa:bb:cc:dd:..."
private_key_path        = "~/.oci/oci_api_key.pem"
duck_domain             = "example.duckdns.org"
duck_token              = "duckdns-token"
wg_admin_password_hash  = "$2a$12$..."
```

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
- manage the service from inside the VPN

Break-glass web UI access with SSH local forwarding:

```bash
ssh -L 51821:localhost:51821 ubuntu@YOUR_SERVER_IP
```

Then open:

```text
http://localhost:51821
```

This keeps the management UI off the public internet.

## Notes And Assumptions

- The OCI region is user-defined through `terraform.tfvars`.
- The current instance shape is `VM.Standard.E2.1.Micro`.
- The Docker volume data for WireGuard is mounted under `/opt/app/vpn/config`.
- DuckDNS is updated on boot and every 5 minutes afterward.

## Security Recommendations

- keep `terraform.tfvars`, host keys, and OCI private keys out of version control
- use a long, unique password for `wg-easy`
- restrict access to your OCI account with MFA
- review Terraform changes before every apply
- rotate credentials if you suspect exposure
- prefer private management paths over opening new firewall ports

## Contributing

This project is for people who want a low-cost, self-hosted VPN with a security-first mindset.

If you have:

- hardening ideas
- Terraform improvements
- OCI free-tier compatibility fixes
- documentation improvements
- safer operational patterns

PRs and suggestions are welcome.
