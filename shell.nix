{
  pkgs ? import <nixpkgs> { },
}:
pkgs.mkShell {
  name = "nemu-build-env";

  nativeBuildInputs = with pkgs; [
    gcc
    python314
    odin
    ols
    glsl_analyzer
    git
    cc65
  ];

  buildInputs = with pkgs; [
    libGL
    xorg.libX11
    xorg.libX11.dev
    xorg.libXi
    xorg.libXcursor
    alsa-lib
  ];

  shellHook = ''
    echo "Entering nemu dev shell"
  '';
}
