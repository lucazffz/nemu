package emulator

import "../utils"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:slice"

Mapper :: union {
	Mapper0,
}

Mapper0 :: struct {
	prg_ram:               []u8,
	prg_rom_lo:            []u8,
	prg_rom_hi:            []u8,
	chr_rom:               []u8,
	prg_mirrored:          bool,
	prg_ram_size_bytes:    int,
	nametable_arrangement: Nametable_Arrangement,
}

@(require_results)
mapper_make_from_ines :: proc(
	ines: iNES20,
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
		m.prg_ram_size_bytes = ines.header.prg_ram_size

		if m.prg_ram_size_bytes != 0 {
			m.prg_ram = make_slice([]u8, m.prg_ram_size_bytes, allocator, loc) or_return
		}

		m.chr_rom = make_slice([]u8, 8 * 1024, allocator, loc) or_return
		m.prg_rom_lo = make_slice([]u8, 16 * 1024, allocator, loc) or_return
		m.prg_rom_hi = make_slice([]u8, 16 * 1024, allocator, loc) or_return
		m.prg_mirrored = prg_mirrored
		m.nametable_arrangement = ines.header.nametable_arrangement

		num_of_copies := copy_slice(m.prg_rom_lo, ines.prg_rom[:16 * 1024])
		assert(
			num_of_copies == 16 * 1024,
			"did not copy PRG-ROM from ROM-file to mapper correctly",
		)

		if !prg_mirrored {
			num_of_copies = copy_slice(m.prg_rom_hi, ines.prg_rom[16 * 1024:])
			assert(
				num_of_copies == 16 * 1024,
				"did not copy PRG-ROM from ROM-file to mapper correctly",
			)
		}

		num_of_copies = copy_slice(m.chr_rom, ines.chr_rom)
		assert(num_of_copies == 8 * 1024, "did not copy CHR-ROM from ROM-file to mapper correctly")

		mapper = m
	case:
		panic(fmt.tprintf("mapper number %d not supported", mapper_number))
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
		delete_slice(m.prg_ram, allocator, loc) or_return
		delete_slice(m.chr_rom, allocator, loc) or_return
		delete_slice(m.prg_rom_lo, allocator, loc) or_return
		delete_slice(m.prg_rom_hi, allocator, loc) or_return
		return .None
	case:
		panic(fmt.tprintf("%v not supported", mapper))
	}

	return .None
}

@(require_results)
mapper_read_from_ppu_address_space :: proc(
	console: ^Console,
	address: u16,
) -> (
	data: u8,
	err: Maybe(Error),
) {
	address := address & 0x3fff
	switch address {
	case 0x0000 ..< 0x2000:
		// pattern tables 0 and 1
		switch m in console.mapper {
		case Mapper0:
			data = m.chr_rom[address]
		case:
			panic(fmt.tprintf("mapper type %v not supported", m))
		}
	case 0x2000 ..= 0x3eff:
		// nametables 0 to 3 (including attribute tables)
		// nametables are mirrored through $3000-$3eff, this is handled
		// by get_nametable_mirror_address
		switch m in console.mapper {
		case Mapper0:
			if m.nametable_arrangement == .Vertical {
				// vertical arrangement gives horizontal mirroring
				address := get_nametable_mirror_address(address, .Horizontal)
				data = console.ppu.vram[address - 0x2000]
			} else {
				// horizontal arrangement gives vertical mirroring
				address := get_nametable_mirror_address(address, .Vertical)
				data = console.ppu.vram[address - 0x2000]
			}
		case:
			panic(fmt.tprintf("mapper type %v not supported", m))
		}
	case:
		err = errorf(.Invalid_Address, "cannot read from $%04X", address)
	}

	return
}

@(require_results)
mapper_write_to_ppu_address_space :: proc(
	console: ^Console,
	data: u8,
	address: u16,
) -> (
	err: Maybe(Error),
) {
	address := address & 0x3fff
	switch address {
	case 0x0000 ..< 0x2000:
		// pattern tables 0 and 1
		switch m in console.mapper {
		case Mapper0:
			err = errorf(
				.Read_Only,
				"cannot write '%02X' to $%04X (read-only $0000-$1FFF)",
				data,
				address,
				severity = .Warning,
			)
		case:
			panic(fmt.tprintf("mapper type %v not supported", m))
		}
	case 0x2000 ..= 0x3eff:
		// nametables 0 to 3 (including attribute tables)
		// nametables are mirrored through $3000-$3eff, this is handled
		// by get_nametable_mirror_address
		switch m in console.mapper {
		case Mapper0:
			// log.debugf("addr: %04X, val: %d", address, data)
			if m.nametable_arrangement == .Vertical {
				// vertical arrangement gives horizontal mirroring
				address := get_nametable_mirror_address(address, .Horizontal)
				console.ppu.vram[address - 0x2000] = data
			} else {
				// horizontal arrangement gives vertical mirroring
				address := get_nametable_mirror_address(address, .Vertical)
				console.ppu.vram[address - 0x2000] = data
			}
		case:
			panic(fmt.tprintf("mapper type %v not supported", m))
		}
	case:
		err = errorf(
			.Invalid_Address,
			"cannot write '%02X' to $%04X",
			data,
			address,
			severity = .Warning,
		)
	}

	return
}

@(require_results)
mapper_read_from_cpu_address_space :: proc(
	mapper: Mapper,
	address: u16,
) -> (
	data: u8,
	err: Maybe(Error),
) {
	switch m in mapper {
	case Mapper0:
		switch address {
		case 0x6000 ..< 0x8000:
			if m.prg_ram_size_bytes == 2 * 1024 {
				address := address & 0x7ff
				data = m.prg_ram[address]
			} else if m.prg_ram_size_bytes == 4 * 1024 {
				address := address & 0xfff
				data = m.prg_ram[address]
			} else {
				err = errorf(
					.Unallocated_Memory,
					"cannot read from $%04X, PRG-RAM memory ($6000-$8000) is unallocated",
					address,
				)
			}
		case 0x8000 ..< 0xc000:
			data = m.prg_rom_lo[address - 0x8000]
		case 0xc000 ..= 0xffff:
			if m.prg_mirrored {
				data = m.prg_rom_lo[address - 0xc000]
			} else {
				data = m.prg_rom_hi[address - 0xc000]
			}
		case:
			err = errorf(.Invalid_Address, "cannot read from $%04X", address)
		}
	case:
		panic(fmt.tprintf("mapper type %v not supported", m))
	}

	return
}

@(require_results)
mapper_write_to_cpu_address_space :: proc(
	mapper: Mapper,
	address: u16,
	data: u8,
) -> (
	err: Maybe(Error),
) {
	switch m in mapper {
	case Mapper0:
		switch address {
		case 0x6000 ..< 0x8000:
			if m.prg_ram_size_bytes == 2 * 1024 {
				address := address & 0x7ff
				m.prg_ram[address] = data
			} else if m.prg_ram_size_bytes == 4 * 1024 {
				address := address & 0xfff
				m.prg_ram[address] = data
			} else {
				err = errorf(
					.Unallocated_Memory,
					"cannot write '%02X' to $%04X, PRG-RAM memory ($6000-$8000) is unallocated",
					data,
					address,
					severity = .Warning,
				)
			}
		case 0x8000 ..= 0xffff:
			err = errorf(
				.Read_Only,
				"cannot write '%02X' to $%04X (read-only, $2000-$9FFF)",
				data,
				address,
				severity = .Warning,
			)
		case:
			err = errorf(
				.Invalid_Address,
				"cannot write '%02X' to $%04X",
				data,
				address,
				severity = .Warning,
			)
		}
	case:
		panic(fmt.tprintf("mapper type %v not supported", m))
	}

	return
}

@(private = "file")
Nametable_Mirroring_Type :: enum {
	Horizontal,
	Vertical,
	Single_Screen_A,
	Single_Screen_B,
	Four_Screen,
}

@(private = "file")
get_nametable_mirror_address :: proc(address: u16, mirroring: Nametable_Mirroring_Type) -> u16 {
	address := address & 0x3fff // keep lower 14 bits

	// handle mirroring of entire nametable region ($3000-$3eff) to
	// primary nametable region ($2000-$2fff)
	if address >= 0x3000 && address <= 0x3eff {
		address -= 0x1000
	}

	// not within nametable region, return masked address
	if !(address >= 0x2000 && address <= 0x2fff) do return address
	// determine which logical nametable the address falls into
	// each nametable is 1KB
	// 0x000-0x3FF -> NT0
	// 0x400-0x7FF -> NT1
	// 0x800-0xBFF -> NT2
	// 0xC00-0xFFF -> NT3
	offset := address - 0x2000
	nametable_bank := offset / 1024
	bank_offset := offset % 1024

	switch mirroring {
	case .Horizontal:
		if nametable_bank == 0 || nametable_bank == 1 {
			// NT0 or NT1 (mirrors NT0) map to the first physical 1KB bank
			return 0x2000 + bank_offset
		} else {
			// NT2 or NT3 (mirrors NT2) map to the second physical 1KB bank
			return 0x2800 + bank_offset
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
		return address
	}

	return address
}

