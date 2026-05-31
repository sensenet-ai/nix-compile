{ config, lib, self, ... }:
  {
  perSystem =
    { config, self', inputs', pkgs, system, ... }:
    let
    nix-compile = self'.packages.nix-compile or self.packages.${system}.nix-compile;
  in {
    checks =
      lib.mkIf (nix-compile != null) {
      "nix-compile:ci" =
        pkgs.runCommand "nix-compile-ci" {
        buildInputs = [nix-compile];
      } ''
        echo "running nix-compile check on ${self}"
        nix-compile check ${self} 2>&1 | tee ci.log
        if [ ''$? -eq 0 ]; then
          touch ''$out
        else
          echo "FAILED: nix-compile check found issues"
          exit 1
        fi




      '';
      "nix-compile:lint-flake" =
        pkgs.runCommand "nix-compile-lint-flake" {
        buildInputs = [nix-compile];
      } ''
        echo "linting flake.nix and embedded bash"
        nix-compile check ${self}/flake.nix 2>&1 | tee lint.log
        if [ ''$? -eq 0 ]; then
          touch ''$out
        else
          echo "FAILED: flake.nix has violations"
          exit 1
        fi




      '';
    };
    formatter =
      lib.mkIf (nix-compile != null) (pkgs.writeShellScriptBin "nix-compile-fmt" ''
      set -e
      files=()
      for arg in "''$@"; do
        if [ -d "''$arg" ]; then
          while IFS= read -r -d "" f; do
            files+=("''$f")
          done < <(find "''$arg" -name '*.nix' -print0 2>/dev/null || true)
        elif [ -f "''$arg" ]; then
          files+=("''$arg")
        fi
      done
      for f in "''${files[@]}"; do
        ${nix-compile}/bin/nix-compile fmt "''$f" > "''$f.tmp"
        mv "''$f.tmp" "''$f"
      done




    '');
    treefmt =
      lib.mkIf (nix-compile != null) {
      settings.formatter.nix-compile =
        {
        command = "${pkgs.bash}/bin/bash";
        options =
          [
          "-euc"
          ''
            for f in "''$@"; do
              ${nix-compile}/bin/nix-compile fmt "''$f" > "''$f.tmp" && mv "''$f.tmp" "''$f"
            done




          ''
          "--"
        ];
        includes = ["*.nix"];
      };
    };
  };
}