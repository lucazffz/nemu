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
	// run the nestest.nes test rom
	rom_file_path := TEST_ROMS_DIRECTORY_PATH + "/other/nestest.nes"
	rom, err := os.read_entire_file_or_err(rom_file_path)
	if err != nil {
		failf(t, "FAIL: could not open file '%s', %v", rom_file_path, err)
		return
	}
	defer delete(rom)

	ines := get_ines_from_bytes(rom)

	if err := console_vet_ines(ines); err != nil {
		err := err.?
		failf(t, "FAIL: %s", err.msg, loc = err.loc)
		return
	}

	console := console_make()
	defer console_delete(console)

	mapper := mapper_make_from_ines(ines)
	defer mapper_delete(mapper)

	console_initialize_with_mapper(&console, mapper)
	_ = cpu_reset(&console)
	console_set_program_counter(&console, 0xc000)

	execute_instruction: {
		complete: bool = true
		err: Maybe(Error)
		for {
			if complete {
				log.debugf(
					"[%04d] %s",
					console.cpu.instruction_count,
					console_state_to_string(&console),
				)
			}

			if complete, err = cpu_execute_clk_cycle(&console); err != nil {
				err := err.?
				failf(
					t,
					"FAIL: error executing instruction %d (%s) \n state: %s",
					console.cpu.instruction_count,
					err.type,
					console_state_to_string(&console),
					loc = err.loc,
				)

				return
			} else {
				if console.cpu.current_instruction.?.type == .JAM && complete do break
			}
		}
	}

	// legal instructions
	if status_byte, err := console_read_from_address(&console, 0x0003); err != nil {
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
	if status_byte, err := console_read_from_address(&console, 0x0002); err != nil {
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

