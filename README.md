# Nemu
Nemu is a cross-platform emulator for the Nintendo Entertainment System with support for Linux and Windows. It has support for the NTSC version of the NES, making it capable of emulating ROMs released for the North American and Japanese markets.

It has support for the following mappers: 
* NROM (Mapper 0)
* MMC1 (Mapper 1)
* MMC2 (Mapper 2)
* MMC3 (Mapper 3)
* MMC4 (Mapper 4)

To see which ROMs are playable, refer to this list: [NES Mapper List](https://tuxnes.sourceforge.net/nesmapper.txt)

# Installation
You first need to install the [Odin compiler](https://odin-lang.org/docs/install/) together [Python interpreter](https://www.python.org/downloads/). Check your specific package manager. 

Nemu is using [Raylib](https://www.raylib.com/) as its media layer, which is statically linked into the binary. It is included within Odin's vendor collection, so no need to install it separately.

**Nix**: If you are using Nix, just run `nix develop` after cloning the repository to enter a development environment with all dependencies installed.

Clone the repository and enter the directory.
```
git clone https://github.com/lucazffz/nemu
cd nemu
```

Run the build script (support for Windows and Linux).
```
python build.py
```

The executable will now be accessible within the created build directory. The executable name is based on your specific platform and system architecture (ex. nemu_linux_x86-64_release.bin).

**Note**: While the emulator officially only supports Windows and Linux, there is no reason why it would not work on macOS. However, to build it on macOS, you would need to use the Odin compiler directly and not the Python build script. This should be as simple as executing `odin build ./src -o:speed -out:nemu -ignore-warnigs`.

# Usage
Nemu includes a small terminal interface. To run a ROM, simply execute:
```
[path to executable] [path to rom]
```

To list usage information, execute:
```
[path to executable] --help
```

## Controls
Nemu currently does not allow you to remap controls. It has support for one-user keyboard input and up to two controllers. While only _Xbox Wireless Controller Series 2_ has been tested, any controller should work.

Only the original NES controller keymap is supported.

| Key                   | Keyboard    | Controller  | 
| ----------------------|-------------|------------ |
| Up, Down, Left, Right | Arrow Keys  | D-pad       |
| Select                | 1           | View        |
| Start                 | 2           | Menu        |
| A                     | X           | A           |
| B                     | Z           | X           |

## Debug UI
Nemu includes a debug interface that can be activated using **F3**.

# Known Issues
There are plenty of known issues regarding emulation accuracy as Nemu is currently not the most stable of emulators.
* When jumping in Contra, the character's spin animation is wrong. Looks like the sprites are selected incorrectly, leading to clipping. It might be an address overflow-related issue. The issue is also noticeable in Super Mario 3 and Super Mario 2 (logs). 
* Input does not work in Paperboy
* PPU strange top left row of pixels
* Super C (using mapper 4) will crash due to out-of-range slice access. Probably a mapper 4 banking issue.
* Mapper 4 scanline counter is not incrementing properly, leading to a multitude of issues in games using the mapper. Observed in Super Mario Bros 3 and Kirby's Adventure.
* The APU pulse channel won't stop playing in the Super Mario 3 menu screen

# Documentation
This project was made possible by the tremendous community effort of documenting the NES hardware behavior. Here are some great resources:

* [Nes Reference Guide (Wiki)](https://www.nesdev.org/wiki/NES_reference_guide)
* [6502 CPU Reference](https://www.cpcwiki.eu/index.php/MOS_6502)
