package emulator

Mapper0 :: struct {
	using m: Mapper,
	// does not perform any banking
}

mapper0_make :: proc() -> ^Mapper0 {
	m := new(Mapper0)
	m.write_to_address = mapper0_write_to_address
	m.read_from_address = mapper0_read_from_address
	m.delete = mapper0_delete
	return m
}

@(private = "file")
mapper0_delete :: proc(mapper: ^Mapper) {
	m := cast(^Mapper0)mapper
	free(m)
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
		addr := get_nametable_mirror_address(address, c.mirroring)
		c.vram[addr - 0x2000] = data
	case 0x6000 ..< 0x8000:
		if len(c.prg_ram) != 0 {
			addr := address & 0x7ff
			c.prg_ram[addr - 0x6000] = data
		} else if len(c.prg_ram) == 4 * 1024 {
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
	switch address {
	case 0x0000 ..< 0x2000:
		data = c.chr_rom[address]
	case 0x2000 ..= 0x3eff:
		addr := get_nametable_mirror_address(address, c.mirroring)
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

