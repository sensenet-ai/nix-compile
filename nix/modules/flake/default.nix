# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                                                      // nix-compile // module
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
#     "The matrix has its roots in primitive arcade games, in early graphics
#      programs and military experimentation with cranial jacks."
#
#                                                                  — Neuromancer
#
# Flake-parts module for nix-compile static analysis.
#
# Provides:
#   - checks.${system}.nix-compile     (runs on `nix flake check`)
#   - devShells integration            (pre-commit hook auto-installed)
#   - packages.${system}.nix-compile-hook
#
# Usage:
#
#   {
#     inputs.nix-compile.url = "github:straylight/nix-compile";
#
#     outputs = inputs: inputs.flake-parts.lib.mkFlake { inherit inputs; } {
#       imports = [ inputs.nix-compile.flakeModules.default ];
#
#       nix-compile = {
#         enable = true;
#         profile = "standard";
#         paths = [ "nix" "lib" ];
#         pre-commit.enable = true;
#       };
#     };
#   }
#

{ lib, flake-parts-lib, ... }:

let
  inherit (lib) mkOption mkEnableOption types mkIf;
in
{
  options.nix-compile = {
    enable = mkEnableOption "nix-compile static analysis";

    profile = mkOption {
      type = types.enum [ "strict" "standard" "minimal" "nixpkgs" "security" ];
      default = "standard";
      description = ''
        Analysis profile:
        - strict: Full aleph conventions (lisp-case, Dhall)
        - standard: Sensible defaults
        - minimal: Essential safety only
        - nixpkgs: nixpkgs contribution guidelines
        - security: Security-focused
      '';
    };

    layout = mkOption {
      type = types.enum [ "straylight" "flake-parts" "nixpkgs" "nixos" "none" ];
      default = "none";
      description = ''
        Directory layout convention to enforce:
        - straylight: nix/modules/{flake,nixos,home}/, nix/packages/
        - flake-parts: modules/, packages/, overlays/
        - nixpkgs: pkgs/by-name/XX/name/package.nix
        - nixos: hosts/, modules/, users/
        - none: No layout enforcement
      '';
    };

    paths = mkOption {
      type = types.listOf types.str;
      default = [ "." ];
      example = [ "nix" "lib" "modules" ];
      description = "Paths to analyze (relative to flake root).";
    };

    pre-commit.enable = mkEnableOption "git pre-commit hook installation";
  };

  config = { config, inputs, self, ... }:
    let
      cfg = config.nix-compile;
    in
    mkIf cfg.enable {
      perSystem = { pkgs, system, ... }:
        let
          nix-compile = inputs.nix-compile.packages.${system}.default or
            (throw "nix-compile.packages.${system}.default not found in inputs");

          pathArgs = lib.escapeShellArgs cfg.paths;
          layoutArg = if cfg.layout == "none" then "" else "-l ${cfg.layout}";

          # ── check derivation ──────────────────────────────────────────────
          check = pkgs.runCommand "nix-compile" {
            nativeBuildInputs = [ nix-compile ];
          } ''
            cd ${self}
            nix-compile -p ${cfg.profile} ${layoutArg} ${pathArgs}
            touch $out
          '';

          # ── pre-commit hook ───────────────────────────────────────────────
          hook = pkgs.writeShellApplication {
            name = "nix-compile-hook";
            runtimeInputs = [ nix-compile pkgs.git ];
            text = ''
              # nix-compile pre-commit hook
              # Profile: ${cfg.profile}
              # Layout: ${cfg.layout}

              staged=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.(nix|sh|bash)$' || true)

              if [ -z "$staged" ]; then
                exit 0
              fi

              echo "nix-compile: checking staged files..."

              # shellcheck disable=SC2086
              if nix-compile -p ${cfg.profile} ${layoutArg} $staged; then
                echo "nix-compile: ✓ clean"
              else
                echo ""
                echo "nix-compile: ✗ blocked"
                echo "Use --no-verify to bypass."
                exit 1
              fi
            '';
          };

          # ── shell hook ────────────────────────────────────────────────────
          shellHook = ''
            if [ -d .git ]; then
              mkdir -p .git/hooks
              cat > .git/hooks/pre-commit << 'HOOK'
            #!/usr/bin/env bash
            set -euo pipefail
            if command -v nix-compile-hook &>/dev/null; then
              exec nix-compile-hook
            elif command -v nix-compile &>/dev/null; then
              exec nix-compile -p ${cfg.profile} ${pathArgs}
            else
              echo "warn: nix-compile not in PATH, skipping check"
            fi
            HOOK
              chmod +x .git/hooks/pre-commit
            fi
          '';

        in
        {
          checks.nix-compile = check;

          packages.nix-compile-hook = hook;

          devShells.nix-compile = pkgs.mkShell {
            name = "nix-compile";
            packages = [ nix-compile hook ];
            shellHook = lib.optionalString cfg.pre-commit.enable shellHook;
          };
        };
    };
}
