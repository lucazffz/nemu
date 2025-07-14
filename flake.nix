{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      with pkgs;
      {
        devShells.default = mkShell {
          nativeBuildInputs = [
            raylib
            xorg.libX11
            xorg.libXrandr
            xorg.libXinerama
            xorg.libXcursor
            xorg.libXi
          ];

          buildInputs = with pkgs; [
            odin
            ols # provides both ols and odinfmt
            python314
            pyright
            black
            gcc
            git
            cc65 # C compiler for 6502 processor family
            glsl_analyzer
          ];

          shellHook = ''
            echo "Entering Nemu dev shell"
          '';
        };
      }
    );
}
