package emulator

Mapper0 :: struct {
	using m:   Mapper,
	mirroring: Nametable_Mirroring,
	// does not perform any banking
}

mapper0_make :: proc(nametable_arrangement: Nametable_Arrangement) -> ^Mapper0 {
	m := new(Mapper0)

	m.mirroring = nametable_arrangement_to_mirroring(nametable_arrangement)
	m.write_to_address = mapper0_write_to_address
	m.read_from_address = mapper0_read_from_address
	m.verify_ines_integrity = mapper0_verify_ines_integrity
	m.delete = mapper0_delete
	return m
}

@(private = "file")
mapper0_delete :: proc(mapper: ^Mapper) {
	m := cast(^Mapper0)mapper
	free(m)
}

@(private = "file")
mapper0_verify_ines_integrity :: proc(info: iNES_Info) -> Maybe(Error) {
	h := info.header

	// if h.prg_ram_size != 2 * KB && h.prg_ram_size != 4 * KB && h.prg_ram_size != 0 {
	// 	return errorf(
	// 		.iNES_Error,
	// 		"invalid PRG-RAM size of %dKB , must be either 0KB, 2KB or 4KB for mapper 0",
	// 		h.prg_ram_size / KB,
	// 	)
	// }

	// if h.prg_rom_size != 16 * KB && h.prg_rom_size != 32 * KB {
	// 	return errorf(
	// 		.iNES_Error,
	// 		"invalid PRG-ROM size of %dKB, must be either 16KB or 32KB for mapper 0",
	// 		h.prg_rom_size / KB,
	// 	)
	// }

	// // if h.prg_nvram_size > 0 {
	// // 	return error(.iNES_Error, "PRG-NVRAM not supported for mapper 0")
	// // }

	// if h.chr_rom_size != 8 * KB {
	// 	return errorf(
	// 		.iNES_Error,
	// 		"invalid CHR-ROM size of %dKB, must be 8KB for mapper 0",
	// 		h.chr_rom_size / KB,
	// 	)
	// }

	// if h.chr_ram_size > 0 {
	// 	return error(.iNES_Error, "CHR-RAM not supported for mapper 0")
	// }

	// // if h.chr_nvram_size > 0 {
	// // 	return error(.iNES_Error, "CHR-NVRAM not supported for mapper 0")
	// // }

	return nil
}

@(private = "file")
mapper0_write_to_address :: proc(
	mapper: ^Mapper,
	c: ^Cartridge,
	data: u8,
	address: u16,
) -> (
	err: Maybe(Error),
) {
	m := cast(^Mapper0)mapper

	switch address {
	case 0x0000 ..< 0x2000:
		err = errorf(
			.Memory_Error,
			"cannot write '%02X' to $%04X (read-only $0000-$1FFF)",
			data,
			address,
			severity = .Warning,
		)
	case 0x2000 ..= 0x3eff:
		addr := get_nametable_mirror_address(address, m.mirroring)
		c.vram[addr - 0x2000] = data
	case 0x6000 ..< 0x8000:
		if len(c.prg_ram) != 0 {
			addr := address & 0x7ff
			c.prg_ram[addr - 0x6000] = data
		} else if len(c.prg_ram) == 4 * KB {
			addr := address & 0xfff
			c.prg_ram[addr - 0x6000] = data
		} else {
			err = errorf(
				.Memory_Error,
				"cannot write '%02X' to $%04X, PRG-RAM ($6000-$7FFF) is unallocated",
				data,
				address,
				severity = .Warning,
			)
		}
	case:
		panic("shit")
	}

	return
}

@(private = "file")
mapper0_read_from_address :: proc(
	mapper: ^Mapper,
	c: ^Cartridge,
	address: u16,
) -> (
	data: u8,
	err: Maybe(Error),
) {
	m := cast(^Mapper0)mapper

	switch address {
	case 0x0000 ..< 0x2000:
		data = c.chr_rom[address]
	case 0x2000 ..= 0x3eff:
		addr := get_nametable_mirror_address(address, m.mirroring)
		data = c.vram[addr - 0x2000]
	case 0x6000 ..< 0x8000:
		if len(c.prg_ram) == 2 * KB {
			data = c.prg_ram[address & 0x7ff]
		} else if len(c.prg_ram) == 4 * KB {
			data = c.prg_ram[address & 0xfff]
		} else {
			err = errorf(
				.Memory_Error,
				"cannot read from $%04X, PRG-RAM ($6000-$7FFF) is unallocated",
				address,
			)
		}
	case 0x8000 ..= 0xffff:
		addr := address - 0x8000
		if len(c.prg_rom) == 16 * KB {
			if addr >= 0x4000 {
				addr -= 0x4000
			}
		}
		data = c.prg_rom[addr]
	case:
		panic("shit")
	}

	return
}

