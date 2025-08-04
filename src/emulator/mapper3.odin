package emulator

Mapper3 :: struct {
	using m:     Mapper,
	mirroring:   Nametable_Mirroring,
	bank_select: u8,
}

mapper3_make :: proc(info: iNES_Info) -> ^Mapper3 {
	m := new(Mapper3)

	arrangement := info.header.nametable_arrangement
	m.mirroring = nametable_arrangement_to_mirroring(arrangement)
	m.m.write_to_address = mapper3_write_to_address
	m.read_from_address = mapper3_read_from_address
	m.verify_ines_integrity = mapper3_verify_ines_integrity
	m.delete = mapper3_delete

	return m
}

@(private = "file")
mapper3_verify_ines_integrity :: proc(info: iNES_Info) -> Maybe(Error) {
	return nil
}

@(private = "file")
mapper3_delete :: proc(mapper: ^Mapper) {
	m := cast(^Mapper3)mapper
	free(m)
}

mapper3_check_compatability :: proc(header: NES20_Header) -> Maybe(Error) {
	return nil
}

@(private = "file")
mapper3_write_to_address :: proc(
	mapper: ^Mapper,
	c: ^Cartridge,
	data: u8,
	address: u16,
) -> (
	err: Maybe(Error),
) {
	m := cast(^Mapper3)mapper
	switch address {
	case 0x0000 ..< 0x2000:
		err = errorf(
			.Memory_Error,
			"cannot write '%02X' to $%04X, mapper 3 does not support CHR-RAM",
			address,
			data,
			severity = .Warning,
		)
	case 0x2000 ..= 0x3eff:
		addr := get_nametable_mirror_address(address, m.mirroring)
		c.vram[addr - 0x2000] = data
	case 0x6000 ..< 0x8000:
		// While Mapper 3 does not support PRG RAM, Hayauchi Super Igo uses
		// 2KB mirrored 3 times from $6000-$7FFF.
		if c.prg_ram != nil {
			c.prg_ram[(address - 0x6000) & 0x07ff] = data
		} else {
			err = errorf(
				.Memory_Error,
				"cannot write '%02X' to $%04X, PRG-RAM ($6000-$7FFF) is unallocated",
				address,
			)
		}
	case 0x8000 ..= 0xffff:
		m.bank_select = data & 0x3
	case:
		panic("address not handled by mapper 3")
	}

	return
}

@(private = "file")
mapper3_read_from_address :: proc(
	mapper: ^Mapper,
	c: ^Cartridge,
	address: u16,
) -> (
	data: u8,
	err: Maybe(Error),
) {
	m := cast(^Mapper3)mapper
	switch address {
	case 0x0000 ..< 0x2000:
		// has 4 8KB banks for a total of 32KB CHR ROM
		bank_number := m.bank_select
		bank_offset := uint(address & 0x1fff)
		offset := uint(bank_number) * 0x2000 + bank_offset
		data = c.chr_rom[offset]
	case 0x2000 ..= 0x3eff:
		addr := get_nametable_mirror_address(address, m.mirroring)
		data = c.vram[addr - 0x2000]
	case 0x6000 ..< 0x8000:
		// While Mapper 3 does not support PRG RAM, Hayauchi Super Igo uses
		// 2KB mirrored 3 times from $6000-$7FFF.
		if c.prg_ram != nil {
			data = c.prg_ram[(address - 0x6000) & 0x07ff]
		} else {
			err = errorf(
				.Memory_Error,
				"cannot read from $%04X, PRG-RAM ($6000-$7FFF) is unallocated",
				address,
				severity = .Warning,
			)
		}
	case 0x8000 ..= 0xffff:
		// mapper 3 has no banked PRG ROM
		data = c.prg_rom[address - 0x8000]
	case:
		panic("address not handled by mapper 3")
	}

	return
}

