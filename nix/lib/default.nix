# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                                                         // nix-compile // lib
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
#     "Case was twenty-four. At twenty-two, he'd been a cowboy."
#
#                                                                  — Neuromancer
#
# Helper functions for non-flake-parts users.
#
# Usage:
#
#   let
#     nix-compile = inputs.nix-compile;
#     nc = nix-compile.lib;
#   in {
#     checks.x86_64-linux.nix-compile = nc.mkCheck {
#       inherit pkgs;
#       nix-compile = nix-compile.packages.x86_64-linux.default;
#       src = ./.;
#       profile = "standard";
#       paths = [ "nix" ];
#     };
#
#     devShells.default = pkgs.mkShell {
#       shellHook = nc.mkPreCommitHook {
#         profile = "standard";
#         paths = [ "nix" ];
#       };
#     };
#   }
#

{ lib }:

{
  # ──────────────────────────────────────────────────────────────────────────────
  #                                                                   // mkCheck
  # ──────────────────────────────────────────────────────────────────────────────

  mkCheck =
    { pkgs
    , nix-compile
    , src
    , profile ? "standard"
    , paths ? [ "." ]
    , name ? "nix-compile"
    }:
    pkgs.runCommand name {
      nativeBuildInputs = [ nix-compile ];
    } ''
      cd ${src}
      nix-compile -p ${profile} ${lib.escapeShellArgs paths}
      touch $out
    '';

  # ──────────────────────────────────────────────────────────────────────────────
  #                                                                    // mkHook
  # ──────────────────────────────────────────────────────────────────────────────

  mkHook =
    { pkgs
    , nix-compile
    , profile ? "standard"
    , paths ? [ "." ]
    }:
    pkgs.writeShellApplication {
      name = "nix-compile-hook";
      runtimeInputs = [ nix-compile pkgs.git ];
      text = ''
        staged=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.(nix|sh|bash)$' || true)
        [ -z "$staged" ] && exit 0
        echo "nix-compile: checking staged files..."
        # shellcheck disable=SC2086
        if nix-compile -p ${profile} $staged; then
          echo "nix-compile: ✓ clean"
        else
          echo "nix-compile: ✗ blocked (--no-verify to bypass)"
          exit 1
        fi
      '';
    };

  # ──────────────────────────────────────────────────────────────────────────────
  #                                                         // mkPreCommitHook
  # ──────────────────────────────────────────────────────────────────────────────

  mkPreCommitHook =
    { profile ? "standard"
    , paths ? [ "." ]
    }:
    let
      paths-str = lib.escapeShellArgs paths;
    in ''
      # nix-compile pre-commit hook installation
      if [ -d .git ] && [ ! -x .git/hooks/pre-commit ]; then
        mkdir -p .git/hooks
        cat > .git/hooks/pre-commit << 'EOF'
      #!/usr/bin/env bash
      set -euo pipefail
      staged=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.(nix|sh|bash)$' || true)
      [ -z "$staged" ] && exit 0
      echo "nix-compile: checking..."
      # shellcheck disable=SC2086
      nix-compile -p ${profile} $staged
      EOF
        chmod +x .git/hooks/pre-commit
        echo "nix-compile: pre-commit hook installed"
      fi
    '';

  # ──────────────────────────────────────────────────────────────────────────────
  #                                                           // mkIntegration
  # ──────────────────────────────────────────────────────────────────────────────

  mkIntegration =
    { pkgs
    , nix-compile
    , src
    , profile ? "standard"
    , paths ? [ "." ]
    }:
    let
      paths-str = lib.escapeShellArgs paths;

      check = pkgs.runCommand "nix-compile" {
        nativeBuildInputs = [ nix-compile ];
      } ''
        cd ${src}
        nix-compile -p ${profile} ${paths-str}
        touch $out
      '';

      hook = pkgs.writeShellApplication {
        name = "nix-compile-hook";
        runtimeInputs = [ nix-compile pkgs.git ];
        text = ''
          staged=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.(nix|sh|bash)$' || true)
          [ -z "$staged" ] && exit 0
          # shellcheck disable=SC2086
          exec nix-compile -p ${profile} $staged
        '';
      };

      shellHook = ''
        if [ -d .git ]; then
          ln -sf ${hook}/bin/nix-compile-hook .git/hooks/pre-commit 2>/dev/null || true
        fi
      '';

    in { inherit check hook shellHook; };
}
