package emulator

import "../utils"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:slice"
import "core:strings"

SUPPORTED_MAPPERS :: []int{0}

Console :: struct {
	cpu:         CPU,
	ppu:         PPU,
	// apu:    APU,
	// 2 KB of internal ram ($0000 - $07FF)
	ram:         []u8,
	// cycles: int,
	// stalls: int,
	mapper:      Mapper,
	cycle_count: int,
	controller1: Controller,
	controller2: Controller,
}

CPU_RAM_INTERVAL :: utils.Interval(u16){0x0000, 0x1fff, .Closed} // 2KB ram mirrored 4 times

// given in ppu address space
PPU_PATTERN_TABLE_INTERVAL :: utils.Interval(u16){0x0000, 0x1fff, .Closed}
PPU_VRAM_INTERVAL :: utils.Interval(u16){0x2000, 0x2fff, .Closed}
// $3000 - $3eff is unused
PPU_PALLETTE_RAM_INTERVAL :: utils.Interval(u16){0x3f00, 0x3f1f, .Closed}

// seperate own address space
PPU_OAM_INTERVAL :: utils.Interval(u8){0x00, 0xff, .Closed}

// allocate memory for console
// will not initialize default values, use console_init
@(require_results)
console_make :: proc(
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	console: ^Console,
	err: runtime.Allocator_Error,
) #optional_allocator_error {
	// dont check error, know that intervals are closed
	ppu_palette_size := utils.interval_size(PPU_PALLETTE_RAM_INTERVAL)
	ppu_oam_size := utils.interval_size(PPU_OAM_INTERVAL)
	cpu_ram_size := utils.interval_size(CPU_RAM_INTERVAL)
	ppu_vram_size := utils.interval_size(PPU_VRAM_INTERVAL)

	console = new(Console, allocator, loc) or_return

	// pattern table and nametable are stored in cartridge (mapper) so
	// dont need to allocate them here
	console.ppu.palette = make_slice([]u8, ppu_palette_size, allocator, loc) or_return
	console.ppu.oam.raw_data = make_slice([]u8, ppu_oam_size, allocator, loc) or_return
	console.ppu.vram = make_slice([]u8, ppu_vram_size, allocator, loc) or_return
	console.ppu.pixel_buffer = make_slice([]Color, 256 * 240, allocator, loc) or_return
	console.ram = make_slice([]u8, cpu_ram_size, allocator, loc) or_return

	return
}

// free memory allocated to console
console_delete :: proc(
	console: ^Console,
	allocator := context.allocator,
	loc := #caller_location,
) -> runtime.Allocator_Error {
	delete_slice(console.ram, allocator, loc) or_return
	delete_slice(console.ppu.oam.raw_data, allocator, loc) or_return
	delete_slice(console.ppu.palette, allocator, loc) or_return
	delete_slice(console.ppu.vram, allocator, loc) or_return
	// delete_slice(console.ppu.pixel_buffer, allocator, loc) or_return
	free(console) or_return
	return .None
}

console_set_program_counter :: proc(console: ^Console, address: u16) {
	console.cpu.pc = address
}

console_initialize_with_mapper :: proc(console: ^Console, mapper: Mapper) {
	// @note must reassign memory pointers if want to intialize new cpu and ppu
	// in console, do like this instead:
	console.cpu.sp = 0xfd
	console.cpu.pc = 0xc000
	console.cpu.status = {.IF}
	console.cpu.instruction_count = 0

	// vblank and sprite overflow often set after power-up
	// console.ppu.mmio_register_bank.ppustatus._unused = 0x10

	console.mapper = mapper
}

console_vet_ines :: proc(ines: iNES20) -> Maybe(Error) {
	if !slice.contains(SUPPORTED_MAPPERS, ines.header.mapper_number) {
		return errorf(
			.Mapper_Number_Not_Supported,
			"mapper %d is not supported",
			ines.header.mapper_number,
		)
	}

	if ines.header.tv_system != .NTSC {
		return errorf(
			.TV_System_Not_Supported,
			"TV system %v is not supported, will assume NTSC",
			ines.header.tv_system,
		)
	}

	if _, ok := ines.header.console_type.(Nintendo_Entertainment_System); !ok {
		return errorf(
			.Console_System_Not_Supported,
			"console system %v is not supported",
			ines.header.console_type,
		)
	}

	if ines.header.cpu_ppu_timing_mode != .RP2C02 {
		return errorf(
			.CPU_PPU_Timing_Mode_Not_Supported,
			"timing mode %v is not supported, will assume RP2C02",
			ines.header.cpu_ppu_timing_mode,
		)
	}

	return ines_vet(ines)
}

console_execute_clk_cycle :: proc(
	console: ^Console,
) -> (
	frame_complete: bool,
	cpu_complete: bool,
	err: Maybe(Error),
) {

	frame_complete = ppu_execute_clk_cycle(console)
	if console.cycle_count % 3 == 0 {
		cpu_complete, err = cpu_execute_clk_cycle(console)
	}

	console.cycle_count += 1
	return
}

console_reset :: proc(console: ^Console) -> Maybe(Error) {
	console.cpu.interrupt = .Reset
	complete: bool
	for !complete {
		_, complete = console_execute_clk_cycle(console) or_return

	}

	return nil
}

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
	case 0x2000 ..< 0x4000:
		// PPU I/O registers
		// registers are mirrored every 8 bytes from $2008-$3fff
		address_offset := u8(address & 0x7)
		ppu_write_to_mmio_register(console, data, address_offset) or_return
	case 0x4000 ..< 0x4020:
		// APU and I/O registers
		switch address {
		case 0x4014:
			// use the address high byte
			ppu_write_to_oamdma(console, u8(address >> 8))
		case 0x04016:
			controller_write(&console.controller1, data)
			controller_write(&console.controller2, data)
		}
	case 0x4020 ..< 0x6000:
		// expansion ROM
		err = errorf(
			.Invalid_Address,
			"cannot write to $04X, expansion ROM not supported ($4020-$5FFF)",
			address,
		)
	case 0x6000 ..= 0xffff:
		// mapper
		mapper_write_to_cpu_address_space(console.mapper, address, data) or_return
	case:
		panic(fmt.tprintf("invalid address $%04X", address))
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
		address_offset := u8(address & 0x7)
		data = ppu_read_from_mmio_register(console, address_offset) or_return
	case 0x4000 ..< 0x4020:
		// APU and I/O registers
		switch address {
		case 0x4014:
			err = error(.Write_Only, "OAMDMA register at address $4014 is write-only")
		case 0x4016:
			data = controller_read(&console.controller1)
		case 0x417:
			data = controller_read(&console.controller2)
		}

	case 0x4020 ..< 0x6000:
		// expansion ROM
		err = errorf(
			.Unallocated_Memory,
			"cannot read from $%04X, expansion ROM not supported ($4020-$5FFF)",
			address,
		)
	case 0x6000 ..= 0xffff:
		// mapper
		data = mapper_read_from_cpu_address_space(console.mapper, address) or_return
	case:
		panic(fmt.tprintf("invalid address $%04X", address))
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

