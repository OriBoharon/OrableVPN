# PROVIDER CONFIG
provider "oci" {
  region           = var.region
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
}

# VARIABLES (Pass these in via a .tfvars file or env vars)
variable "compartment_id" {
  type = string
}

variable "region" {
  type = string
}

variable "tenancy_ocid" {
  type = string
}

variable "user_ocid" {
  type = string
}

variable "fingerprint" {
  type = string
}

variable "private_key_path" {
  type = string
}

variable "ssh_authorized_keys_path" {
  type        = string
  description = "Path to the SSH public key that should be authorized for the instance."
  default     = "~/.ssh/id_ed25519.pub"
}

variable "duck_domain" {
  type = string
}

variable "duckdns_token_secret_ocid" {
  type        = string
  sensitive   = true
  description = "OCI Secret OCID containing the DuckDNS token."
}

variable "wg_admin_password_hash_base64_secret_ocid" {
  type        = string
  sensitive   = true
  description = "OCI Secret OCID containing the base64-encoded wg-easy admin password hash."
}

variable "ssh_host_private_key_secret_ocid" {
  type        = string
  sensitive   = true
  description = "OCI Secret OCID containing the persistent SSH host private key."
}

variable "ssh_host_public_key_secret_ocid" {
  type        = string
  sensitive   = true
  description = "OCI Secret OCID containing the persistent SSH host public key."
}

variable "enable_tenancy_always_free_guardrails" {
  type        = bool
  description = "Whether to manage tenancy-wide OCI quotas that keep quota-covered resources inside documented Always Free limits."
  default     = true
}

variable "enable_tenancy_budget_alerts" {
  type        = bool
  description = "Whether to manage tenancy-wide budget alerts that notify on unexpected non-free OCI spend."
  default     = true
}

variable "budget_alert_recipients" {
  type        = string
  description = "Delimited list of email addresses that should receive tenancy-wide OCI budget alerts."
  default     = ""
}

variable "always_free_a1_ocpus" {
  type        = number
  description = "OCI Always Free A1 OCPU allowance to mirror in tenancy quotas. Review this value if Oracle changes the offering."
  default     = 4
}

variable "always_free_a1_memory_gb" {
  type        = number
  description = "OCI Always Free A1 memory allowance in GB to mirror in tenancy quotas. Review this value if Oracle changes the offering."
  default     = 24
}

variable "always_free_e2_micro_ocpus" {
  type        = number
  description = "OCI Always Free E2 micro OCPU allowance to mirror in tenancy quotas. Review this value if Oracle changes the offering."
  default     = 2
}

variable "always_free_total_storage_gb" {
  type        = number
  description = "OCI Always Free shared boot-plus-block storage allowance in GB to mirror in tenancy quotas. Review this value if Oracle changes the offering."
  default     = 200
}

variable "always_free_backup_count" {
  type        = number
  description = "OCI Always Free boot-plus-block backup allowance to mirror in tenancy quotas. Review this value if Oracle changes the offering."
  default     = 5
}

variable "monthly_safety_budget_amount" {
  type        = number
  description = "Near-zero monthly OCI budget amount, expressed as a whole number in your billing currency, used for tenancy-wide spend tripwire alerts."
  default     = 1

  validation {
    condition     = var.monthly_safety_budget_amount >= 1 && floor(var.monthly_safety_budget_amount) == var.monthly_safety_budget_amount
    error_message = "monthly_safety_budget_amount must be a whole number greater than or equal to 1."
  }
}

variable "instance_shape" {
  type        = string
  description = "Compute shape for the VPN instance. This repo intentionally stays on the Always Free AMD micro path."
  default     = "VM.Standard.E2.1.Micro"

  validation {
    condition     = var.instance_shape == "VM.Standard.E2.1.Micro"
    error_message = "instance_shape must remain VM.Standard.E2.1.Micro so this repo stays compatible with the tenancy-wide Always Free guardrails."
  }
}

variable "vpn_data_volume_size_gb" {
  type        = number
  description = "Size of the persistent VPN data volume in GB. Keep this conservative so the stack fits within the tenancy-wide Always Free storage pool."
  default     = 50

  validation {
    condition     = var.vpn_data_volume_size_gb > 0 && var.vpn_data_volume_size_gb <= 50
    error_message = "vpn_data_volume_size_gb must stay between 1 and 50 GB so the stack remains comfortably within the shared Always Free storage pool."
  }
}

locals {
  project_name             = "orable-vpn"
  instance_principal_group = "${local.project_name}-instance-principals"
  instance_secret_policy   = "${local.project_name}-secret-readers"

  always_free_capacity_quota_statements = [
    "zero compute-core quotas in tenancy",
    "zero compute-memory quotas in tenancy",
    "set compute-core quota standard-a1-core-count to ${var.always_free_a1_ocpus} in tenancy",
    "set compute-core quota standard-a1-core-regional-count to ${var.always_free_a1_ocpus} in tenancy",
    "set compute-memory quota standard-a1-memory-count to ${var.always_free_a1_memory_gb} in tenancy",
    "set compute-memory quota standard-a1-memory-regional-count to ${var.always_free_a1_memory_gb} in tenancy",
    "set compute-core quota standard-e2-micro-core-count to ${var.always_free_e2_micro_ocpus} in tenancy",
    "zero block-storage quotas in tenancy",
    "set block-storage quota total-storage-gb to ${var.always_free_total_storage_gb} in tenancy",
    "set block-storage quota backup-count to ${var.always_free_backup_count} in tenancy",
  ]

  deny_paid_resource_quota_statements = [
    "zero load-balancer quotas in tenancy",
    "zero compute-management quotas in tenancy",
    "zero auto-scaling quotas in tenancy",
    "zero database quotas in tenancy",
    "zero postgresql quotas in tenancy",
  ]
}

# 2. Networking (The "VPC")
resource "oci_core_vcn" "vpn_vcn" {
  compartment_id = var.compartment_id
  cidr_block     = "10.0.0.0/16"
  display_name   = "vpn_vcn"
  dns_label      = "vpnvcn"
}

resource "oci_core_internet_gateway" "vpn_ig" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.vpn_vcn.id
  display_name   = "vpn_internet_gateway"
}

resource "oci_core_default_route_table" "vpn_rt" {
  manage_default_resource_id = oci_core_vcn.vpn_vcn.default_route_table_id

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.vpn_ig.id
  }
}

# 3. Security (The Firewall)
resource "oci_core_security_list" "vpn_sec_list" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.vpn_vcn.id
  display_name   = "vpn_security_list"

  # Allow SSH
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"

    tcp_options {
      min = 22
      max = 22
    }
  }

  # Allow WireGuard VPN
  ingress_security_rules {
    protocol = "17" # UDP
    source   = "0.0.0.0/0"

    udp_options {
      min = 51820
      max = 51820
    }
  }

  # Allow all outbound (Essential for VPN routing)
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

resource "oci_core_subnet" "vpn_subnet" {
  compartment_id    = var.compartment_id
  vcn_id            = oci_core_vcn.vpn_vcn.id
  cidr_block        = "10.0.1.0/24"
  display_name      = "vpn_subnet"
  security_list_ids = [oci_core_security_list.vpn_sec_list.id]
}

data "oci_core_images" "ubuntu_latest" {
  compartment_id           = var.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = "24.04"
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_volume" "vpn_data" {
  availability_domain = data.oci_identity_availability_domain.ad.name
  compartment_id      = var.compartment_id
  display_name        = "vpn_data"
  size_in_gbs         = var.vpn_data_volume_size_gb
}

# --- COMPUTE: THE VPS ---
resource "oci_core_instance" "vpn_vps" {
  availability_domain = data.oci_identity_availability_domain.ad.name
  compartment_id      = var.compartment_id
  display_name        = local.project_name
  shape               = var.instance_shape # Fallback Always Free AMD shape

  create_vnic_details {
    subnet_id        = oci_core_subnet.vpn_subnet.id
    assign_public_ip = true
  }

  source_details {
    source_type = "image"
    source_id   = data.oci_core_images.ubuntu_latest.images[0].id
  }

  agent_config {
    is_management_disabled = false
    is_monitoring_disabled = false

    plugins_config {
      name          = "Compute Instance Monitoring"
      desired_state = "ENABLED"
    }
  }

  metadata = {
    ssh_authorized_keys = file(pathexpand(var.ssh_authorized_keys_path))
    user_data = base64encode(templatefile("${path.module}/setup.tftpl", {
      duck_domain                               = var.duck_domain
      duckdns_token_secret_ocid                 = var.duckdns_token_secret_ocid
      wg_admin_password_hash_base64_secret_ocid = var.wg_admin_password_hash_base64_secret_ocid
      ssh_host_private_key_secret_ocid          = var.ssh_host_private_key_secret_ocid
      ssh_host_public_key_secret_ocid           = var.ssh_host_public_key_secret_ocid
      vpn_data_device                           = "/dev/oracleoci/oraclevdb"
      docker_compose_content                    = file("${path.module}/docker-compose.yaml")
    }))
  }
}

resource "oci_identity_dynamic_group" "vpn_instance_principals" {
  compartment_id = var.tenancy_ocid
  name           = local.instance_principal_group
  description    = "Instance principals for the ${local.project_name} VPN host."
  matching_rule  = "ALL {instance.id = '${oci_core_instance.vpn_vps.id}'}"
}

resource "oci_identity_policy" "vpn_instance_secret_access" {
  compartment_id = var.tenancy_ocid
  name           = local.instance_secret_policy
  description    = "Allows the ${local.project_name} instance to read its runtime secrets."

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.vpn_instance_principals.name} to read secret-bundles in compartment id ${var.compartment_id}",
  ]
}

resource "oci_core_volume_attachment" "vpn_data_attachment" {
  attachment_type                     = "paravirtualized"
  device                              = "/dev/oracleoci/oraclevdb"
  display_name                        = "vpn_data_attachment"
  instance_id                         = oci_core_instance.vpn_vps.id
  volume_id                           = oci_core_volume.vpn_data.id
  is_pv_encryption_in_transit_enabled = false
}

data "oci_identity_availability_domain" "ad" {
  compartment_id = var.compartment_id
  ad_number      = 1
}

resource "oci_limits_quota" "tenancy_always_free_capacity" {
  count          = var.enable_tenancy_always_free_guardrails ? 1 : 0
  compartment_id = var.tenancy_ocid
  name           = "${local.project_name}-always-free-capacity"
  description    = "Tenancy-wide OCI quotas that keep quota-covered compute and storage resources inside documented Always Free limits."
  statements     = local.always_free_capacity_quota_statements
}

resource "oci_limits_quota" "tenancy_paid_resource_denies" {
  count          = var.enable_tenancy_always_free_guardrails ? 1 : 0
  compartment_id = var.tenancy_ocid
  name           = "${local.project_name}-paid-resource-denies"
  description    = "Tenancy-wide OCI quotas that deny common paid expansion-oriented services by default."
  statements     = local.deny_paid_resource_quota_statements
}

resource "oci_budget_budget" "tenancy_safety_budget" {
  count          = var.enable_tenancy_budget_alerts ? 1 : 0
  compartment_id = var.tenancy_ocid
  amount         = var.monthly_safety_budget_amount
  reset_period   = "MONTHLY"
  description    = "Near-zero tenancy-wide safety budget that alerts on unexpected non-free OCI usage."
  display_name   = "OrableTenancySafetyBudget"
  target_type    = "COMPARTMENT"
  targets        = [var.tenancy_ocid]

  lifecycle {
    precondition {
      condition     = trimspace(var.budget_alert_recipients) != ""
      error_message = "budget_alert_recipients must be set when enable_tenancy_budget_alerts is true."
    }
  }
}

resource "oci_budget_alert_rule" "tenancy_actual_spend_alert" {
  count          = var.enable_tenancy_budget_alerts ? 1 : 0
  budget_id      = oci_budget_budget.tenancy_safety_budget[0].id
  display_name   = "UnexpectedActualSpend"
  threshold      = 0.01
  threshold_type = "ABSOLUTE"
  type           = "ACTUAL"
  recipients     = var.budget_alert_recipients
  message        = "Unexpected OCI spend has exceeded 0.01 in your tenancy. Budgets only alert, so review recent resources and billing activity immediately."
}

resource "oci_budget_alert_rule" "tenancy_forecast_spend_alert" {
  count          = var.enable_tenancy_budget_alerts ? 1 : 0
  budget_id      = oci_budget_budget.tenancy_safety_budget[0].id
  display_name   = "UnexpectedForecastSpend"
  threshold      = 0.01
  threshold_type = "ABSOLUTE"
  type           = "FORECAST"
  recipients     = var.budget_alert_recipients
  message        = "OCI forecasts non-free spend above 0.01 in your tenancy. Budgets do not block charges, so investigate upcoming resource usage immediately."
}

output "instance_public_ip" {
  value       = oci_core_instance.vpn_vps.public_ip
  description = "The public IP address of the VPS"
}

output "instance_id" {
  value       = oci_core_instance.vpn_vps.id
  description = "The OCID of the VPS"
}
