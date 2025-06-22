package emulator

import "../utils"
import "base:runtime"
import "core:fmt"
import "core:strings"

Console :: struct {
	cpu:    CPU,
	ppu:    PPU,
	// apu:    APU,
	// 2 KB of internal ram ($0000 - $07FF)
	ram:    []u8,
	// cycles: int,
	// stalls: int,
	mapper: Mapper,
}

// allocate memory for console
// will not initialize default values, use console_init
@(require_results)
console_make :: proc(
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	console: Console,
	err: runtime.Allocator_Error,
) #optional_allocator_error {
	// dont check error, know that interval is closed
	ram_size := utils.interval_size(CPU_INTERNAL_RAM_INTERVAL)
	ram := make_slice([]u8, ram_size, allocator, loc) or_return
	// console = new(Console, allocator, loc) or_return
	console.ram = ram

	return
}

// free memory allocated to console
console_delete :: proc(
	console: Console,
	allocator := context.allocator,
	loc := #caller_location,
) -> runtime.Allocator_Error {
	delete_slice(console.ram, allocator, loc) or_return
	return .None
}

console_set_program_counter :: proc(console: ^Console, address: u16) {
	console.cpu.pc = address
}

console_initialize_with_mapper :: proc(console: ^Console, mapper: Mapper) {
	console.cpu = {
		x                 = 0,
		y                 = 0,
		acc               = 0,
		sp                = 0xfd,
		pc                = 0xc000,
		status            = {.IF},
		interrupt         = .None,
		instruction_count = 0,
		cycle_count       = 0,
		stall_count       = 0,
	}

	console.mapper = mapper
}


@(private = "file")
CPU_INTERNAL_RAM_INTERVAL :: utils.Interval(u16){0x0000, 0x1FFF, .Closed} // 2KB ram mirrored 4 times

@(require_results)
console_write_to_address :: proc(
	console: ^Console,
	address: u16,
	data: u8,
) -> (
	err: Maybe(Error),
) {
	switch address {
	case 0x0000 ..< 0x2000:
		// cpu internal RAM, 2 KB
		// RAM is mirrored every 2 KB from $0800-$1fff
		console.ram[address & 0x07ff] = data
	case 0x2000 ..< 4000:
		// PPU I/O registers
		// registers are mirrored every 8 bytes from $2008-$3fff
		address := address % 8
	case 0x4000 ..< 0x4020:
	// assert(false, "apu not supported")
	// APU and I/O registers
	case 0x4020 ..< 0x6000:
		// expansion ROM
		err = errorf(
			.Invalid_Address,
			"cannot write to $02X, expansion ROM not supported ($4020-$6000)",
		)
	case 0x6000 ..= 0xffff:
		// mapper
		mapper_write_to_address(console.mapper, address, data) or_return
	case:
		panic(fmt.tprintf("invalid address $%02X", address))
	}

	return
}

@(require_results)
console_read_from_address :: proc(
	console: ^Console,
	address: u16,
) -> (
	data: u8,
	err: Maybe(Error),
) {
	switch address {
	case 0x0000 ..< 0x2000:
		// cpu internal RAM, 2 KB
		// RAM is mirrored every 2 KB from $0800-$1fff
		data = console.ram[address & 0x07ff]
	case 0x2000 ..< 0x4000:
		// PPU I/O registers
		// registers are mirrored every 8 bytes from $2008-$3fff
		address := address % 8
	case 0x4000 ..< 0x4020:
	// APU and I/O registers
	case 0x4020 ..< 0x6000:
		// expansion ROM
		err = errorf(
			.Invalid_Address,
			"cannot read from $02X, expansion ROM not supported ($4020-$6000)",
		)
	case 0x6000 ..= 0xffff:
		// mapper
		data = mapper_read_from_address(console.mapper, address) or_return
	case:
		panic(fmt.tprintf("invalid address $%02X", address))
	}
	return
}

@(require_results)
console_state_to_string :: proc(console: ^Console) -> string {
	opcode, _ := console_read_from_address(console, console.cpu.pc)
	instruction := get_instruction_from_opcode(opcode)
	cpu := console.cpu

	num_of_operands := instruction.byte_size - 1
	op_str: string = "     "

	// instruction have either 0, 1 or 2 operand bytes
	operand1, _ := console_read_from_address(console, console.cpu.pc + 1)
	operand2, _ := console_read_from_address(console, console.cpu.pc + 2)
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
		rel_addr, _ := console_read_from_address(console, console.cpu.pc + 1)
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
		"%04X  %02X %s  %s  A:%02X X:%02X Y:%02X P:%02X SP:%02X CYC:%04d",
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

