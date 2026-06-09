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
        # straylint case-ban gate. Enforces zero `case` / `\case` over the
        # ALLOWLIST of modules already swept to the house style — they cannot
        # regress. The list grows as the sweep proceeds; when it covers the tree,
        # the whole codebase is case-free by construction. (~433 survivors today
        # across 48 files; run `straylint lib app` to see the rest.)
        "nix-compile:case-ban" =
          let
            # files swept clean of `case` / `\case` (guards & equations only)
            sweptClean = [
              "lib/NixCompile/Bash/Facts.hs"
              "lib/NixCompile/Bash/Parse.hs"
              "lib/NixCompile/Bash/Patterns.hs"
              "lib/NixCompile/CLI/Check.hs"
              "lib/NixCompile/Config.hs"
              "lib/NixCompile/Diagnostic.hs"
              "lib/NixCompile/Emit/Config.hs"
              "lib/NixCompile/LSP/Handlers.hs"
              "lib/NixCompile/LSP/ProjectCache.hs"
              "lib/NixCompile/Nix/Naming.hs"
              "lib/NixCompile/Safety.hs"
              "lib/NixCompile/Schema/Build.hs"
              "lib/NixCompile/Nix/Flake.hs"
              "lib/NixCompile/Nix/Inference.hs"
              "lib/NixCompile/Nix/LayoutConvention.hs"
              "lib/NixCompile/Nix/Lint.hs"
              "lib/NixCompile/Nix/LintCombined.hs"
              "lib/NixCompile/Nix/LintDerivation.hs"
              "lib/NixCompile/Nix/LintPackages.hs"
              "lib/NixCompile/Nix/LintPatterns.hs"
              "lib/NixCompile/Nix/Module.hs"
              "lib/NixCompile/Nix/ModuleKind.hs"
              "lib/NixCompile/Nix/ModuleSystem.hs"
              "lib/NixCompile/Nix/Parse.hs"
              "lib/NixCompile/Nix/Types.hs"
              "lib/NixCompile/Nix/Scope.hs"
              "lib/NixCompile/Nix/Utils.hs"
            ];
          in
          pkgs.runCommandLocal "nix-compile-case-ban" { } ''
            ${nix-compile}/bin/straylint --strict ${
              lib.concatMapStringsSep " " (f: "${self}/${f}") sweptClean
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
