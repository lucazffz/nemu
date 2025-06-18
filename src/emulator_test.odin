package nemu

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

TEST_ROMS_DIRECTORY_PATH :: #config(TEST_ROMS_DIRECTORY_PATH, "./test_roms")
VERBOSE_LOGGING :: #config(VERBOSE_LOGGING, false)

@(test)
test_cpu :: proc(t: ^testing.T) {
	// run the nestest.nes test rom
	console := console_make()
	console_init(console)
	mapper := mapper_make()
	defer console_delete(console)
	defer mapper_delete(mapper)

	console.mapper = mapper

	rom_file_path := TEST_ROMS_DIRECTORY_PATH + "/cpu_test/nestest.nes"
	log_file_path := TEST_ROMS_DIRECTORY_PATH + "/cpu_test/nestest.log"
	data, log: []byte
	err: os.Error
	if data, err = os.read_entire_file_or_err(rom_file_path); err != nil {
		msg := fmt.tprintf("Error opening file '%s', %v", rom_file_path, err)
		testing.fail_now(t, msg)
	}
	defer delete(data)

	if log, err = os.read_entire_file_or_err(log_file_path); err != nil {
		msg := fmt.tprintf("Error opening file '%s', %v", log_file_path, err)
		testing.fail_now(t, msg)
	}
	defer delete(log)

	rom := ines_nes20_from_bytes(data)
	mapper->fill_from_ines_rom(rom)

	if err := console_cpu_reset(console, 0xc000); err != nil {
		msg := fmt.tprintf("Error resetting CPU, %v", err)
		testing.fail_now(t, msg)
	}

	num_of_instructions := 1200

	it := string(log)
	for line in strings.split_after_iterator(&it, "\n") {
		if num_of_instructions < 0 do break
		num_of_instructions -= 1

		console_state_str := console_state_to_string(console)
		when VERBOSE_LOGGING {
			fmt.printfln("[%04d] %s", console.cpu.instruction_count + 1, console_state_str)
		}

		// if (line[:73] != console_state_str) {
		// 	msg := fmt.tprintf(
		// 		"Expected state during instruction %d \n'%s', got \n'%s'",
		// 		console.cpu.instruction_count + 1,
		// 		line[:73],
		// 		console_state_str,
		// 	)
		// 	testing.fail_now(t, msg)
		// }


		if _, instr, err := console_cpu_step(console); err != nil {
			msg := fmt.tprintf(
				"Error executing instruction number %d [%s], %v",
				console.cpu.instruction_count + 1,
				instruction_to_string(instr),
				err,
			)
			testing.fail_now(t, msg)
		}

	}

	// legal instructions
	if status_byte, err := console_mem_read_from_address(console, 0x0200); err != nil {
		msg := fmt.tprintf("Error reading test status byte at address 0x0200, %v", err)
		testing.fail_now(t, msg)
	} else {
		testing.expectf(
			t,
			status_byte == 0x0000,
			"expected status byte $0200 to equal 00, got %02x (see nestesxt.txt for failure code meanings)",
			status_byte,
		)
	}

	// illegal instructions
	if status_byte, err := console_mem_read_from_address(console, 0x0300); err != nil {
		msg := fmt.tprintf("Error reading test status byte at address 0x0300, %v", err)
		testing.fail_now(t, msg)
	} else {
		testing.expectf(
			t,
			status_byte == 0x0000,
			"expected status byte $0300 to equal 00, got %02x (see nestesxt.txt for failure code meanings)",
			status_byte,
		)
	}
	// allocates using temp allocator
	console_state_to_string :: proc(console: ^Console) -> string {
		opcode, _ := console_mem_read_from_address(console, console.cpu.pc)
		instruction := get_instruction_from_opcode(opcode)
		cpu := console.cpu

		num_of_operands := instruction.byte_size - 1
		op_str: string = "     "

		// instruction have either 0, 1 or 2 operand bytes
		operand1, _ := console_mem_read_from_address(console, console.cpu.pc + 1)
		operand2, _ := console_mem_read_from_address(console, console.cpu.pc + 2)
		if num_of_operands == 1 {
			op_str = fmt.tprintf("%02X   ", operand1)
		} else if num_of_operands == 2 {
			op_str = fmt.tprintf("%02X %02X", operand1, operand2)
		}

		builder := strings.builder_make()
		defer strings.builder_destroy(&builder)
		type_str, _ := fmt.enum_value_to_string(instruction.type)
		strings.write_string(&builder, type_str)


		switch instruction.addressing_mode {
		case .Implied, .Accumulator:
			break
		case .Immediate:
			strings.write_string(&builder, fmt.tprintf(" #$%02X", operand1))
		case .Zeropage:
			strings.write_string(&builder, fmt.tprintf(" $%02X", operand1))
		case .Absolute:
			strings.write_string(&builder, fmt.tprintf(" $%02X%02X", operand2, operand1))
		case .Absolute_X:
		case .Absolute_Y:
		case .Zeropage_X:
		case .Zeropage_Y:
		case .Relative:
			rel_addr, _ := console_mem_read_from_address(console, console.cpu.pc + 1)
			jump_addr := u16(i16(console.cpu.pc) + 2 + i16(i8(rel_addr)))
			strings.write_string(&builder, fmt.tprintf(" $%04X", jump_addr))
		case .Indirect:
		case .Zeropage_Indirect_X:
		case .Zeropage_Indirect_Y:

		}

		#partial switch instruction.type {
		case .STA, .BIT:
			strings.write_string(&builder, fmt.tprintf(" = %02X", cpu.acc))
		case .STX:
			strings.write_string(&builder, fmt.tprintf(" = %02X", cpu.x))
		case .STY:
			strings.write_string(&builder, fmt.tprintf(" = %02X", cpu.y))
		}

		trailing_whitespace := strings.repeat(" ", 30 - len(builder.buf))
		defer delete(trailing_whitespace)

		strings.write_string(&builder, trailing_whitespace)
		instr_str := strings.to_string(builder)

		return fmt.tprintf(
			"%04X  %02X %s  %s  A:%02X X:%02X Y:%02X P:%02X SP:%02X CYC:%04X",
			// cpu.instruction_count + 1,
			cpu.pc,
			opcode,
			op_str,
			instr_str,
			cpu.acc,
			cpu.x,
			cpu.y,
			status_flags_to_byte(cpu.status, false),
			cpu.sp,
			cpu.cycle_count,
		)

	}
}

