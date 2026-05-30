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
        "nix-compile:ci" = pkgs.runCommand "nix-compile-ci" { buildInputs = [ nix-compile ]; } ''
          echo "running nix-compile check on ${self}"
          nix-compile check ${self} 2>&1 | tee ci.log
          if [ $? -eq 0 ]; then
            touch $out
          else
            echo "FAILED: nix-compile check found issues"
            exit 1
          fi
        '';

        "nix-compile:lint-flake" =
          pkgs.runCommand "nix-compile-lint-flake" { buildInputs = [ nix-compile ]; }
            ''
              echo "linting flake.nix and embedded bash"
              nix-compile check ${self}/flake.nix 2>&1 | tee lint.log
              if [ $? -eq 0 ]; then
                touch $out
              else
                echo "FAILED: flake.nix has violations"
                exit 1
              fi
            '';
      };
    };
}
