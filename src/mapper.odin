package nemu

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"

Mapper :: struct {
	read_from_address:  proc(mapper: ^Mapper, address: u16) -> (u8, Memory_Error),
	write_to_address:   proc(mapper: ^Mapper, address: u16, data: u8) -> Memory_Error,
	fill_from_ines_rom: proc(mapper: ^Mapper, rom: NES20),
}

Mapper0 :: struct {
	using mapper: Mapper,
	wram:         []u8,
	prg_rom_lo:   []u8,
	prg_rom_hi:   []u8,
	prg_mirrored: bool,
}

mapper0_make :: proc(
	prg_mirrored := true,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	mapper: ^Mapper0,
	err: runtime.Allocator_Error,
) #optional_allocator_error {
	mapper = new(Mapper0, allocator, loc) or_return
	mapper.wram = make_slice([]u8, 8 * 1024, allocator, loc) or_return
	mapper.prg_rom_lo = make_slice([]u8, 16 * 1024, allocator, loc) or_return
	mapper.prg_rom_hi = make_slice([]u8, 16 * 1024, allocator, loc) or_return
	mapper.mapper = {
		mapper0_read_from_address,
		mapper0_write_to_address,
		mapper0_fill_from_ines_rom,
	}
	mapper.prg_mirrored = prg_mirrored
	return
}


mapper0_delete :: proc(
	mapper: ^Mapper0,
	allocator := context.allocator,
	loc := #caller_location,
) -> runtime.Allocator_Error {
	delete_slice(mapper.wram, allocator, loc) or_return
	delete_slice(mapper.prg_rom_lo, allocator, loc) or_return
	delete_slice(mapper.prg_rom_hi, allocator, loc) or_return
	free(mapper) or_return
	return .None
}

mapper0_read_from_address :: proc(
	mapper: ^Mapper,
	address: u16,
) -> (
	data: u8,
	error: Memory_Error,
) {
	mapper := cast(^Mapper0)mapper

	switch address {
	case 0x6000 ..< 0x8000:
		data = mapper.wram[address - 0x6000]
	case 0x8000 ..< 0xc000:
		data = mapper.prg_rom_lo[address - 0x8000]
	case 0xc000 ..< 0xffff:
		if mapper.prg_mirrored {
			data = mapper.prg_rom_lo[address - 0xc000]
			// fmt.printf("%x", data)
		} else {
			data = mapper.prg_rom_hi[address - 0xc000]
		}
	case:
		error = .Invalid_Address
	}

	return
}

mapper0_write_to_address :: proc(
	mapper: ^Mapper,
	address: u16,
	data: u8,
) -> (
	error: Memory_Error,
) {
	mapper := cast(^Mapper0)mapper

	switch address {
	case 0x6000 ..< 0x8000:
		mapper.wram[address - 0x6000] = data
	case 0x8000 ..< 0xc000:
		mapper.prg_rom_lo[address - 0x8000] = data
	case 0xc000 ..< 0xffff:
		mapper.prg_rom_lo[address - 0xc000] = data
	// error = .Read_Only
	case:
		error = .Invalid_Address
	}

	return
}

mapper0_fill_from_ines_rom :: proc(mapper: ^Mapper, rom: NES20) {
	mapper := cast(^Mapper0)mapper
	status := copy_slice(mapper.prg_rom_lo, rom.prg_rom)
}

mapper_make :: proc {
	mapper0_make,
}

mapper_delete :: proc {
	mapper0_delete,
}

