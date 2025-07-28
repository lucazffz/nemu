package emulator


import "../utils"
import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"

ASSETS_DIR_PATH :: #directory + "assets/"

CPU_CLK_FREQUENCY :: 1789773.0

Console :: struct {
	cpu:                             CPU,
	ppu:                             PPU,
	apu:                             APU,
	// 2 KB of internal ram ($0000 - $07FF)
	ram:                             []u8,
	palette:                         ^Palette,
	cartridge:                       ^Cartridge,
	controller1:                     Controller,
	controller2:                     Controller,
	cycle_count:                     int,
	dma_halt_cycle:                  bool,
	dma_oam_page:                    u8,
	dma_oam_addr:                    u8,
	dma_oam_data:                    u8,
	dma_oam_alignment_cycle:         bool, // DMA halt/alignment cycle
	dma_oam_transfer:                bool,
	dma_dmc_transfer:                bool,
	dma_dmc_transfer_schedule_count: int,
	dma_dmc_transfer_scheduled:      bool,
	dma_dmc_schedule_on_get_cycle:   bool,
	dma_dmc_dummy_cycle:             bool,
	dma_dmc_alignment_cycle:         bool,
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
	palette: Maybe(^Palette) = nil,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	console: ^Console,
	err: runtime.Allocator_Error,
) #optional_allocator_error {
	// dont check error, know that intervals are closed
	ppu_palette_size := utils.interval_size(PPU_PALLETTE_RAM_INTERVAL)
	cpu_ram_size := utils.interval_size(CPU_RAM_INTERVAL)

	console = new(Console, allocator, loc) or_return

	console.apu = apu_make(allocator, loc) or_return

	console.palette = palette.? or_else palette_make_default()

	// pattern table and nametable are stored in cartridge (mapper) so
	// dont need to allocate them here
	console.ppu.palette = make_slice([]u8, ppu_palette_size, allocator, loc) or_return
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
	delete_slice(console.ram, allocator, loc) or_return
	delete_slice(console.ppu.palette, allocator, loc) or_return
	palette_delete(console.palette)
	cartridge_delete(console.cartridge)

	free(console, allocator, loc) or_return
	return .None
}

console_set_program_counter :: proc(console: ^Console, address: u16) {
	console.cpu.pc = address
}

// will touch all fields so can be used to reinitialize an existing console
console_initialize_with_cartridge :: proc(console: ^Console, cartridge: ^Cartridge) {
	c: Console

	c.cpu.sp = 0xfd
	c.cpu.pc = 0xc000
	c.cpu.status = {.IF}


	// reassign pointers
	c.ram = console.ram
	c.ppu.palette = console.ppu.palette
	c.palette = console.palette

	c.cartridge = cartridge

	apu_opts: APU_Options = {
		mixing_stratergy = APU_Mixing_Linear_Approximation{0, 0, 0, 0, 1},
	}

	apu_initialize(&c.apu, 44100, apu_opts)

	console^ = c
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
	trigger_nmi, trigger_irq, dmc_dma_transfer: bool

	frame_complete, trigger_nmi = ppu_execute_clk_cycle(
		&console.ppu,
		console.cartridge,
		console.palette,
		pixel_buffer,
	)

	audio_sample_complete, trigger_irq, dmc_dma_transfer = apu_execute_clk_cycle(&console.apu)

	if dmc_dma_transfer do console_schedule_dma_dmc_transfer(console)

	if trigger_nmi {
		console.cpu.interrupt = .NMI
	} else if trigger_irq {
		console.cpu.interrupt = .IRQ
	}

	if console.cycle_count % 3 == 0 {
		if should_execute_dma_transfer(console) {
			dma_transfer_execute_clk_cycle(console)
		} else {
			cpu_complete, err = cpu_execute_clk_cycle(console)
		}
	}

	console.cycle_count += 1
	return

	should_execute_dma_transfer :: proc(c: ^Console) -> bool {
		if c.dma_oam_transfer {
			return true
		}

		if c.dma_dmc_transfer {
			return true
		}

		if c.dma_dmc_transfer_scheduled {
			c.dma_dmc_transfer_schedule_count -= 1
			if c.dma_dmc_transfer_schedule_count == 0 {
				c.dma_dmc_transfer_scheduled = false
				c.dma_dmc_transfer = true
				return true
			}
		}

		return false
	}

	dma_transfer_execute_clk_cycle :: proc(c: ^Console) {
		dmc_active: bool

		dmc_execute: if c.dma_dmc_transfer {
			if c.dma_halt_cycle {
				c.dma_halt_cycle = false
				return
			}

			dmc_active = true
			if c.dma_dmc_dummy_cycle {
				c.dma_dmc_dummy_cycle = false
				return
			}

			if c.dma_dmc_alignment_cycle {
				c.dma_dmc_alignment_cycle = false
				if is_apu_clk2(c^) {
					return
				}
			}

			addr := c.apu.dmc.reader_current_addr
			c.apu.dmc.sample_buffer, _ = console_read_from_address(c, addr)
			c.apu.dmc.sample_buffer_empty = false
			c.apu.dmc.dma_transfer_mode = .Reload
			reset_dmc_dma(c)

			reset_dmc_dma :: proc(c: ^Console) {
				c.dma_dmc_transfer = false
				c.dma_dmc_dummy_cycle = true
				c.dma_dmc_alignment_cycle = true
				if !c.dma_oam_transfer {
					c.dma_halt_cycle = true
				}
			}
		}

		oam_execute: if c.dma_oam_transfer {
			if c.dma_halt_cycle {
				c.dma_halt_cycle = false
				return
			}

			if dmc_active {
				c.dma_oam_alignment_cycle = true
				return
			}

			if c.dma_oam_alignment_cycle {
				c.dma_oam_alignment_cycle = false
				// DMA can only read in read get cycles (apu_clk1) so
				// clear dummy read flag if next cycle is apu_clk1
				if is_apu_clk2(c^) {
					return
				}

			}

			if is_apu_clk1(c^) {
				// read on get cycle
				addr := u16(c.dma_oam_page) << 8 | u16(c.dma_oam_addr)
				c.dma_oam_data, _ = console_read_from_address(c, addr)
			}

			if is_apu_clk2(c^) {
				// write on put cycle
				ppu_oam_write_to_address(&c.ppu, c.dma_oam_data, c.dma_oam_addr)
				c.dma_oam_addr += 1

				if c.dma_oam_addr == 0x0 {
					reset_oam_dma(c)
				}

				reset_oam_dma :: proc(c: ^Console) {
					c.dma_oam_transfer = false
					c.dma_oam_alignment_cycle = true
					if !c.dma_dmc_transfer {
						c.dma_halt_cycle = true
					}
				}
			}
		}

	}
}

// @note clk1 is assumed to be even cpu clock cycles and clk2 uneven.
// This is not technically correct since the NES CPU and APU can
// power into either of 2 alginments relative to each other. However,
// this emulator have start at 0.
is_apu_clk1 :: proc(c: Console) -> bool {
	return c.cycle_count & 0x1 == 0
}

is_apu_clk2 :: proc(c: Console) -> bool {
	return c.cycle_count & 0x1 == 1
}

@(private)
console_schedule_dma_oam_transfer :: proc(console: ^Console, page: u8) {
	console.dma_oam_transfer = true
	console.dma_oam_addr = 0
	console.dma_oam_page = page
}

@(private)
console_schedule_dma_dmc_transfer :: proc(console: ^Console) {
	console.dma_dmc_transfer_scheduled = true
	console.dma_dmc_transfer = false

	if is_apu_clk1(console^) {
		console.dma_dmc_transfer_schedule_count = 3
	}

	if is_apu_clk2(console^) {
		console.dma_dmc_transfer_schedule_count = 4
	}

	if console.apu.dmc.dma_transfer_mode == .Reload {
		console.dma_dmc_transfer_schedule_count += 1
	}
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
	case 0x4000 ..< 0x4014, 0x4017:
		apu_write_to_address(&console.apu, data, address)
	case 0x4014:
		console_schedule_dma_oam_transfer(console, data)
	case 0x4015:
		apu_write_to_address(&console.apu, data, address)
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

