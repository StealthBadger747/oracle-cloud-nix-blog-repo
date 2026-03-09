terraform {
  required_version = ">= 1.7.0"

  required_providers {
    oci = {
      source = "oracle/oci"
    }
  }
}

provider "oci" {
  region              = var.region
  config_file_profile = var.oci_profile
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

locals {
  image_object_name = "nixos-aarch64.qcow2"
}

resource "oci_objectstorage_bucket" "nixos_bucket" {
  compartment_id = var.compartment_ocid
  namespace      = var.namespace
  name           = var.bucket_name
  access_type    = "NoPublicAccess"
}

resource "oci_objectstorage_object" "nixos_image" {
  bucket    = oci_objectstorage_bucket.nixos_bucket.name
  namespace = var.namespace
  object    = local.image_object_name
  source    = var.local_image_path
}

resource "oci_core_image" "nixos" {
  compartment_id = var.compartment_ocid
  display_name   = "NixOS ARM64"

  image_source_details {
    source_type    = "objectStorageTuple"
    namespace_name = var.namespace
    bucket_name    = oci_objectstorage_bucket.nixos_bucket.name
    object_name    = oci_objectstorage_object.nixos_image.object
  }

  launch_mode = "PARAVIRTUALIZED"

  timeouts {
    create = "60m"
  }
}

resource "oci_core_shape_management" "nixos_a1_compat" {
  compartment_id = var.compartment_ocid
  image_id       = oci_core_image.nixos.id
  shape_name     = "VM.Standard.A1.Flex"

  depends_on = [oci_core_image.nixos]
}

resource "oci_core_compute_image_capability_schema" "nixos_caps" {
  compartment_id                                      = var.compartment_ocid
  image_id                                            = oci_core_image.nixos.id
  compute_global_image_capability_schema_version_name = "2024-03-27"

  schema_data = {
    "Compute.Firmware" = jsonencode({
      descriptorType = "enumstring"
      source         = "IMAGE"
      defaultValue   = "UEFI_64"
      values         = ["UEFI_64"]
    })

    "Compute.LaunchMode" = jsonencode({
      descriptorType = "enumstring"
      source         = "IMAGE"
      defaultValue   = "PARAVIRTUALIZED"
      values         = ["PARAVIRTUALIZED", "EMULATED", "CUSTOM", "NATIVE"]
    })

    "Storage.BootVolumeType" = jsonencode({
      descriptorType = "enumstring"
      source         = "IMAGE"
      defaultValue   = "PARAVIRTUALIZED"
      values         = ["PARAVIRTUALIZED", "ISCSI", "SCSI", "IDE", "NVME"]
    })

    "Network.AttachmentType" = jsonencode({
      descriptorType = "enumstring"
      source         = "IMAGE"
      defaultValue   = "PARAVIRTUALIZED"
      values         = ["PARAVIRTUALIZED", "E1000", "VFIO", "VDPA"]
    })
  }
}

resource "oci_core_vcn" "main" {
  compartment_id = var.compartment_ocid
  cidr_block     = "10.0.0.0/16"
  display_name   = "nixos-vcn"
  dns_label      = "nixosvcn"
}

resource "oci_core_internet_gateway" "igw" {
  compartment_id = var.compartment_ocid
  display_name   = "nixos-igw"
  vcn_id         = oci_core_vcn.main.id
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  display_name   = "nixos-public-rt"
  vcn_id         = oci_core_vcn.main.id

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.igw.id
  }
}

resource "oci_core_security_list" "ssh" {
  compartment_id = var.compartment_ocid
  display_name   = "nixos-ssh"
  vcn_id         = oci_core_vcn.main.id

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"

    tcp_options {
      min = 22
      max = 22
    }
  }

  ingress_security_rules {
    protocol = "1" # ICMP
    source   = "0.0.0.0/0"

    icmp_options {
      type = 3
      code = 4
    }
  }
}

resource "oci_core_subnet" "public" {
  compartment_id             = var.compartment_ocid
  display_name               = "nixos-public"
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = "10.0.1.0/24"
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.ssh.id]
  dhcp_options_id            = oci_core_vcn.main.default_dhcp_options_id
  prohibit_public_ip_on_vnic = false
  dns_label                  = "public"
}

resource "oci_core_instance" "nixos" {
  compartment_id      = var.compartment_ocid
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    memory_in_gbs = 24
    ocpus         = 4
  }

  source_details {
    source_type             = "image"
    source_id               = oci_core_image.nixos.id
    boot_volume_vpus_per_gb = 10
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = true
  }

  launch_options {
    network_type     = "PARAVIRTUALIZED"
    boot_volume_type = "PARAVIRTUALIZED"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_authorized_key
  }

  depends_on = [
    oci_core_shape_management.nixos_a1_compat,
    oci_core_compute_image_capability_schema.nixos_caps
  ]
}
