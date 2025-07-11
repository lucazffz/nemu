package emulator

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

TEST_ROMS_DIRECTORY_PATH :: #config(TEST_ROMS_DIRECTORY_PATH, #directory + "../../test/test_roms")

fail :: proc(t: ^testing.T, msg: string, loc := #caller_location) {
	if msg != "" {
		log.error("FAIL:", msg, location = loc)
	} else {
		log.error("FAIL", location = loc)
	}
}

failf :: proc(t: ^testing.T, format: string, args: ..any, loc := #caller_location) {
	log.errorf(format, ..args, location = loc)
}

@(test)
test_cpu :: proc(t: ^testing.T) {
	cartridge, err := cartridge_make_from_filename(TEST_ROMS_DIRECTORY_PATH + "/other/nestest.nes")
	if err != nil {
		failf(t, "FAIL: %s", err.?.msg)
		return
	}

	console := console_make()
	defer console_delete(console)

	console_initialize_with_cartridge(console, cartridge)
	_ = console_reset(console)
	console_set_program_counter(console, 0xc000)

	execute_instruction: {
		complete: bool = true
		err: Maybe(Error)
		for {
			if complete {
				log.debugf(
					"[%04d] %s",
					console.cpu.instruction_count,
					console_state_to_string(console),
				)
			}

			if complete, err = cpu_execute_clk_cycle(console); err != nil {
				err := err.?
				failf(
					t,
					"FAIL: error executing instruction %d (%s) \n state: %s",
					console.cpu.instruction_count,
					err.type,
					console_state_to_string(console),
					loc = err.loc,
				)

				return
			} else {
				if console.cpu.current_instruction.?.type == .JAM && complete do break
			}
		}
	}

	// legal instructions
	if status_byte, err := console_read_from_address(console, 0x0003); err != nil {
		err := err.?
		failf(t, "FAIL: error reading test status byte at $0002, %v", err.type, loc = err.loc)
		return
	} else {
		testing.expectf(
			t,
			status_byte == 0x0000,
			"FAIL: expected status byte at $0002 to equal 00, got %02x (see nestesxt.txt for failure code meanings)",
			status_byte,
		)
	}

	// illegal instructions
	if status_byte, err := console_read_from_address(console, 0x0002); err != nil {
		err := err.?
		failf(t, "FAIL: error reading test status byte at $0003, %v", err.type, loc = err.loc)
		return
	} else {
		testing.expectf(
			t,
			status_byte == 0x0000,
			"FAIL: expected status byte at $0003 to equal 00, got %02x (see nestesxt.txt for failure code meanings)",
			status_byte,
		)
	}
}

