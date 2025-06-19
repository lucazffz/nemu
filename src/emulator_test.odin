package nemu

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

TEST_ROMS_DIRECTORY_PATH :: #config(TEST_ROMS_DIRECTORY_PATH, "./test_roms")
VERBOSE_LOGGING :: #config(VERBOSE_LOGGING, false)

fail :: proc(t: ^testing.T, msg: string, loc := #caller_location) {
	if msg != "" {
		log.error("FAIL:", msg, location = loc)
	} else {
		log.error("FAIL", location = loc)
	}
}

failf :: proc(t: ^testing.T, format: string, args: ..any, location := #caller_location) {
	log.errorf(format, ..args, location = location)
}


@(test)
test_cpu :: proc(t: ^testing.T) {
	// run the nestest.nes test rom
	console := console_make()
	console_init(console)
	mapper := mapper_make()
	defer console_delete(console)
	defer mapper_delete(mapper)

	console.mapper = mapper


	rom_file_path := TEST_ROMS_DIRECTORY_PATH + "/other/nestest.nes"
	data, err := os.read_entire_file_or_err(rom_file_path)
	if err != nil {
		failf(t, "FAIL: could not open file '%s', %v", rom_file_path, err)
		return
	}
	defer delete(data)

	rom := ines_nes20_from_bytes(data)
	mapper->fill_from_ines_rom(rom)

	if err := console_cpu_reset(console, 0xc000); err != nil {
		err := err.?
		failf(t, "FAIL: could not reset CPU, %v", err.type, location = err.loc)
		return

	}

	for {
		when VERBOSE_LOGGING {
			log.infof(
				"[%04d] %s",
				console.cpu.instruction_count + 1,
				console_state_to_string(console),
			)
		}

		if _, instr, err := console_cpu_step(console); err != nil {
			err := err.?
			failf(
				t,
				"FAIL: error executing instruction %d (%s) \n state: %s",
				console.cpu.instruction_count + 1,
				err.type,
				console_state_to_string(console),
				location = err.loc,
			)

			return
		} else {
			if instr.type == .JAM do break
		}
	}

	// legal instructions
	if status_byte, err := console_read_from_address(console, 0x0003); err != nil {
		err := err.?
		failf(t, "FAIL: error reading test status byte at $0002, %v", err.type, location = err.loc)
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
		failf(t, "FAIL: error reading test status byte at $0003, %v", err.type, location = err.loc)
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

