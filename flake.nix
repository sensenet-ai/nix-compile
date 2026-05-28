{
  description = "nix-compile - Type inference for bash scripts at Nix eval time";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs =
    inputs@{ flake-parts, treefmt-nix, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ treefmt-nix.flakeModule ];

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
              cryptonite = pkgs.haskell.lib.dontCheck hsuper.cryptonite;
              hashing = pkgs.haskell.lib.dontCheck hsuper.hashing;
              hnix-store-core = pkgs.haskell.lib.dontCheck hsuper.hnix-store-core;
              hnix-store-remote = pkgs.haskell.lib.dontCheck hsuper.hnix-store-remote;
              hnix = pkgs.haskell.lib.dontCheck hsuper.hnix;
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
            nix-compile-test = pkgs.haskell.lib.doCheck nix-compile;
          };

          treefmt = {
            projectRootFile = "flake.nix";
            programs.fourmolu.enable = true;
            programs.nixfmt.enable = true;
          };

          devShells.default = pkgs.mkShell {
            name = "nix-compile-dev";
            inputsFrom = [
              nix-compile.env
              config.treefmt.build.devShell
            ];
            buildInputs = with pkgs; [
              ghc
              cabal-install
              haskell-language-server
              hlint
              jq
              mdbook
            ];
            shellHook = ''
              echo "nix-compile development shell"
              echo "  nix-compile parse <script>   Show facts"
              echo "  nix-compile infer <script>   Show schema (JSON)"
              echo "  nix-compile check <script>   Check policies"
              echo "  treefmt                      Format all sources"
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
            doc = {
              type = "app";
              program =
                let
                  script = pkgs.writeShellScript "nix-compile-doc" ''
                    dir=$(mktemp -d)
                    trap "rm -rf $dir" EXIT
                    cp -r ${./doc}/* "$dir/"
                    chmod -R u+w "$dir"
                    echo "serving docs at http://localhost:3000"
                    exec ${pkgs.mdbook}/bin/mdbook serve "$dir"
                  '';
                in
                "${script}";
            };
          };
        };
    };
}
