{
  description = "My Sandboxed Pi Agent";

  nixConfig = {
    extra-substituters = [ "https://cache.numtide.com" ];
    extra-trusted-public-keys = [ "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    llm-agents.url = "github:numtide/llm-agents.nix";
  };

  outputs =
    {
      self,
      nixpkgs,
      llm-agents,
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
      };

      shellInputs = with pkgs; [
        bash
        bubblewrap
        bun
        llm-agents.packages.${system}.pi
        llm-agents.packages.${system}.tuicr
        zellij
        git
        wl-clipboard
        uv
        nodejs
        rtk
      ];

      sandbox = pkgs.writeShellApplication {
        name = "sandbox";
        runtimeInputs = shellInputs;
        text = ''
          export LAYOUT_KDL="${./default/layout.kdl}"
          export TUICR_CONFIG="${./default/tuicr/config.toml}"
          export PI_SETTINGS_JSON="${./default/settings.json}"
        '' + builtins.readFile ./sandbox.sh;
      };
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        buildInputs = shellInputs;
      };
      apps.${system}.default = {
        type = "app";
        program = "${sandbox}/bin/sandbox";
      };
      formatter.${system} = pkgs.writeShellApplication {
        name = "nixfmt-wrapper";
        runtimeInputs = [
          pkgs.findutils
          pkgs.nixfmt
        ];
        text = ''
          if [ $# -eq 0 ]; then
            find . -name '*.nix' -exec nixfmt {} +
          else
            nixfmt "$@"
          fi
        '';
      };
    };
}
