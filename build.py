import os
import sys

# Check that the given platform is supported
supported_platforms = ["linux", "windows"]

if not sys.platform in supported_platforms:
    sys.exit(
        "ERROR: {platform} is not officially supported. Supported platforms are {supported}".format(
            platform=sys.platform, supported=supported_platforms
        )
    )

# Read args to determine build mode (debug, release)
build_mode = "release"
valid_args = ["release", "debug"]

if len(sys.argv) == 2:
    arg = sys.argv[1]
    if arg not in valid_args:
        sys.exit("ERROR: {arg} is not a valid argument, expected {valid}".format(arg=arg, valid=valid_args))
    else:
        build_mode = arg

# Determine the build path based on platform
out_name = ""
build_dir_path = os.curdir + "/build/"
if sys.platform == "linux":
    out_name = "nemu_linux_amd64_" + build_mode + ".bin"
elif sys.platform == "windows":
    out_name = "nemu_windows_amd64_" + build_mode + ".exe"

odin_build_flags_path = "-out:" + build_dir_path + out_name

# Determine platform specific build flags
odin_build_flags_platform = ""
if sys.platform == "linux":
    odin_build_flags_platform = "-target:linux_amd64 "
elif sys.platform == "windows":
    odin_build_flags_platform = "-target:windows_amd64 "


# Determine build flags based on build mode
odin_build_flags_mode = ""
if build_mode == "release":
    vet = "-vet-packages:nemu,emulator,utils -vet -vet-cast -vet-tabs -vet-semicolon "
    odin_build_flags_mode = "-no-bounds-check -disable-assert -ignore-warnings " + vet
elif build_mode == "debug":
    odin_build_flags_mode = "-debug "

# Assemble all build flags
odin_build_flags_base = "-o:speed -build-mode:exe "
odin_build_flags = (
    odin_build_flags_base
    + odin_build_flags_mode
    + odin_build_flags_platform
    + odin_build_flags_path
)

# Create build dir if not exists
if not os.path.exists(build_dir_path):
    print("--- Created build directory at '{path}'".format(path=build_dir_path))
    os.mkdir(build_dir_path)

# Compile project
# @note should probably use subprocess.run instead but couldnt
# get that to work with odin compiler
print("--- Compiling...")
status = os.system("odin build src " + odin_build_flags)
if status != 0:
    print("ERROR: Could not create executable")
else:
    print("--- Created executable at '{path}'".format(path=build_dir_path + out_name))
