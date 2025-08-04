package emulator

import "base:runtime"
import "core:fmt"
import "core:strings"

ASSETS_DIR_PATH :: #directory + "assets/"

CPU_CLK_FREQUENCY :: 1789773.0
KB :: 1024 // one kibibyte

Console :: struct {
	cpu:         CPU,
	ppu:         PPU,
	apu:         APU,
	// 2 KB of internal ram ($0000 - $07FF)
	ram:         []u8,
	palette:     ^Palette,
	cartridge:   ^Cartridge,
	controller1: Controller,
	controller2: Controller,
	cycle_count: int,
	dma:         DMA,
}

// allocate memory for console
// will not initialize default values, use console_init
@(require_results)
console_make :: proc(
	palette: Maybe(^Palette) = nil,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	console: ^Console,
	err: runtime.Allocator_Error,
) #optional_allocator_error {
	cpu_ram_size := 2 * KB
	console = new(Console, allocator, loc) or_return

	// cpu doesnt need any allocation
	console.apu = apu_make(allocator, loc) or_return
	console.ppu = ppu_make(allocator, loc) or_return

	console.palette = palette.? or_else palette_make_default(allocator, loc) or_return

	// pattern table and nametable are stored in cartridge (mapper) so
	// dont need to allocate them here
	console.ram = make_slice([]u8, cpu_ram_size, allocator, loc) or_return


	return
}

// free memory allocated to console
console_delete :: proc(
	console: ^Console,
	allocator := context.allocator,
	loc := #caller_location,
) -> runtime.Allocator_Error {
	apu_delete(console.apu, allocator, loc) or_return
	ppu_delete(console.ppu, allocator, loc) or_return
	delete_slice(console.ram, allocator, loc) or_return
	palette_delete(console.palette, allocator, loc) or_return
	cartridge_delete(console.cartridge)

	free(console, allocator, loc) or_return
	return .None
}

console_set_program_counter :: proc(console: ^Console, address: u16) {
	console.cpu.pc = address
}

// Restore state as after power up.
console_initialize_with_cartridge :: proc(console: ^Console, cartridge: ^Cartridge) {
	apu_opts: APU_Options = {
		mixing_stratergy = APU_Mixing_Linear_Approximation{1, 1, 1, 1, 1},
	}

	cpu_initialize(&console.cpu)
	dma_initialize(&console.dma)
	apu_initialize(&console.apu, 44100, apu_opts)
	ppu_initialize(&console.ppu)

	// c: Console

	// reassign pointers
	// c.ram = console.ram
	// c.palette = console.palette

	console.cartridge = cartridge

	// console^ = c
}


console_execute_clk_cycle :: proc(
	console: ^Console,
	pixel_buffer: Maybe([]Color),
) -> (
	frame_complete: bool,
	cpu_complete: bool,
	audio_sample_complete: bool,
	err: Maybe(Error),
) {
	trigger_nmi, trigger_irq: bool

	frame_complete, trigger_nmi = ppu_execute_clk_cycle(
		&console.ppu,
		console.cartridge,
		console.palette,
		pixel_buffer,
	)

	audio_sample_complete, trigger_irq = apu_execute_clk_cycle(&console.apu, &console.dma)

	if cartridge_query_trigger_irq(console.cartridge) {
		trigger_irq = true
	}

	if trigger_nmi {
		console.cpu.interrupt = .NMI
	} else if trigger_irq {
		console.cpu.interrupt = .IRQ
	}

	if console.cycle_count % 3 == 0 {
		halt_cpu := dma_execute_clk_cycle(console)
		if !halt_cpu {
			cpu_complete, err = cpu_execute_clk_cycle(console)
		}
	}

	console.cycle_count += 1
	return
}

console_reset :: proc(console: ^Console) -> Maybe(Error) {
	console.cpu.interrupt = .Reset
	complete: bool
	for !complete {
		_, complete, _ = console_execute_clk_cycle(console, nil) or_return

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
		ppu_write_to_mmio_register(&console.ppu, console.cartridge, data, address_offset) or_return
	case 0x4000 ..< 0x4014, 0x4015, 0x4017:
		apu_write_to_address(&console.apu, data, address)
	case 0x4014:
		dma_query_oam_state_complete(&console.dma)
		dma_schedule_oam_transfer(&console.dma, data)
	// dma_schedule_oam_transfer(console, data)
	case 0x04016:
		controller_write(&console.controller1, data)
		controller_write(&console.controller2, data)
	case 0x4020 ..= 0xffff:
		// mapper
		cartridge_write_to_address(console.cartridge, data, address) or_return
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
		data = ppu_read_from_mmio_register(
			&console.ppu,
			console.cartridge,
			address_offset,
		) or_return
	case 0x4000 ..< 0x4014, 0x4015:
		data, err = apu_read_from_address(&console.apu, address)
	case 0x4014:
		err = error(.Memory_Error, "OAMDMA register at address $4014 is write-only")
	case 0x4016:
		data = controller_read(&console.controller1)
	case 0x4017:
		data = controller_read(&console.controller2)
	case 0x4020 ..= 0xffff:
		// mapper
		data = cartridge_read_from_address(console.cartridge, address) or_return
	case:
		panic(fmt.tprintf("invalid address $%04X", address))
	}

	return
}

@(require_results)
console_state_to_string :: proc(console: ^Console) -> string {
	opcode, _ := console_read_from_address(console, console.cpu.pc)
	instruction := cpu_get_instruction_from_opcode(opcode)
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

