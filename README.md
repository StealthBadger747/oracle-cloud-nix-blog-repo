# Oracle Cloud NixOS Companion Repo

This repo is the companion example for the article at https://erikparawell.com/oracle-cloud-nixos.html.

The blog post is the source of truth for the write-up and explanation. This repo only contains the reproducible example code and the minimal setup notes needed to run it.

## Prerequisites
- `nix` with flakes enabled
- OCI CLI credentials in `~/.oci/config` (profile name defaults to `DEFAULT`)
- `terraform`/`opentofu`
- An Oracle account that can import custom images. Custom images are not Always Free-eligible, so this generally means a PAYG account or a Free Trial account with remaining credits.

Optional dev shell with the right tools:
```bash
nix develop
```

## Build the image
1) Put your SSH public key in `modules/configuration.nix` (or set `ssh_authorized_key` in Terraform). Replace the placeholder key with your own before building or applying.  
2) On ARM: `nix build .#`  
   On x86_64 (with binfmt/qemu available): `nix build .#packages.aarch64-linux.default`

Output: `result/nixos.qcow2`

If you cross-build on x86_64, ensure the host supports ARM emulation, e.g. in `/etc/nixos/configuration.nix`:
```nix
boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
```

## Deploy with Terraform
1) Create `terraform/terraform.tfvars` from the provided example and fill in:
   - `tenancy_ocid`, `compartment_ocid`, `namespace`, `bucket_name`, `region`
   - `ssh_authorized_key` (same key you want on the instance)
2) From `terraform/`:
```bash
terraform init
terraform plan
terraform apply
```

Terraform creates the Object Storage bucket if needed, uploads `result/nixos.qcow2`, imports it as a custom image, registers A1.Flex compatibility, sets image capability schema values, builds a small public VCN/subnet, and launches a VM.Standard.A1.Flex instance.

Grab the IP:
```bash
terraform output -raw instance_ip
ssh nixos@$(terraform output -raw instance_ip)
```

## Clean up
From `terraform/`: `terraform destroy`
