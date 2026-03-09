# Deploying NixOS to Oracle Cloud Free Tier ARM Instances

by [Erik Parawell](#) on November 6th, 2025

## Project Motivation

Oracle Cloud's free tier offers 4 ARM cores, 24GB RAM, and 200GB storage. I wanted to deploy NixOS instances there for testing and development. The deployment process should be fully automated with Terraform rather than requiring manual configuration through the Oracle console.

Most existing guides for deploying custom images to Oracle Cloud cover the basic steps but miss critical configuration requirements for ARM instances. This resulted in shape compatibility errors when attempting to launch A1.Flex instances with custom NixOS images.

One important limitation up front: this workflow relies on importing a custom image, and custom images are not an Always Free-eligible image type. In practice that means you need either a paid account or a Free Trial account with credits remaining before Oracle will let you launch from the imported image.

## Project Goals

The goals for this deployment were:

 1. Build a NixOS ARM64 image suitable for Oracle Cloud Infrastructure  
 2. Automate image upload and import using Terraform  
 3. Configure shape compatibility for A1.Flex instances  
 4. Set proper image capabilities for boot firmware and virtualization  
 5. Launch instances without manual console intervention

## The Shape Compatibility Issue

Oracle Cloud requires two separate configuration steps for custom images that aren't immediately obvious:

**Shape Compatibility Registration**  
Custom images must explicitly declare which instance shapes they support. This is configured under Custom Images → "Edit details" → "Compatible Shapes" in the console. Without this registration, Oracle returns a "shape not compatible with image" error when attempting to launch instances.

**Image Capabilities Metadata**  
Images require metadata defining boot firmware type and virtualization mode. This is set under Custom Images → "Edit image capabilities". Incorrect settings result in instances that boot but become unresponsive.

These settings exist in separate UI locations and both must be configured correctly for ARM instances. The Terraform provider includes resources to automate both steps.

## Building the NixOS Image

NixOS includes an OCI image builder module. The flake configuration:


```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs }: {
    nixosConfigurations.oci-base = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        "${nixpkgs}/nixos/modules/virtualisation/oci-image.nix"
        ./configuration.nix
      ];
    };

    packages.aarch64-linux.default =
      self.nixosConfigurations.oci-base.config.system.build.OCIImage;
  };
}
```

A minimal configuration.nix:


```nix
{ config, pkgs, ... }: {
  system.stateVersion = "25.05";

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  services.cloud-init.enable = true;

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
  };

  users.users.nixos = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3... your-key-here"
    ];
  };

  security.sudo.wheelNeedsPassword = false;
}
```

Building the image:


```bash
# On ARM hardware
$ nix build .#

# Cross-compile from x86_64
$ nix build .#packages.aarch64-linux.default
```

Cross-compilation requires ARM emulation on the build host:


```nix
boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
```

The build produces result/nixos.qcow2.

## Terraform Configuration

The Terraform configuration handles image upload, import, shape compatibility registration, and image capabilities.

**Image Upload and Import**


```hcl
# Create a bucket for image uploads
resource "oci_objectstorage_bucket" "nixos_bucket" {
  compartment_id = var.compartment_ocid
  namespace      = var.namespace
  name           = var.bucket_name
  access_type    = "NoPublicAccess"
}

# Upload image to Object Storage
resource "oci_objectstorage_object" "nixos_image" {
  bucket    = oci_objectstorage_bucket.nixos_bucket.name
  namespace = var.namespace
  object    = "nixos-aarch64.qcow2"
  source    = "./result/nixos.qcow2"
}

# Import as custom OCI image
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
```

If you already have a bucket you want to reuse, you can switch this resource back to a `data "oci_objectstorage_bucket"` lookup. I prefer managing the bucket here because it removes one manual prerequisite from the example.

**Shape Compatibility Registration**

This resource registers the image with the A1.Flex shape:


```hcl
resource "oci_core_shape_management" "nixos_a1_compat" {
  compartment_id = var.compartment_ocid
  image_id       = oci_core_image.nixos.id
  shape_name     = "VM.Standard.A1.Flex"

  depends_on = [oci_core_image.nixos]
}
```

Without this resource, instance creation fails with shape compatibility errors.

**Image Capabilities**


```hcl
resource "oci_core_compute_image_capability_schema" "nixos_caps" {
  compartment_id = var.compartment_ocid
  image_id       = oci_core_image.nixos.id
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
```

## Instance Launch Configuration


```hcl
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
    network_type      = "PARAVIRTUALIZED"
    boot_volume_type  = "PARAVIRTUALIZED"
  }

  depends_on = [
    oci_core_shape_management.nixos_a1_compat,
    oci_core_compute_image_capability_schema.nixos_caps
  ]
}
```

The depends\_on ensures shape compatibility and image capabilities are configured before instance creation.

## Deployment Process

Create an Object Storage bucket in the Oracle console (Storage → Buckets → Create Bucket).

Deploy the infrastructure:


```shell
$ cd terraform
$ cat > terraform.tfvars <<'EOF'
tenancy_ocid     = "ocid1.tenancy.oc1..aaa..."
compartment_ocid = "ocid1.compartment.oc1..aaa..."
namespace        = "your-namespace"
region           = "us-ashburn-1"
EOF

$ terraform init
$ terraform plan
$ terraform apply
```

Image import typically takes 30-45 minutes. Once complete:


```shell
$ IP=$(terraform output -raw instance_ip)
$ ssh nixos@$IP
```

## Troubleshooting

**Shape not compatible error**  
Verify the shape management resource was created:


```shell
$ terraform state show oci_core_shape_management.nixos_a1_compat
```

If missing, manually configure in the console: Custom Images → image → "Edit details" → "Compatible Shapes" → add VM.Standard.A1.Flex with min 1 OCPU / 6GB RAM and max 4 OCPU / 24GB RAM.

**Instance boots but is unresponsive**  
Rebuild image capabilities metadata: Custom Images → image → "Edit image capabilities" → Save without changes.

**Build fails on x86\_64**  
Enable ARM emulation:


```nix
boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
```

## Project Status

The deployment process is now fully automated. NixOS instances can be deployed to Oracle Cloud's free tier ARM instances without manual console configuration.

**What is working:**

 - Automated image build with Nix  
 - Image upload to Object Storage  
 - Shape compatibility registration via Terraform  
 - Image capabilities configuration  
 - Instance launch with proper dependencies

**Key findings:**

Shape compatibility registration is required for custom ARM images but not well documented. The oci\_core\_shape\_management Terraform resource automates what would otherwise require manual UI configuration.

Image capabilities metadata must be set correctly for instances to become accessible after boot. The oci\_core\_compute\_image\_capability\_schema resource handles this configuration.

With proper automation, Oracle Cloud's free tier provides 4 ARM cores and 24GB RAM suitable for development workloads and testing infrastructure.
