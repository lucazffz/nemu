package nemu

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "emulator"

ASSETS_DIRECTORY_PATH :: #config(ASSETS_DIRECTORY_PATH, #directory + "../assets")

default_context: runtime.Context

console: emulator.Console

main :: proc() {
	logger := log.create_console_logger(.Info)
	defer log.destroy_console_logger(logger)
	context.logger = logger

	// setup tracking allocator in debug mode and print unfreed allocations
	// on termination
	when ODIN_DEBUG {
		context.logger.lowest_level = .Debug

		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				// use temp allocator as to not interfere with the tracking allocator
				if builder, err := strings.builder_make_none(context.temp_allocator); err == nil {
					fmt.sbprintfln(
						&builder,
						"%v allocations not freed during termination:",
						len(track.allocation_map),
					)

					for _, entry in track.allocation_map {
						fmt.sbprintfln(&builder, " - %v bytes @ %v", entry.size, entry.location)
					}

					log.warn(strings.to_string(builder))
				} else {
					log.error("could not print unfreed allocations", err)
				}

				mem.tracking_allocator_destroy(&track)
			}
		}
	}

	default_context = context

	ppu: emulator.PPU


	i: u8 = 6
	ppu.mmio_register_bank.ppuctrl.nametable_base_address = i

	byt: u8 = u8(ppu.mmio_register_bank.ppuctrl)

	err := emulator.error(.Read_Only, "some error")
	emulator.error_log(err, .Warning)

	fmt.println(ppu.mmio_register_bank.ppuctrl.nametable_base_address)
	// fmt.println(byt)
	// log.warn("WARNING: hej")

}

