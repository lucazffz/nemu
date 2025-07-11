package emulator

// @note Consecutive-cycle writes are not emulated which
// will cause issues in certain games.
// See https://www.nesdev.org/wiki/MMC1 for documentation.
//
// It also does not respect the chip enable bit in the PRG bank register
Mapper1 :: struct {
	using m:             Mapper,
	// all registers are 5 bits
	load_register:       u8,
	control:             bit_field u8 {
		nametable_arrangement: u8 | 2,
		// 0, 1: switch 32KB at $8000, ignoring low bit of bank number
		// 2: fix first bank at $8000 and switch 16KB bank at $C000
		// 3: fix last bank at $C000 and switch 16KB at $8000
		prg_rom_bank_mode:     u8 | 2,
		// 0: switch 8KB at a time
		// 1: switch two separate 4KB banks
		chr_rom_bank_mode:     u8 | 1,
		_unused:               u8 | 3,
	},
	chr_bank_0_register: u8,
	chr_bank_1_register: u8,
	prg_bank_register:   u8,
}

mapper1_make :: proc() -> ^Mapper1 {
	m := new(Mapper1)
	reset(m)

	m.write_to_address = mapper1_write_to_address
	m.read_from_address = mapper1_read_from_address
	m.delete = mapper1_delete
	return m
}

@(private = "file")
mapper1_delete :: proc(mapper: ^Mapper) {
	m := cast(^Mapper1)mapper
	free(m)
}

@(private = "file")
mapper1_write_to_address :: proc(
	mapper: ^Mapper,
	c: ^Cartridge,
	data: u8,
	address: u16,
) -> (
	err: Maybe(Error),
) {
	m := cast(^Mapper1)mapper
	switch address {
	case 0x0000 ..< 0x2000:
		// Mapper 1 have either CHR ROM or RAM, not both
		if c.chr_ram != nil {
			offset := map_address_to_chr_mem_offset(m^, address)
			c.chr_ram[offset] = data
		} else if c.chr_rom != nil {
			err = errorf(
				.Memory_Error,
				"cannot write '%02X' to $%04X (read-only $0000-$1FFF)",
				data,
				address,
				severity = .Warning,
			)
		} else {
			panic("either CHR ROM or RAM must be present")
		}
	case 0x2000 ..= 0x3eff:
		addr := get_nametable_mirror_address(address, c.mirroring)
		c.vram[addr - 0x2000] = data
	case 0x6000 ..< 0x8000:
		if c.prg_ram != nil {
			c.prg_ram[address - 0x6000] = data
		} else {
			err = errorf(
				.Memory_Error,
				"cannot write '%02X' to $%04X, PRG-RAM ($6000-$7FFF) is unallocated",
				data,
				address,
				severity = .Warning,
			)
		}
	case 0x8000 ..= 0xffff:
		write_to_load_register(m, c, data, address)
	case:
		panic("address not handled by mapper 1")
	}

	return
}

@(private = "file")
mapper1_read_from_address :: proc(
	mapper: ^Mapper,
	c: ^Cartridge,
	address: u16,
) -> (
	data: u8,
	err: Maybe(Error),
) {
	m := cast(^Mapper1)mapper
	switch address {
	case 0x0000 ..< 0x2000:
		chr_mem: []u8
		// Mapper 1 have either CHR ROM or RAM, not both
		if c.chr_rom != nil {
			chr_mem = c.chr_rom
		} else if c.chr_ram != nil {
			chr_mem = c.chr_ram
		} else {
			panic("either CHR ROM or RAM must be present")
		}

		offset := map_address_to_chr_mem_offset(m^, address)
		data = chr_mem[offset]
	case 0x2000 ..= 0x3eff:
		addr := get_nametable_mirror_address(address, c.mirroring)
		data = c.vram[addr - 0x2000]
	case 0x6000 ..< 0x8000:
		if c.prg_ram != nil {
			data = c.prg_ram[address - 0x6000]
		} else {
			err = errorf(
				.Memory_Error,
				"cannot read from $%04X, PRG-RAM ($6000-$7FFF) is unallocated",
				address,
			)
		}
	case 0x8000 ..= 0xffff:
		offset := map_address_to_prg_mem_offset(m^, address, len(c.prg_rom))
		data = c.prg_rom[offset]
	case:
		panic("address not handled by mapper 1")
	}

	return
}

@(private = "file")
reset :: proc(m: ^Mapper1) {
	m.load_register = 0x10
	m.control.prg_rom_bank_mode = 3
}

@(private = "file")
write_to_load_register :: proc(m: ^Mapper1, c: ^Cartridge, data: u8, address: u16) {
	// log.info(m.prg_bank_register)
	// mirroring: Nametable_Mirroring

	// reset shift register if bit 7 of data is set
	if (data & 0x80) == 0x80 {
		reset(m)
	} else {
		complete := m.load_register & 0x1 == 1
		m.load_register = (m.load_register >> 1) | ((data & 0x01) << 4)
		// m.load_register_count += 1
		if complete {
			// choose register to write to based on address bit 13 and 14
			switch (address >> 13) & 0x03 {
			case 0:
				// m.control.nametable_arrangement = m.load_register & 0x3
				// m.control.prg_rom_bank_mode = (m.load_register >> 2) & 0x3
				// m.control.chr_rom_bank_mode = (m.load_register >> 4) & 0x1
				m.control = auto_cast (m.load_register & 0x1f)
				// set cartridge mirroring mode based in nametable
				// arrangement in mapper 1 control register
				switch m.control.nametable_arrangement {
				case 0:
					c.mirroring = .Single_Screen_A
				case 1:
					c.mirroring = .Single_Screen_B
				case 2:
					c.mirroring = .Vertical
				case 3:
					c.mirroring = .Horizontal
				}
			case 1:
				m.chr_bank_0_register = m.load_register & 0x1f
			case 2:
				m.chr_bank_1_register = m.load_register & 0x1f
			case 3:
				m.prg_bank_register = m.load_register & 0x0f
			case:
				panic("shit")
			}

			m.load_register = 0x10 // clear register after 5th write
		}

	}

	// return mirroring
}

@(private = "file")
map_address_to_chr_mem_offset :: proc(m: Mapper1, address: u16) -> (mapped_offset: uint) {
	assert(address < 0x2000, "address not within chr memory range")
	// pattern tables, CHR ROM / RAM
	if m.control.chr_rom_bank_mode == 0 {
		// 8KB banking mode
		chr_offset := uint(address & 0x1fff)
		bank_number := m.chr_bank_0_register >> 1
		mapped_offset = uint(bank_number) * 0x2000 + chr_offset
	} else {
		// 4KB banking mode
		chr_offset := uint(address & 0x0fff)
		if address < 0x1000 {
			bank_number := m.chr_bank_0_register
			mapped_offset = uint(bank_number) * 0x1000 + chr_offset
		} else {
			bank_number := m.chr_bank_1_register
			mapped_offset = uint(bank_number) * 0x1000 + chr_offset
		}
	}

	return
}

@(private = "file")
map_address_to_prg_mem_offset :: proc(
	m: Mapper1,
	address: u16,
	prg_rom_size: uint,
) -> (
	mapped_offset: uint,
) {
	assert(address >= 0x8000 && address <= 0xffff, "address not within prg memory range")

	// PRG ROM
	// 0, 1: switch 32KB at $8000, ignoring low bit of bank number
	// 2: fix first bank at $8000 and switch 16KB bank at $C000
	// 3: fix last bank at $C000 and switch 16KB at $8000
	switch m.control.prg_rom_bank_mode {
	case 0, 1:
		prg_offset := uint(address & 0x7fff)
		bank_number := m.prg_bank_register >> 1
		mapped_offset = uint(bank_number) * 0x8000 + prg_offset
	case 2:
		bank_number := m.prg_bank_register
		if address < 0xc000 {
			prg_offset := uint(address & 0x3fff)
			mapped_offset = prg_offset
		} else {
			prg_offset := uint(address & 0x3fff)
			mapped_offset = uint(bank_number) * 0x4000 + prg_offset
		}
	case 3:
		if address < 0xc000 {
			bank_number := m.prg_bank_register
			prg_offset := uint(address & 0x3fff)
			mapped_offset = uint(bank_number) * 0x4000 + prg_offset
		} else {
			prg_offset := uint(address & 0x3fff)
			last_bank_start_offset := prg_rom_size - 0x4000
			mapped_offset = uint(last_bank_start_offset) + prg_offset
		}
	}

	return
}

