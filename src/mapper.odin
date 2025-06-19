package nemu

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "utils"

Mapper :: union {
	Mapper0,
}

Mapper0 :: struct {
	wram:         []u8,
	prg_rom_lo:   []u8,
	prg_rom_hi:   []u8,
	prg_mirrored: bool,
}

mapper_make_from_ines :: proc(
	ines: NES20,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	mapper: Mapper,
	err: runtime.Allocator_Error,
) #optional_allocator_error {

	prg_mirrored := ines.header.prg_rom_size == 1 ? true : false
	mapper_number := ines.header.mapper_number

	switch mapper_number {
	case 0:
		m := Mapper0{}
		m.prg_rom_lo = make_slice([]u8, 16 * 1024, allocator, loc) or_return
		m.prg_rom_hi = make_slice([]u8, 16 * 1024, allocator, loc) or_return
		m.prg_mirrored = prg_mirrored

		status := copy_slice(m.prg_rom_lo, ines.prg_rom)
		assert(status == 16 * 1024, "did not copy prg rom from rom to mapper correctly")

		mapper = m

	case:
		assert(false, fmt.tprintf("mapper number %d not supported", mapper_number))
	}

	return

}

mapper_delete :: proc(
	mapper: Mapper,
	allocator := context.allocator,
	loc := #caller_location,
) -> runtime.Allocator_Error {
	switch m in mapper {
	case Mapper0:
		delete_slice(m.wram, allocator, loc) or_return
		delete_slice(m.prg_rom_lo, allocator, loc) or_return
		delete_slice(m.prg_rom_hi, allocator, loc) or_return
		// free(mapper) or_return
		return .None
	case:
		assert(false, fmt.tprintf("%v not supported", mapper))
	}

	return .None
}

mapper_read_from_address :: proc(mapper: Mapper, address: u16) -> (data: u8, err: Maybe(Error)) {
	switch m in mapper {
	case Mapper0:
		switch address {
		case 0x6000 ..< 0x8000:
			data = m.wram[address - 0x6000]
		case 0x8000 ..< 0xc000:
			data = m.prg_rom_lo[address - 0x8000]
		case 0xc000 ..= 0xffff:
			if m.prg_mirrored {
				data = m.prg_rom_lo[address - 0xc000]
			} else {
				data = m.prg_rom_hi[address - 0xc000]
			}
		case:
			err = errorf(.Invalid_Address, "mapper cannot read from $%02X", address)
		}
	case:
		assert(false, fmt.tprintf("mapper type %v not supported", mapper))
	}

	return
}


mapper_write_to_address :: proc(mapper: Mapper, address: u16, data: u8) -> (err: Maybe(Error)) {
	switch m in mapper {
	case Mapper0:
		switch address {
		case 0x6000 ..< 0x8000:
			m.wram[address - 0x6000] = data
		case 0x8000 ..= 0xffff:
			err = errorf(
				.Read_Only,
				"mapper cannot write '%02X' to $%02X (read-only memory region, $8000-$FFFF)",
				data,
				address,
			)
		case:
			err = errorf(.Invalid_Address, "mapper cannot write '%02X' to $%02X", data, address)
		}
	case:
		assert(false, fmt.tprintf("mapper type %v not supported", mapper))
	}

	return
}

