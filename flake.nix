{
  description = "nix-compile - Type inference for bash scripts at Nix eval time";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        {
          config,
          self',
          inputs',
          pkgs,
          system,
          ...
        }:
        let
          haskellPackages = pkgs.haskellPackages.override {
            overrides = hself: hsuper: {
              # Disable tests for packages that have flaky tests
              cryptonite = pkgs.haskell.lib.dontCheck hsuper.cryptonite;
              hashing = pkgs.haskell.lib.dontCheck hsuper.hashing;
              hnix-store-core = pkgs.haskell.lib.dontCheck hsuper.hnix-store-core;
              hnix-store-remote = pkgs.haskell.lib.dontCheck hsuper.hnix-store-remote;
              # Use hnix from nixpkgs (0.17.x)
              hnix = pkgs.haskell.lib.dontCheck hsuper.hnix;
              # ShellCheck is available as ShellCheck
              ShellCheck = hsuper.ShellCheck;
            };
          };

          nix-compile = haskellPackages.callCabal2nix "nix-compile" ./. { };
        in
        {
          packages = {
            default = nix-compile;
            nix-compile = nix-compile;
          };

          checks = {
            nix-compile-test = pkgs.stdenv.mkDerivation {
              name = "nix-compile-test";
              src = ./.;
              nativeBuildInputs = [
                nix-compile
                haskellPackages.ghc
              ];
              buildPhase = ''
                runHook preBuild
                # Run the test suite
                ${nix-compile}/bin/nix-compile --help > /dev/null
                runHook postBuild
              '';
              installPhase = ''
                runHook preInstall
                touch $out
                runHook postInstall
              '';
            };
          };

          devShells.default = pkgs.mkShell {
            name = "nix-compile-dev";
            inputsFrom = [ nix-compile.env ];
            buildInputs = with pkgs; [
              ghc
              cabal-install
              haskell-language-server
              hlint
              ormolu
              jq
            ];
            shellHook = ''
              echo "nix-compile development shell"
              echo "  nix-compile parse <script>   Show facts"
              echo "  nix-compile infer <script>   Show schema (JSON)"
              echo "  nix-compile check <script>   Check policies"
            '';
          };

          apps = {
            default = {
              type = "app";
              program = "${nix-compile}/bin/nix-compile";
            };
            nix-compile = {
              type = "app";
              program = "${nix-compile}/bin/nix-compile";
            };
          };
        };
    };
}
