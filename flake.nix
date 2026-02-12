{
  description = "nix-compile - Type inference and static analysis for Nix and bash";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      imports = [
        ./nix/modules/flake/local.nix
        ./nix/modules/flake/default.nix
      ];

      nix-compile = {
        enable = true;
        profile = "strict";
        layout = "straylight";
        paths = [ "nix" "lib" "app" "config" ];
        pre-commit.enable = true;
      };

      flake = {
        flakeModules.default = ./nix/modules/flake/default.nix;
        nixosModules.default = ./nix/modules/nixos/default.nix;
        homeModules.default = ./nix/modules/home-manager/default.nix;

        lib = import ./nix/lib { inherit (inputs.nixpkgs) lib; };
      };
    };
}
