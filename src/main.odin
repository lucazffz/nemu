package nemu

import runtime "base:runtime"
import fmt "core:fmt"
import log "core:log"
import mem "core:mem"
import strings "core:strings"

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

	fmt.println("Hello World")


	console = console_make()
	console_init(console)
	console_delete(console)
}

