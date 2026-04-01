# PROVIDER CONFIG
provider "oci" {
  region = "il-jerusalem-1"
}

# VARIABLES (Pass these in via a .tfvars file or env vars)
variable "compartment_id" { type = string }
variable "tenancy_id"     { type = string }
variable "wg_private_key" { 
  type = string 
  sensitive = true
   }
variable "duck_domain"    { type = string }
variable "duck_token"     { 
  type = string
  sensitive = true 
  }
variable "wg_admin_password" {
  type = string
  sensitive = true
  description = "WireGuard Easy web UI password"
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


# --- SECURITY: VAULT & SECRET ---
resource "oci_kms_vault" "vpn_vault" {
  compartment_id = var.compartment_id
  display_name   = "vpn_stateless_vault"
  vault_type     = "DEFAULT"
}

resource "oci_kms_key" "vpn_master_key" {
  compartment_id      = var.compartment_id
  display_name        = "vpn_master_key"
  management_endpoint = oci_kms_vault.vpn_vault.management_endpoint
  key_shape { 
    algorithm = "AES"
    length = 32 
    }
}

resource "oci_vault_secret" "wg_key_secret" {
  compartment_id = var.compartment_id
  vault_id       = oci_kms_vault.vpn_vault.id
  key_id         = oci_kms_key.vpn_master_key.id
  secret_name    = "wg_private_key"
  secret_content {
    content_type = "BASE64"
    content      = base64encode(var.wg_private_key)
  }
}

# --- IDENTITY: DYNAMIC GROUP & POLICY ---
resource "oci_identity_dynamic_group" "vps_dg" {
  compartment_id = var.tenancy_id # Dynamic groups must be in tenancy root
  description    = "The dynamic VPN group identity"
  name           = "vpn_vps_access_group"
  matching_rule  = "instance.compartment.id = '${var.compartment_id}'"
}

resource "oci_identity_policy" "vpn_vps_policy" {
  compartment_id = var.compartment_id
  name           = "vps_vault_access"
  description    = "Allows the VPN VPS to retrieve secrets from the Vault at boot time"
  statements     = [
    "Allow dynamic-group vpn_vps_access_group to read secret-bundle in compartment id ${var.compartment_id}"
  ]
}

# --- COMPUTE: THE VPS ---
resource "oci_core_instance" "vpn_vps" {
  availability_domain = data.oci_identity_availability_domain.ad.name
  compartment_id      = var.compartment_id
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
      name   = "Compute Instance Monitoring"
      desired_state = "ENABLED"
    }
  }

  metadata = {
    ssh_authorized_keys = file(pathexpand("~/.ssh/id_rsa.pub"))
    user_data = base64encode(templatefile("setup.tftpl", {
      secret_ocid            = oci_vault_secret.wg_key_secret.id
      duck_domain            = var.duck_domain
      duck_token             = var.duck_token
      wg_admin_password      = var.wg_admin_password
      docker_compose_content = file("docker-compose.yaml")
      ssh_host_key_private = file("keys/host_key")
      ssh_host_key_public  = file("keys/host_key.pub")
    }))
  }


  depends_on = [oci_identity_policy.vpn_vps_policy, oci_vault_secret.wg_key_secret]
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