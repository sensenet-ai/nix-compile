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
        "nix-compile:ci" = builtins.derivation {
          name = "nix-compile-ci";
          builder = "${pkgs.bash}/bin/bash";
          system = builtins.currentSystem;
          args = [
            "-euc"
            ''
              echo "running nix-compile check on ${self}"
              ${nix-compile}/bin/nix-compile check ${self} 2>&1 | tee ci.log
              if [ $? -eq 0 ]; then
                touch $out
              else
                echo "FAILED: nix-compile check found issues"
                exit 1
              fi
            ''
          ];
        };
        "nix-compile:lint-flake" = builtins.derivation {
          name = "nix-compile-lint-flake";
          builder = "${pkgs.bash}/bin/bash";
          system = builtins.currentSystem;
          args = [
            "-euc"
            ''
              echo "linting flake.nix and embedded bash"
              ${nix-compile}/bin/nix-compile check ${self}/flake.nix 2>&1 | tee lint.log
              if [ $? -eq 0 ]; then
                touch $out
              else
                echo "FAILED: flake.nix has violations"
                exit 1
              fi
            ''
          ];
        };
      };
      formatter = lib.mkIf (nix-compile != null) (
        builtins.derivation {
          name = "nix-compile-fmt";
          builder = "${pkgs.bash}/bin/bash";
          system = builtins.currentSystem;
          args = [
            "-euc"
            ''
                ${pkgs.coreutils}/bin/install -Dm755 /dev/stdin $out/bin/nix-compile-fmt << 'ENDOFSCRIPT'
              set -e
              files=()
              for arg in "$@"; do
                if [ -d "$arg" ]; then
                  while IFS= read -r -d "" f; do
                    case "$f" in */adversarial_output/*|*/test/fixtures/*) continue ;; esac
                    files+=("$f")
                  done < <(${pkgs.findutils}/bin/find "$arg" -name '*.nix' -not -path '*/adversarial_output/*' -print0 2>/dev/null || true)
                elif [ -f "$arg" ]; then
                  files+=("$arg")
                fi
              done
              for f in "''${files[@]}"; do
                ${nix-compile}/bin/nix-compile fmt "$f" > "$f.tmp"
                ${pkgs.coreutils}/bin/mv "$f.tmp" "$f"
              done
              ENDOFSCRIPT
            ''
          ];
        }
      );
    };
}
