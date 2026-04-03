# AGENTS.md

This repository provisions and bootstraps a small Oracle Cloud VPS that runs WireGuard via `wg-easy`.

## Project Purpose

- Provision OCI networking, compute, and a persistent block volume with Terraform.
- Bootstrap the instance with cloud-init from `setup.tftpl`.
- Run `wg-easy` with Docker Compose.
- Use DuckDNS for dynamic DNS updates.

## Key Files

- `main.tf`: OCI infrastructure, instance metadata, and cloud-init template wiring.
- `setup.tftpl`: first-boot provisioning script that installs Docker, mounts the data volume, configures DuckDNS, and starts the container stack.
- `docker-compose.yaml`: `wg-easy` service definition.
- `terraform.tfvars`: local secrets and environment-specific values. Treat as sensitive.

## Important Operating Rules

- Do not open the `wg-easy` management UI port publicly.
- Port `51821/tcp` being closed in the OCI security list is intentional.
- Management should happen only from inside the VPN.
- Break-glass management should use SSH local port forwarding, not a public firewall rule.
- Preserve this security posture unless the user explicitly asks to change it.

## Implementation Notes

- The instance shape is intended to stay on the Always Free path unless the user asks otherwise.
- The boot script expects persistent SSH host keys at `keys/host_key` and `keys/host_key.pub`.
- The block volume is mounted at `/opt/app/vpn/config` so WireGuard state survives instance replacement/reboot.
- DuckDNS is updated both immediately at boot and every 5 minutes via cron.

## Editing Guardrails

- Prefer minimal, targeted changes over broad refactors.
- Keep Terraform and bootstrap logic easy to audit.
- Do not expose secrets in logs, docs, or example output.
- Be careful with `terraform.tfvars`; avoid echoing tokens, hashes, OCIDs, or key paths back to the user unless necessary.
- If changing networking, call out user-facing access changes explicitly.

## Useful Defaults For Future Codex Sessions

- Assume the user wants infrastructure changes to remain conservative and reversible.
- Assume security is preferred over convenience for remote administration.
- If a proposal would make the admin UI internet-accessible, stop and confirm first.
