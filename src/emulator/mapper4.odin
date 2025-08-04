package emulator

Mapper4 :: struct {
	using m:             Mapper,
	bank_select_reg:     bit_field u8 {
		reg:               u8   | 3, // register to update on next write
		_unused:           u8   | 3,
		// 0: $8000-$9FFF swappable, $C000-$DFFF fixed
		// 1: $C000-$DFFF swappable, $8000-$9FFF fixed
		prg_rom_bank_mode: u8   | 1,
		// 0: two 2KB banks at $0000-$0FFF, four 1KB banks at $1000-$1FFF
		// 1: two 2KB banks at $1000-$1FFF, four 1KB banks at $0000-$0FFF
		chr_a12_inversion: bool | 1,
	},
	prg_ram_protect_reg: bit_field u8 {
		_unused:       u8   | 6,
		write_protect: bool | 1,
		chip_enable:   bool | 1,
	},
	irq_latch_reg:       u8,
	// ---- Internal variables
	a12_high:            bool,
	// a12_low_counter:     uint,
	interrupt_enable:    bool,
	interrupt_reload:    bool,
	interrupt_counter:   u8,
	bank_select_regs:    [8]u8, // R0-R7
}

mapper4_make :: proc() -> ^Mapper4 {
	m := new(Mapper4)

	m.write_to_address = mapper4_write_to_address
	m.read_from_address = mapper4_read_from_address
	m.verify_ines_integrity = mapper4_verify_ines_integrity
	m.delete = mapper4_delete

	return m
}

@(private = "file")
mapper4_verify_ines_integrity :: proc(info: iNES_Info) -> Maybe(Error) {
	return nil
}

@(private = "file")
mapper4_delete :: proc(mapper: ^Mapper) {
	m := cast(^Mapper4)mapper
	free(m)
}

mapper4_check_compatability :: proc(header: NES20_Header) -> Maybe(Error) {
	return nil
}

@(private = "file")
mapper4_write_to_address :: proc(
	mapper: ^Mapper,
	c: ^Cartridge,
	data: u8,
	address: u16,
) -> (
	err: Maybe(Error),
) {
	m := cast(^Mapper4)mapper

	switch address {
	case 0x0000 ..< 0x3f00:
		if address < 0x2000 {
			// $0000-$1FFF
			if mem, read_only := cartridge_get_chr_mem(c); !read_only {
				offset := map_address_to_chr_mem_offset(m^, address)
				mem[offset] = data
			} else {
				err = errorf(
					.Memory_Error,
					"cannot write '%02X' to $%04X (read-only $0000-$1FFF)",
					data,
					address,
					severity = .Warning,
				)
			}
		} else {
			// $2000-$3EFF
			addr := get_nametable_mirror_address(address, c.mirroring)
			c.vram[addr - 0x2000] = data
		}

		if a12_query_on_rising_edge(m, address) {
			c.trigger_irq = update_interrupt(m, address)
		}
	case 0x6000 ..< 0x8000:
		if c.prg_ram == nil {
			err = errorf(
				.Memory_Error,
				"cannot write '%02X' to $%04X, PRG-RAM ($6000-$7FFF) is unallocated",
				data,
				address,
				severity = .Warning,
			)

			return
		}

		if !m.prg_ram_protect_reg.chip_enable {
			err = errorf(
				.Memory_Error,
				"cannot write '%02X' to $%04X, PRG-RAM ($6000-$7FFF) chip disabled (Mapper 4)",
				data,
				address,
				severity = .Warning,
			)

			return
		}

		if m.prg_ram_protect_reg.write_protect {
			err = errorf(
				.Memory_Error,
				"cannot write '%02X' to $%04X, PRG-RAM ($6000-$7FFF) write protected (Mapper 4)",
				data,
				address,
				severity = .Warning,
			)

			return
		}

		c.prg_ram[address - 0x6000] = data
	case 0x8000 ..= 0xffff:
		write_to_register_from_address(m, c, address, data)
	case:
		panic("address not handled by mapper 4")
	}

	return
}

@(private = "file")
mapper4_read_from_address :: proc(
	mapper: ^Mapper,
	c: ^Cartridge,
	address: u16,
) -> (
	data: u8,
	err: Maybe(Error),
) {
	m := cast(^Mapper4)mapper

	switch address {
	case 0x0000 ..< 0x3f00:
		if address < 0x2000 {
			// $0000-$1FFF
			offset := map_address_to_chr_mem_offset(m^, address)
			mem := cartridge_get_chr_mem(c)
			data = mem[offset]
		} else {
			// $2000-$3EFF
			addr := get_nametable_mirror_address(address, c.mirroring)
			data = c.vram[addr - 0x2000]
		}

		if a12_query_on_rising_edge(m, address) {
			c.trigger_irq = update_interrupt(m, address)
		}
	case 0x6000 ..< 0x8000:
		if c.prg_ram == nil {
			err = errorf(
				.Memory_Error,
				"cannot read from $%04X, PRG-RAM ($6000-$7FFF) is unallocated",
				address,
			)

			return
		}

		if !m.prg_ram_protect_reg.chip_enable {
			err = errorf(
				.Memory_Error,
				"cannot read from $%04X, PRG-RAM ($6000-$7FFF) chip disabled (Mapper 4)",
				address,
				severity = .Warning,
			)

			return
		}

		data = c.prg_ram[address - 0x6000]
	case 0x8000 ..= 0xffff:
		offset := map_address_to_prg_mem_offset(m^, address, len(c.prg_rom))
		data = c.prg_rom[offset]
	case:
		panic("address not handled by mapper 4")
	}

	return
}

@(private = "file")
write_to_register_from_address :: proc(m: ^Mapper4, c: ^Cartridge, address: u16, data: u8) {
	is_address_even := address & 0x0001 == 0
	switch address {
	case 0x8000 ..< 0xa000:
		if is_address_even {
			m.bank_select_reg = auto_cast data
		} else {
			// bank data reg
			bank_number: u8
			reg_number := m.bank_select_reg.reg
			if reg_number == 6 || reg_number == 7 {
				// R6 and R7 will ignore two highest bits
				// @note some romehacks rely on an 8-bit extension of R6/7
				// for oversized PRG-ROM. Not supported by many emulator.
				bank_number = data & 0x3f
			} else if reg_number == 0 || reg_number == 1 {
				// R0 and R1 willignore lowest bit
				bank_number = data & 0xfe
			} else {
				bank_number = data
			}

			m.bank_select_regs[reg_number] = bank_number
		}
	case 0xa000 ..< 0xc000:
		if is_address_even {
			if data & 0x01 == 0 {
				c.mirroring = .Vertical
			} else {
				c.mirroring = .Horizontal
			}
		} else {
			m.prg_ram_protect_reg = auto_cast data
		}
	case 0xc000 ..< 0xe000:
		if is_address_even {
			m.irq_latch_reg = data
		} else {
			// irq reload reg
			m.interrupt_counter = 0
			m.interrupt_reload = true
		}
	case 0xe000 ..= 0xffff:
		if is_address_even {
			// irq disable reg
			m.interrupt_enable = false
		} else {
			// irq enable reg
			m.interrupt_enable = true
		}
	case:
		panic("address not within registers space")
	}
}

@(require_results, private = "file")
a12_query_on_rising_edge :: proc(m: ^Mapper4, address: u16) -> bool {
	a12_high := address & 0x1000 > 0
	defer m.a12_high = a12_high

	if !m.a12_high && a12_high {
		return true
	}

	return false

}

@(require_results, private = "file")
update_interrupt :: proc(m: ^Mapper4, address: u16) -> (trigger_irq: bool) {
	// A12 rising edge, 0 -> 1
	if m.interrupt_counter == 0 || m.interrupt_reload {
		m.interrupt_reload = false
		m.interrupt_counter = m.irq_latch_reg
	} else {
		m.interrupt_counter -= 1
	}

	if m.interrupt_counter == 0 && m.interrupt_enable {
		trigger_irq = true
	}

	return
}

@(private = "file")
map_address_to_chr_mem_offset :: proc(m: Mapper4, address: u16) -> (mapped_offset: uint) {
	address := address
	if m.bank_select_reg.chr_a12_inversion {
		address ~= 0x1000
	}

	switch address {
	case 0x0000 ..< 0x0800:
		mapped_offset = get_mapped_offset(m.bank_select_regs[0], .Two_KB, address)
	case 0x0800 ..< 0x1000:
		mapped_offset = get_mapped_offset(m.bank_select_regs[1], .Two_KB, address)
	case 0x1000 ..< 0x1400:
		mapped_offset = get_mapped_offset(m.bank_select_regs[2], .One_KB, address)
	case 0x1400 ..< 0x1800:
		mapped_offset = get_mapped_offset(m.bank_select_regs[3], .One_KB, address)
	case 0x1800 ..< 0x01c0:
		mapped_offset = get_mapped_offset(m.bank_select_regs[4], .One_KB, address)
	case 0x1c00 ..< 0x2000:
		mapped_offset = get_mapped_offset(m.bank_select_regs[5], .One_KB, address)
	}

	return

	Bank_Size :: enum {
		One_KB,
		Two_KB,
	}

	get_mapped_offset :: proc(
		#any_int bank_number: uint,
		#any_int bank_size: Bank_Size,
		address: u16,
	) -> (
		mapped_offset: uint,
	) {
		mask: uint = 0x03ff if bank_size == .One_KB else 0x07ff
		prg_offset := uint(address) & mask
		// all bank select registers count banks in 1KB units, even R0 and R1
		mapped_offset = bank_number * 0x400 + prg_offset
		return
	}
}

@(private = "file")
map_address_to_prg_mem_offset :: proc(
	m: Mapper4,
	address: u16,
	prg_rom_size: uint,
) -> (
	mapped_offset: uint,
) {
	// All PRG ROM banks are 8KB in size.
	switch address {
	case 0x8000 ..< 0xa000:
		if m.bank_select_reg.prg_rom_bank_mode == 0 {
			// switchable
			bank_number := m.bank_select_regs[6]
			prg_offset := uint(address & 0x1fff)
			mapped_offset = uint(bank_number) * 0x2000 + prg_offset
		} else {
			// fixed to second-last bank
			prg_offset := uint(address & 0x1fff)
			second_last_bank_start_offset := prg_rom_size - 0x4000
			mapped_offset = uint(second_last_bank_start_offset) + prg_offset
		}
	case 0xa000 ..< 0xc000:
		// switchable 
		bank_number := m.bank_select_regs[7]
		prg_offset := uint(address & 0x1fff)
		mapped_offset = uint(bank_number) * 0x2000 + prg_offset
	case 0xc000 ..< 0xe000:
		if m.bank_select_reg.prg_rom_bank_mode == 0 {
			// fixed to second-last bank
			prg_offset := uint(address & 0x1fff)
			second_last_bank_start_offset := prg_rom_size - 0x4000
			mapped_offset = uint(second_last_bank_start_offset) + prg_offset
		} else {
			// switchable
			bank_number := m.bank_select_regs[6]
			prg_offset := uint(address & 0x1fff)
			mapped_offset = uint(bank_number) * 0x2000 + prg_offset
		}
	case 0xe000 ..= 0xffff:
		// fixed to last bank
		prg_offset := uint(address & 0x1fff)
		last_bank_start_offset := prg_rom_size - 0x2000
		mapped_offset = uint(last_bank_start_offset) + prg_offset
	}

	return
}

