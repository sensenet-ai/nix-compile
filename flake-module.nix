{
  config,
  lib,
  self,
  ...
}:
{
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
      nix-compile = self'.packages.nix-compile or self.packages.${system}.nix-compile;
    in
    {
      checks = lib.mkIf (nix-compile != null) {
        "nix-compile:typecheck" =
          let
            nixFiles = lib.filesystem.listFilesRecursive (self + "/nix");
          in
          pkgs.runCommand "nix-compile-typecheck" { buildInputs = [ nix-compile ]; } ''
            echo "running nix-compile typecheck on ${self}"
            nix-compile typecheck ${self}/nix 2>&1 | tee typecheck.log
            if nix-compile typecheck ${self}/nix 2>&1 | grep -q "0 failed"; then
              touch $out
            else
              echo "FAILED: nix-compile found type errors"
              exit 1
            fi
          '';

        "nix-compile:graph" =
          let
            graph = nix-compile + "/bin/nix-compile";
          in
          pkgs.runCommand "nix-compile-graph" { buildInputs = [ nix-compile ]; } ''
            echo "running nix-compile graph on ${self}"
            nix-compile graph ${self} 2>&1 | tee graph.log
            if [ $? -eq 0 ]; then
              touch $out
            else
              echo "FAILED: nix-compile found layout violations"
              exit 1
            fi
          '';

        "nix-compile:lint-flake" =
          pkgs.runCommand "nix-compile-lint-flake" { buildInputs = [ nix-compile ]; }
            ''
              echo "linting flake.nix and embedded bash"
              nix-compile nix ${self}/flake.nix 2>&1 | tee lint.log
              if nix-compile nix ${self}/flake.nix 2>&1 | grep -q "total error(s)"; then
                echo "FAILED: flake.nix has lint violations"
                exit 1
              fi
              touch $out
            '';
      };
    };
}
