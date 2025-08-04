package emulator

import "base:runtime"
import "core:os"
import "core:slice"

KB :: 1024 // one kibibyte

Cartridge :: struct {
	mapper:           ^Mapper,
	mapper_number:    int,
	submapper_number: int,
	ines_info:        iNES_Info,
	vram:             []u8,
	prg_rom:          []u8,
	prg_ram:          []u8, // used as SRAM or WRAM
	// Cartridges typically use either CHR RAM or CHR ROM, not both.
	// Mappers are agnotisc to weather ROM or RAM is present. However,
	// they are stored seperately here in case some special use case would
	// arise where they need to be treated seperately.
	chr_rom:          []u8,
	chr_ram:          []u8,
	battery_present:  bool,
	trigger_irq:      bool,
}

Nametable_Mirroring :: enum {
	Horizontal,
	Vertical,
	Single_Screen_A,
	Single_Screen_B,
	Four_Screen,
}

cartridge_query_trigger_irq :: proc(cartridge: ^Cartridge) -> bool {
	trigger_irq := cartridge.trigger_irq
	cartridge.trigger_irq = false
	return trigger_irq
}

@(require_results)
cartridge_get_chr_mem :: proc(cartridge: ^Cartridge) -> (mem: []u8, read_only: bool) #optional_ok {
	if cartridge.chr_rom != nil {
		return cartridge.chr_rom, true
	} else if cartridge.chr_ram != nil {
		return cartridge.chr_ram, false
	}

	panic("either CHR ROM or RAM have to be present")
}

@(require_results)
cartridge_persistant_ram_present :: proc(cartridge: Cartridge) -> bool {
	// Standard NES mappers that use SRAM (save/static RAM) for persistent
	// game saves always rely on a battery. A battery is generally
	// not present without the use of SRAM (for official NES cartridges).
	return cartridge.battery_present && cartridge.prg_ram != nil
}


@(require_results)
cartridge_make_from_filename :: proc(
	filename: string,
) -> (
	cartridge: ^Cartridge,
	err: Maybe(Error),
) {
	rom, e := os.read_entire_file_or_err(filename)
	if e != nil {
		err = errorf(.IO_Error, "could not open file '%s', %v", filename, err, severity = .Fatal)
		return
	}

	defer delete(rom)

	ines, ok := ines_get_from_bytes(rom)
	if !ok {
		err = errorf(.iNES_Error, "file '%s' is not an iNES file", filename, severity = .Fatal)
		return
	}

	info := ines_get_info(ines)
	ines_check_compatability(info) or_return
	ines_check_integrity(info) or_return
	cartridge = cartridge_make_from_ines(ines)

	return
}


@(require_results)
cartridge_make_from_ines :: proc(
	ines: NES20,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	c: ^Cartridge,
	err: runtime.Allocator_Error,
) #optional_allocator_error {
	c = new(Cartridge)

	c.vram = make_slice([]u8, 2 * KB, allocator, loc) or_return
	c.mapper_number = ines.header.mapper_number
	c.submapper_number = ines.header.submapper_number
	c.battery_present = ines.header.battery_present
	c.ines_info = ines_get_info(ines)

	allocate_cartridge_memory(c, ines, allocator, loc) or_return

	// @todo copy nvram for PRG and CHR 
	copy_slice(c.prg_rom, ines.prg_rom)
	copy_slice(c.chr_rom, ines.chr_rom)

	info := ines_get_info(ines)
	c.mapper = mapper_make_from_number(c.mapper_number, info)

	return

	allocate_cartridge_memory :: proc(
		c: ^Cartridge,
		ines: NES20,
		allocator := context.allocator,
		loc := #caller_location,
	) -> runtime.Allocator_Error {
		h := ines.header

		if h.prg_ram_size != 0 {
			c.prg_ram = make_slice([]u8, h.prg_ram_size, allocator, loc) or_return
		}
		if h.prg_rom_size != 0 {
			c.prg_rom = make_slice([]u8, h.prg_rom_size, allocator, loc) or_return
		}
		if h.chr_rom_size != 0 {
			c.chr_rom = make_slice([]u8, h.chr_rom_size, allocator, loc) or_return
		}
		if h.chr_ram_size != 0 {
			c.chr_ram = make_slice([]u8, h.chr_ram_size, allocator, loc) or_return
		}

		return nil
	}
}

cartridge_delete :: proc(
	cartridge: ^Cartridge,
	allocator := context.allocator,
	loc := #caller_location,
) -> runtime.Allocator_Error {
	delete_slice(cartridge.vram, allocator, loc) or_return
	delete_slice(cartridge.prg_rom, allocator, loc) or_return
	delete_slice(cartridge.prg_ram, allocator, loc) or_return
	delete_slice(cartridge.chr_rom, allocator, loc) or_return
	delete_slice(cartridge.chr_ram, allocator, loc) or_return
	cartridge.mapper->delete()

	free(cartridge)

	return .None
}

@(require_results)
cartridge_read_from_address :: proc(
	cartridge: ^Cartridge,
	address: u16,
) -> (
	data: u8,
	err: Maybe(Error),
) {
	switch address {
	case 0x4020 ..< 0x6000:
		// expansion ROM
		err = errorf(
			.Memory_Error,
			"cannot read from $%04X, expansion area not supported ($4020-$5FFF)",
			address,
		)
	case:
		data, err = cartridge.mapper->read_from_address(cartridge, address)
	}
	return
}


@(require_results)
cartridge_write_to_address :: proc(
	cartridge: ^Cartridge,
	data: u8,
	address: u16,
) -> (
	err: Maybe(Error),
) {
	switch address {
	case 0x4020 ..< 0x6000:
		// expansion ROM
		err = errorf(
			.Memory_Error,
			"cannot read from $%04X, expansion area not supported ($4020-$5FFF)",
			address,
		)
	case:
		err = cartridge.mapper->write_to_address(cartridge, data, address)
	}

	return
}

