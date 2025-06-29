# source $stdenv/setup

# directory paths
SRC = src
BUILD = build
BIN = bin
TOOLS = tools
SHADERS = $(SRC)/shaders
ASSETS = $(SRC)/assets

ODIN_FLAGS = -out:$(BIN)/nemu
SOKOL_SHDC_FLAGS = -i $(SHADERS)/shader.glsl -o $(SHADERS)/shader.odin -l glsl430 -f sokol_odin 

# .PHONY: all
# all: 
# 	cd src/vendor/sokol-odin/sokol; ./build_clibs_linux.sh
# 	make build

.PHONY: build
build:
	mkdir -p $(BUILD)
	mkdir -p $(BIN)
	odin build $(SRC) $(ODIN_FLAGS)

.PHONY: run
run: build
	$(BIN)/nemu

.PHONY: test
test:
	odin test $(SRC)/emulator -out:$(BUILD)/test -debug


# .PHONY: install
# install:
# 	mv sokol ${out}/
# 	mkdir -p ${out}/bin
# 	cp -r build ${out}/bin
