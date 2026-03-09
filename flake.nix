{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs }:
  let
    devShellSystems = [
      "aarch64-darwin"
      "aarch64-linux"
      "x86_64-darwin"
      "x86_64-linux"
    ];

    mkPkgs = system: import nixpkgs {
      inherit system;
      config.allowUnfree = true;
    };
  in {
    devShells = nixpkgs.lib.genAttrs devShellSystems (system:
      let pkgs = mkPkgs system;
      in {
        default = pkgs.mkShell {
          buildInputs = with pkgs; [
            oci-cli
            opentofu
            jq
            python3
          ];

          shellHook = ''
            echo "OCI CLI and OpenTofu development environment loaded"
            echo "OCI CLI version: $(oci --version)"
            echo "TOFU version: $(tofu version)"
          '';
        };
      });

    nixosConfigurations = {
      oci = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          "${nixpkgs}/nixos/modules/virtualisation/oci-image.nix"
          ./modules/configuration.nix
        ];
      };
    };

    packages = {
      aarch64-linux = {
        default = self.nixosConfigurations.oci.config.system.build.OCIImage;
        ociImage = self.nixosConfigurations.oci.config.system.build.OCIImage;
      };
    };

    checks = nixpkgs.lib.genAttrs devShellSystems (system:
      let pkgs = mkPkgs system;
      in {
        tf-fmt = pkgs.runCommand "tf-fmt-check" { } ''
          ${pkgs.opentofu}/bin/tofu -chdir=${./terraform} fmt -check -recursive
          touch $out
        '';
      });

  };
}
