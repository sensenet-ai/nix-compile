# Test: Cross-language type inference from Nix to bash
#
# When you write:
#   curl --connect-timeout "${timeout}"
# nix-compile should infer that `timeout` must be an integer in Nix.
{ pkgs, lib, config, ... }:
{
  # Script that uses curl with timeout - should infer timeout :: int
  packages.fetch-data = pkgs.writeShellApplication {
    name = "fetch-data";
    runtimeInputs = with pkgs; [ curl jq ];
    text = ''
      # These Nix interpolations should have their types inferred from bash context:
      #   ${config.timeout} -> used with --connect-timeout -> TInt
      #   ${config.retries} -> used with --retry -> TInt  
      #   ${config.output} -> used with -o -> TPath
      curl --connect-timeout "${config.timeout}" \
           --retry "${config.retries}" \
           -o "${config.output}" \
           "${config.url}"
      
      # jq --indent expects int
      jq --indent "${config.indentLevel}" . "${config.output}"
    '';
  };

  # Script that uses find with depth limits
  packages.search = pkgs.writeShellApplication {
    name = "search";
    runtimeInputs = with pkgs; [ findutils ];
    text = ''
      # ${config.maxDepth} and ${config.minDepth} should be TInt
      find "${config.searchPath}" \
           -maxdepth "${config.maxDepth}" \
           -mindepth "${config.minDepth}" \
           -name "${config.pattern}"
    '';
  };

  # Script using ssh 
  packages.deploy = pkgs.writeShellApplication {
    name = "deploy";
    runtimeInputs = with pkgs; [ openssh rsync ];
    text = ''
      # ${config.sshPort} -> TInt (from ssh -p)
      # ${config.sshKey} -> TPath (from ssh -i)
      # ${config.bwLimit} -> TInt (from rsync --bwlimit)
      ssh -p "${config.sshPort}" -i "${config.sshKey}" "${config.host}" "mkdir -p /app"
      rsync --bwlimit "${config.bwLimit}" -avz ./dist/ "${config.host}:/app/"
    '';
  };

  # Script with parallel execution
  packages.batch-process = pkgs.writeShellApplication {
    name = "batch-process";
    runtimeInputs = with pkgs; [ parallel ];
    text = ''
      # ${config.jobs} and ${config.jobTimeout} should be TInt
      find . -name "*.txt" | parallel -j "${config.jobs}" --timeout "${config.jobTimeout}" process {}
    '';
  };
}
