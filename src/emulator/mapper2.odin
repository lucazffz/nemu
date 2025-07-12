package emulator

Mapper2 :: struct {
	using m:     Mapper,
	bank_select: u8,
}

mapper2_make :: proc() -> ^Mapper2 {
	m := new(Mapper2)

	m.write_to_address = mapper2_write_to_address
	m.read_from_address = mapper2_read_from_address
	m.verify_ines_integrity = mapper2_verify_ines_integrity
	m.delete = mapper2_delete

	return m
}

@(private = "file")
mapper2_delete :: proc(mapper: ^Mapper) {
	m := cast(^Mapper2)mapper
	free(m)
}

@(private = "file")
mapper2_verify_ines_integrity :: proc(info: iNES_Info) -> Maybe(Error) {
	h := info.header
	return nil
}

@(private = "file")
mapper2_write_to_address :: proc(
	mapper: ^Mapper,
	c: ^Cartridge,
	data: u8,
	address: u16,
) -> (
	err: Maybe(Error),
) {
	m := cast(^Mapper2)mapper
	switch address {
	case 0x0000 ..< 0x2000:
		// Mapper 2 has no CHR memory banking capabilities
		if mem, read_only := cartridge_get_chr_mem(c); !read_only {
			mem[address] = data
		} else {
			err = errorf(
				.Memory_Error,
				"cannot write '%02X' to $%04X (read-only $0000-$1FFF)",
				data,
				address,
				severity = .Warning,
			)
		}
	case 0x2000 ..= 0x3eff:
		addr := get_nametable_mirror_address(address, c.mirroring)
		c.vram[addr - 0x2000] = data
	case 0x6000 ..< 0x8000:
		// While Mapper 2 does not support PRG RAM, some homebrew games
		// and educational cartridges require PRG RAM. Therefore,
		// it is recommended that emulators support it.
		// See docs here: https://www.nesdev.org/wiki/UxROM
		if c.prg_ram != nil {
			c.prg_ram[address - 0x6000] = data
		} else {
			err = errorf(
				.Memory_Error,
				"cannot write '%02X' to $%04X, PRG-RAM ($6000-$7FFF) is unallocated",
				address,
			)
		}
	case 0x8000 ..= 0xffff:
		// While bank select is bits 2-0 for UNROM and 3-0 for UOROM,
		// emulator usually use all 8 bits for wider cartridge board
		// compatability. 
		m.bank_select = data
	case:
		panic("address not handled by mapper 2")
	}

	return
}

@(private = "file")
mapper2_read_from_address :: proc(
	mapper: ^Mapper,
	c: ^Cartridge,
	address: u16,
) -> (
	data: u8,
	err: Maybe(Error),
) {
	m := cast(^Mapper2)mapper
	switch address {
	case 0x0000 ..< 0x2000:
		// Mapper 2 has no CHR memory banking capabilities
		mem := cartridge_get_chr_mem(c)
		data = mem[address]
	case 0x2000 ..= 0x3eff:
		addr := get_nametable_mirror_address(address, c.mirroring)
		data = c.vram[addr - 0x2000]
	case 0x6000 ..< 0x8000:
		// While Mapper 2 does not support PRG RAM, some homebrew games
		// and educational cartridges require PRG RAM. Therefore,
		// it is recommended that emulators support it.
		// See docs here: https://www.nesdev.org/wiki/UxROM
		if c.prg_ram != nil {
			data = c.prg_ram[address - 0x6000]
		} else {
			err = errorf(
				.Memory_Error,
				"cannot read from $%04X, PRG-RAM ($6000-$7FFF) is unallocated",
				address,
				severity = .Warning,
			)
		}
	case 0x8000 ..= 0xffff:
		// $8000-$BFFF: 16KB switchable PRG ROM bank
		// $C000-$FFFF: 16KB PRG ROM bank fixed to the last bank
		if address < 0xc000 {
			bank_number := m.bank_select
			bank_offset := uint(address & 0x3fff)
			offset := uint(bank_number) * 0x4000 + bank_offset
			data = c.prg_rom[offset]
		} else {
			bank_offset := uint(address & 0x3fff)
			last_bank_start_offset := len(c.prg_rom) - 0x4000
			offset := uint(last_bank_start_offset) + bank_offset
			data = c.prg_rom[offset]
		}
	case:
		panic("address not handled by mapper 2")
	}

	return
}

