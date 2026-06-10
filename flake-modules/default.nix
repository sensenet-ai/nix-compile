{
  lib,
  self,
  ...
}:
{
  perSystem =
    {
      self',
      pkgs,
      system,
      ...
    }:
    let
      nix-compile = self'.packages.nix-compile or self.packages.${system}.nix-compile;
    in
    {
      checks = lib.mkIf (nix-compile != null) {
        # End-to-end layout-enforcement guard. The harness in
        # tools/layoutcheck/check.sh is invoked ONLY here, through
        # `nix flake check` — keeping a single disciplined runner so it can't
        # drift from a parallel manual invocation. It runs the real binary
        # against the committed good/perturbed flake-parts fixture projects and
        # asserts the clean one is layout-clean and the perturbed one fails.
        "nix-compile:layout-e2e" = pkgs.runCommandLocal "nix-compile-layout-e2e" {
          nativeBuildInputs = [
            pkgs.bash
            pkgs.gnugrep
            pkgs.coreutils
          ];
        } ''
          bash ${self}/tools/layoutcheck/check.sh ${nix-compile}/bin/nix-compile
          touch $out
        '';
        # nix-compile dogfoods itself: type-check, lint, and layout-check the
        # whole source tree. Uses the repo's own .nix-compile.dhall (layout =
        # flake-parts, ignores), so it must be run with --config pointing at it
        # (the build CWD is not ${self}). A non-zero exit fails the check.
        "nix-compile:ci" = pkgs.runCommandLocal "nix-compile-ci" { } ''
          echo "running nix-compile check on ${self}"
          ${nix-compile}/bin/nix-compile --config ${self}/.nix-compile.dhall check ${self}
          touch $out
        '';
        "nix-compile:lint-flake" = pkgs.runCommandLocal "nix-compile-lint-flake" { } ''
          echo "linting flake.nix and embedded bash"
          ${nix-compile}/bin/nix-compile --config ${self}/.nix-compile.dhall check ${self}/flake.nix
          touch $out
        '';
        # CLI smoke / jank guard. Runs the real binary across a good/bad/empty/
        # missing/dir input matrix and asserts exit codes, error categories, and
        # the stdout/stderr contract — the rough edges dogfooding surfaced
        # (crashes, mislabeled errors, hangs). Same single-runner discipline as
        # layout-e2e: invoked ONLY here so it cannot drift from a manual run.
        "nix-compile:cli" = pkgs.runCommandLocal "nix-compile-cli" {
          nativeBuildInputs = [
            pkgs.bash
            pkgs.gnugrep
            pkgs.coreutils
          ];
        } ''
          bash ${self}/tools/clicheck/check.sh ${nix-compile}/bin/nix-compile
          touch $out
        '';
        # straylint case-ban gate. Enforces zero `case` / `\case` across the
        # ENTIRE first-party Haskell tree (lib/, app/, straylint/): if a `case`
        # can be written as function-clause equations, guards, or an eliminator
        # (maybe/either/…), it is. The whole codebase is case-free by
        # construction — new files are covered automatically, so the rule can't
        # be regressed by adding a module. See doc/HOUSE_STYLE.md for the law.
        "nix-compile:case-ban" =
          let
            # every first-party .hs file (straylint takes an explicit file list;
            # it does not recurse directory arguments)
            haskellSources = builtins.filter (path: lib.hasSuffix ".hs" (toString path)) (
              lib.filesystem.listFilesRecursive (self + "/lib")
              ++ lib.filesystem.listFilesRecursive (self + "/app")
              ++ lib.filesystem.listFilesRecursive (self + "/straylint")
            );
          in
          pkgs.runCommandLocal "nix-compile-case-ban" { } ''
            ${nix-compile}/bin/straylint --strict ${
              lib.concatMapStringsSep " " toString haskellSources
            }
            touch $out
          '';
      };
      formatter = lib.mkIf (nix-compile != null) (
        builtins.derivation {
          name = "nix-compile-fmt";
          builder = "${pkgs.bash}/bin/bash";
          system = system;
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
