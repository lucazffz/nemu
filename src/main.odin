package nemu

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"

ASSETS_DIRECTORY_PATH :: #config(ASSETS_DIRECTORY_PATH, "./assets")

default_context: runtime.Context

console: ^Console


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

	console := console_make()
	console_init(console)
	mapper := mapper_make()
	defer console_delete(console)
	defer mapper_delete(mapper)

	console.mapper = mapper


	if file, err := os.read_entire_file_or_err("../test_roms/cpu_test/nestest.nes"); err != nil {
		fmt.eprintln("could not read file: %s", err)
	} else {
		defer delete(file)
		if variant, ok := ines_determine_format_variant_from_bytes(file); ok {
			rom := ines_nes20_from_bytes(file)
			mapper->fill_from_ines_rom(rom)

		} else {
			fmt.eprintln("file not .nes file")
		}


	}


	error := console_cpu_reset(console, 0xc000)
	fmt.println(console.cpu.status)
	fmt.printfln("%x", status_flags_to_byte(console.cpu.status, false))
	assert(error == nil, "shit")
	// fmt.printfln("%x", console.cpu.pc)
	// fmt.println(console.cpu.cycle_count)

	for i := 0; i < 8900; i += 1 {
		instr, cycles, error := console_cpu_step(console)
		if error != nil {
			fmt.eprintln(error)
			return
		}

	}

	fmt.println(console.cpu.cycle_count)
	fmt.printfln("%x", status_flags_to_byte(console.cpu.status, false))
}

