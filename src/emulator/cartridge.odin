package emulator

import "base:runtime"
import "core:os"

KB :: 1024 // one kibibyte

Cartridge :: struct {
	mapper:           ^Mapper,
	mapper_number:    int,
	submapper_number: int,
	ines_variant:     iNES_File_Variant,
	ines_header:      NES20_Header,
	vram:             []u8,
	prg_rom:          []u8,
	chr_rom:          []u8,
	prg_ram:          []u8, // used as SRAM or WRAM
	chr_ram:          []u8,
	// @todo nvram not used by any official cartridges, perhaps remove
	// prg_nvram:        []u8,
	// chr_nvram:        []u8,
	battery_present:  bool,
	mirroring:        Nametable_Mirroring,
}

Mapper :: struct {
	write_to_address:  proc(m: ^Mapper, c: ^Cartridge, data: u8, address: u16) -> Maybe(Error),
	read_from_address: proc(m: ^Mapper, c: ^Cartridge, address: u16) -> (u8, Maybe(Error)),
	delete:            proc(m: ^Mapper),
}

cartridge_persistant_ram_present :: proc(cartridge: Cartridge) -> bool {
	// Standard NES mappers that use SRAM (save/static RAM) for persistent
	// game saves always rely on a battery. A battery is generally
	// not present without the use of SRAM (for official NES cartridges).
	return cartridge.battery_present && cartridge.prg_ram != nil
}

cartridge_nametable_arrangement_to_mirroring :: proc(
	arrangement: Nametable_Arrangement,
) -> (
	mirroring: Nametable_Mirroring,
) {
	switch arrangement {
	case .Vertical:
		mirroring = .Horizontal
	case .Horizontal:
		mirroring = .Vertical
	}

	return
}

cartridge_make_from_filename :: proc(filename: string) -> (^Cartridge, Maybe(Error)) {
	rom, err := os.read_entire_file_or_err(filename)
	if err != nil {
		return nil, errorf(
			.IO_Error,
			"could not open file '%s', %v",
			filename,
			err,
			severity = .Fatal,
		)

	}

	defer delete(rom)

	if ok := ines_is_nes_file_format(rom); !ok {
		return nil, errorf(
			.iNES_Error,
			"file '%s' is not an iNES file",
			filename,
			severity = .Fatal,
		)
	}

	ines_variant := ines_determine_format_variant_from_bytes(rom)
	if ines_variant != .NES_20 && ines_variant != .iNES {
		return nil, errorf(
			.iNES_Error,
			"file '%s' is of iNES variant '%v', only iNES 1.0 and 2.0 supported",
			filename,
			ines_variant,
			severity = .Fatal,
		)
	}

	ines := get_ines_from_bytes(rom)


	if err := console_vet_ines(ines); err != nil {
		return nil, err
	}

	return cartridge_make_from_ines(ines), nil
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
	c.mirroring = cartridge_nametable_arrangement_to_mirroring(ines.header.nametable_arrangement)
	c.battery_present = ines.header.battery_present
	c.ines_variant = ines.file_variant
	c.ines_header = ines.header

	allocate_cartridge_memory(c, ines, allocator, loc) or_return

	// @todo copy nvram for PRG and CHR 
	copy_slice(c.prg_rom, ines.prg_rom)
	copy_slice(c.chr_rom, ines.chr_rom)

	assign_mapper(c, c.mapper_number)

	return

	assign_mapper :: proc(c: ^Cartridge, mapper_number: int) {
		switch mapper_number {
		case 0:
			c.mapper = &mapper0_make().m
		case 1:
			c.mapper = &mapper1_make().m
		case 2:
			c.mapper = &mapper2_make().m
		case 3:
			c.mapper = &mapper3_make().m
		case:
			panic("mapper not supported")
		}
	}

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
		// if h.prg_nvram_size != 0 {
		// 	c.prg_nvram = make_slice([]u8, h.prg_nvram_size, allocator, loc) or_return
		// }
		if h.chr_rom_size != 0 {
			c.chr_rom = make_slice([]u8, h.chr_rom_size, allocator, loc) or_return
		}
		if h.chr_ram_size != 0 {
			c.chr_ram = make_slice([]u8, h.chr_ram_size, allocator, loc) or_return
		}
		// if h.chr_nvram_size != 0 {
		// 	c.chr_nvram = make_slice([]u8, h.chr_nvram_size, allocator, loc) or_return
		// }

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
	// delete_slice(cartridge.prg_nvram, allocator, loc) or_return
	delete_slice(cartridge.chr_rom, allocator, loc) or_return
	delete_slice(cartridge.chr_ram, allocator, loc) or_return
	// delete_slice(cartridge.chr_nvram, allocator, loc) or_return
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
			"cannot read from $%04X, expansion area not supported by mapper 0($4020-$5FFF)",
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
			"cannot read from $%04X, expansion area not supported by mapper 0($4020-$5FFF)",
			address,
		)
	case:
		err = cartridge.mapper->write_to_address(cartridge, data, address)
	}

	return
}

Nametable_Mirroring :: enum {
	Horizontal,
	Vertical,
	Single_Screen_A,
	Single_Screen_B,
	Four_Screen,
}

get_nametable_mirror_address :: proc(address: u16, mirroring: Nametable_Mirroring) -> u16 {
	addr := address & 0x3fff // keep lower 14 bits

	// handle mirroring of entire nametable region ($3000-$3eff) to
	// primary nametable region ($2000-$2fff)
	if addr >= 0x3000 && addr <= 0x3eff {
		addr -= 0x1000
	}

	// not within nametable region, return masked address
	if !(addr >= 0x2000 && addr <= 0x2fff) do return addr
	// determine which logical nametable the address falls into
	// each nametable is 1KB
	// 0x000-0x3FF -> NT0
	// 0x400-0x7FF -> NT1
	// 0x800-0xBFF -> NT2
	// 0xC00-0xFFF -> NT3
	offset := addr - 0x2000
	nametable_bank := offset / 1024
	bank_offset := offset % 1024

	switch mirroring {
	case .Horizontal:
		if nametable_bank == 0 || nametable_bank == 1 {
			// NT0 or NT1 (mirrors NT0) map to the first physical 1KB bank
			return 0x2000 + bank_offset
		} else {
			// NT2 or NT3 (mirrors NT2) map to the second physical 1KB bank
			return 0x2400 + bank_offset
		}
	case .Vertical:
		if nametable_bank == 0 || nametable_bank == 2 {
			// NT0 or NT2 (mirrors NT0) map to the first physical 1KB bank
			return 0x2000 + bank_offset
		} else {
			// NT1 or NT3 (mirrors NT1) map to the second physical 1KB bank
			return 0x2400 + bank_offset
		}
	case .Single_Screen_A:
		// all nametables map to the first physical 1KB bank ($2000-$23FF)
		return 0x2000 + bank_offset
	case .Single_Screen_B:
		// all nametables map to the second physical 1KB bank ($2400-$27FF)
		return 0x2400 + bank_offset
	case .Four_Screen:
		// no mirroring, all 4 logical nametables are distinct
		return addr
	}

	return addr
}

