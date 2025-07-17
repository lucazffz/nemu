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
        runtime_libs = with pkgs; [
          raylib
          wayland
          libxkbcommon
          libglvnd
          mesa
          xorg.libX11
          xorg.libXi
          xorg.libXcursor
          xorg.libXrandr
          xorg.libXinerama
        ];
      in
      with pkgs;
      {
        devShells.default = mkShell {
          buildInputs = runtime_libs;
          nativeBuildInputs = with pkgs; [
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

          # LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath runtime_libs;

          shellHook = ''
            echo "Entering Nemu dev shell"
          '';
        };
      }
    );
}
