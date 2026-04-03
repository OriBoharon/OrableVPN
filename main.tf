# PROVIDER CONFIG
provider "oci" {
  region           = var.region
  tenancy_ocid     = var.tenancy_ocid
  user_ocid        = var.user_ocid
  fingerprint      = var.fingerprint
  private_key_path = var.private_key_path
}

# VARIABLES (Pass these in via a .tfvars file or env vars)
variable "compartment_id" { type = string }
variable "region"         { type = string }
variable "tenancy_ocid"   { type = string }
variable "user_ocid"        { type = string }
variable "fingerprint"    { type = string }
variable "private_key_path" { type = string }
variable "duck_domain"    { type = string }
variable "duck_token"     { 
  type = string
  sensitive = true 
  }
variable "wg_admin_password_hash" {
  type = string
  sensitive = true
  description = "WireGuard Easy web UI password hash"
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
      duck_domain            = var.duck_domain
      duck_token             = var.duck_token
      vpn_data_device        = "/dev/oracleoci/oraclevdb"
      docker_compose_content = templatefile("docker-compose.yaml", {
        duck_domain             = var.duck_domain
        wg_admin_password_hash  = replace(var.wg_admin_password_hash, "$", "$$")
      })
      ssh_host_key_private = file("keys/host_key")
      ssh_host_key_public  = file("keys/host_key.pub")
    }))
  }
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
