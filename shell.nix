{
  pkgs ? import <nixpkgs> { },
}:
pkgs.mkShell {
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

  buildInputs = with pkgs; [
    raylib
    glfw
    xorg.libX11
    xorg.libX11.dev
    xorg.libXi
    xorg.libXcursor
    libglvnd
    mesa
  ];

  shellHook = ''
    # Had to do this mess to get Odin to recognize Raylib.
    # Taken from: https://github.com/NixOS/nixpkgs/issues/348498
    # Could definitly be solved better, see link for multiple solutions.
    export LD_LIBRARY_PATH=${pkgs.xorg.libX11}/lib:${pkgs.xorg.libXrandr}/lib:${pkgs.xorg.libXinerama}/lib:${pkgs.xorg.libXcursor}/lib:${pkgs.xorg.libXi}/lib:${pkgs.raylib}/lib:${pkgs.mesa}/lib:${pkgs.libglvnd}/lib:$LD_LIBRARY_PATH
      export LIBGL_ALWAYS_SOFTWARE=1
      export DISPLAY=:0
      export XDG_SESSION_TYPE=x11
      export GDK_BACKEND=wayland
      export SDL_VIDEODRIVER=wayland
      echo "Entering Nemu dev shell"
  '';
}
