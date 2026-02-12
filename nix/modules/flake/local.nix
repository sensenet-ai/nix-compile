# Local development module for nix-compile
#
# This module provides packages, devShells, checks, and apps for local development.
# It is imported by the flake.nix at the repository root.
{ inputs, ... }:
{
  _class = "flake";

  perSystem =
    { pkgs, ... }:
    let
      haskellPackages = pkgs.haskellPackages.override {
        overrides = hself: hsuper: {
          cryptonite = pkgs.haskell.lib.dontCheck hsuper.cryptonite;
          hashing = pkgs.haskell.lib.dontCheck hsuper.hashing;
          hnix-store-core = pkgs.haskell.lib.dontCheck hsuper.hnix-store-core;
          hnix-store-remote = pkgs.haskell.lib.dontCheck hsuper.hnix-store-remote;
          hnix = pkgs.haskell.lib.dontCheck hsuper.hnix;
        };
      };

      nix-compile = haskellPackages.callCabal2nix "nix-compile" inputs.self { };
    in
    {
      packages = {
        default = nix-compile;
        inherit nix-compile;
      };

      checks.build = nix-compile;

      devShells.default = pkgs.mkShell {
        name = "nix-compile-dev";
        inputsFrom = [ nix-compile.env ];
        packages = [
          pkgs.cabal-install
          pkgs.haskell-language-server
          pkgs.hlint
          pkgs.ormolu
          pkgs.ghcid
        ];
        shellHook = ''
          echo ""
          echo "  nix-compile dev shell"
          echo "  ─────────────────────"
          echo ""
          echo "  build      cabal build"
          echo "  test       cabal test"
          echo "  repl       cabal repl"
          echo "  watch      ghcid"
          echo ""
          echo "  hlint      hlint lib/ app/ test/"
          echo "  fmt        ormolu -i lib/**/*.hs app/*.hs"
          echo ""
        '';
      };

      apps = {
        default = {
          type = "app";
          program = "${nix-compile}/bin/nix-compile";
          meta.description = "nix-compile CLI";
        };
        nix-compile = {
          type = "app";
          program = "${nix-compile}/bin/nix-compile";
          meta.description = "nix-compile CLI";
        };
      };
    };
}
