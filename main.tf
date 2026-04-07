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

locals {
  project_name             = "orable-vpn"
  instance_principal_group = "${local.project_name}-instance-principals"
  instance_secret_policy   = "${local.project_name}-secret-readers"
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
  shape                    = "VM.Standard.E2.1.Micro" # Ensures it only finds compatible images
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_volume" "vpn_data" {
  availability_domain = data.oci_identity_availability_domain.ad.name
  compartment_id      = var.compartment_id
  display_name        = "vpn_data"
  size_in_gbs         = 50
}

# --- COMPUTE: THE VPS ---
resource "oci_core_instance" "vpn_vps" {
  availability_domain = data.oci_identity_availability_domain.ad.name
  compartment_id      = var.compartment_id
  display_name        = local.project_name
  shape               = "VM.Standard.E2.1.Micro" # Fallback Always Free AMD shape

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
      duck_domain                         = var.duck_domain
      duckdns_token_secret_ocid          = var.duckdns_token_secret_ocid
      wg_admin_password_hash_base64_secret_ocid = var.wg_admin_password_hash_base64_secret_ocid
      ssh_host_private_key_secret_ocid   = var.ssh_host_private_key_secret_ocid
      ssh_host_public_key_secret_ocid    = var.ssh_host_public_key_secret_ocid
      vpn_data_device                    = "/dev/oracleoci/oraclevdb"
      docker_compose_content             = file("${path.module}/docker-compose.yaml")
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

output "instance_public_ip" {
  value       = oci_core_instance.vpn_vps.public_ip
  description = "The public IP address of the VPS"
}

output "instance_id" {
  value       = oci_core_instance.vpn_vps.id
  description = "The OCID of the VPS"
}
