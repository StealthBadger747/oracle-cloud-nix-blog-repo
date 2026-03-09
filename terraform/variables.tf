variable "tenancy_ocid" {
  description = "Tenancy OCID (used for availability domain lookup)"
  type        = string
}

variable "compartment_ocid" {
  description = "Compartment OCID to host the image and instance"
  type        = string
}

variable "namespace" {
  description = "Object Storage namespace (find under Object Storage -> Namespace)"
  type        = string
}

variable "bucket_name" {
  description = "Name of the Object Storage bucket to create for the qcow2 upload"
  type        = string
}

variable "region" {
  description = "OCI region (e.g., us-ashburn-1)"
  type        = string
}

variable "oci_profile" {
  description = "Profile name from ~/.oci/config to authenticate with"
  type        = string
  default     = "DEFAULT"
}

variable "local_image_path" {
  description = "Path to the built qcow2 image produced by nix build"
  type        = string
  default     = "../result/nixos.qcow2"
}

variable "ssh_authorized_key" {
  description = "SSH public key to inject into the instance (same key used inside the image)"
  type        = string
}
