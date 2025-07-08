package emulator

import "base:runtime"
import "core:fmt"

KB :: 1024 // one kibibyte

Cartridge :: struct {
	mapper:                Mapper,
	vram:                  []u8,
	prg_rom:               []u8,
	chr_rom:               []u8,
	prg_ram:               []u8, // can be used as save RAM
	chr_ram:               []u8,
	prg_nv_ram:            []u8,
	chr_nv_ram:            []u8,
	battery_present:       bool,
	nametable_arrangement: Nametable_Arrangement,
}

Mapper :: union {
	Mapper0,
}

Mapper0 :: struct {
	// does not perform any banking
}

Mapper1 :: struct {
}

cartridge_persistant_ram_present :: proc(cartridge: Cartridge) -> bool {
	// Standard NES mappers that use SRAM (save/static RAM) for persistent
	// game saves always rely on a battery. A battery is generally
	// not present without the use of SRAM (for official NES cartridges).
	return cartridge.battery_present
}

@(require_results)
cartridge_make_from_ines :: proc(
	ines: iNES20,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	c: Cartridge,
	err: runtime.Allocator_Error,
) #optional_allocator_error {
	mapper_number := ines.header.mapper_number
	header := ines.header

	c.vram = make_slice([]u8, 2 * KB, allocator, loc) or_return

	switch mapper_number {
	case 0:
		c.mapper = Mapper0{}
		c.battery_present = false
		c.nametable_arrangement = header.nametable_arrangement

		c.prg_ram = make_slice([]u8, header.prg_ram_size, allocator, loc) or_return
		c.prg_rom = make_slice([]u8, header.prg_rom_size, allocator, loc) or_return
		c.chr_rom = make_slice([]u8, header.chr_rom_size, allocator, loc) or_return

		copy_slice(c.prg_rom, ines.prg_rom)
		copy_slice(c.chr_rom, ines.chr_rom)
	}

	return
}


cartridge_delete :: proc(
	cartridge: Cartridge,
	allocator := context.allocator,
	loc := #caller_location,
) -> runtime.Allocator_Error {
	delete_slice(cartridge.vram, allocator, loc) or_return
	delete_slice(cartridge.prg_rom, allocator, loc) or_return
	delete_slice(cartridge.prg_ram, allocator, loc) or_return
	delete_slice(cartridge.prg_nv_ram, allocator, loc) or_return
	delete_slice(cartridge.chr_rom, allocator, loc) or_return
	delete_slice(cartridge.chr_ram, allocator, loc) or_return
	delete_slice(cartridge.chr_nv_ram, allocator, loc) or_return

	return .None
}

@(require_results)
cartridge_read_from_ppu_address :: proc(
	cartridge: Cartridge,
	address: u16,
) -> (
	data: u8,
	err: Maybe(Error),
) {
	c := cartridge
	switch m in c.mapper {
	case Mapper0:
		switch address {
		case 0x0000 ..< 0x2000:
			data = c.chr_rom[address]
		case 0x2000 ..= 0x3eff:
			if c.nametable_arrangement == .Vertical {
				// vertical arrangement gives horizontal mirroring
				addr := get_nametable_mirror_address(address, .Horizontal)
				data = c.vram[addr - 0x2000]
			} else {
				// horizontal arrangement gives vertical mirroring
				addr := get_nametable_mirror_address(address, .Vertical)
				data = c.vram[addr - 0x2000]
			}
		case:
			err = errorf(.Invalid_Address, "cannot read from $%04X", address)
		}
	case:
		panic("mapper not supported")
	}

	return
}

@(require_results)
cartridge_write_to_ppu_address :: proc(
	cartridge: Cartridge,
	data: u8,
	address: u16,
) -> (
	err: Maybe(Error),
) {
	c := cartridge
	switch m in c.mapper {
	case Mapper0:
		switch address {
		case 0x0000 ..< 0x2000:
			err = errorf(
				.Read_Only,
				"cannot write '%02X' to $%04X (read-only $0000-$1FFF)",
				data,
				address,
				severity = .Warning,
			)
		case 0x2000 ..= 0x3eff:
			if c.nametable_arrangement == .Vertical {
				// vertical arrangement gives horizontal mirroring
				addr := get_nametable_mirror_address(address, .Horizontal)
				c.vram[addr - 0x2000] = data
			} else {
				// horizontal arrangement gives vertical mirroring
				addr := get_nametable_mirror_address(address, .Vertical)
				c.vram[addr - 0x2000] = data
			}
		case:
			err = errorf(.Invalid_Address, "cannot read from $%04X", address)
		}
	case:
		panic("mapper not supported")
	}

	return
}

@(require_results)
cartridge_read_from_cpu_address :: proc(
	cartridge: Cartridge,
	address: u16,
) -> (
	data: u8,
	err: Maybe(Error),
) {
	c := cartridge
	switch m in c.mapper {
	case Mapper0:
		switch address {
		case 0x4020 ..< 0x6000:
			// expansion ROM
			err = errorf(
				.Unallocated_Memory,
				"cannot read from $%04X, expansion area not supported by mapper 0($4020-$5FFF)",
				address,
			)
		case 0x6000 ..< 0x8000:
			if len(c.prg_ram) == 2 * KB {
				data = c.prg_ram[address & 0x7ff]
			} else if len(c.prg_ram) == 4 * KB {
				data = c.prg_ram[address & 0xfff]
			} else {
				err = errorf(
					.Unallocated_Memory,
					"cannot read from $%04X, PRG-RAM memory ($6000-$8000) is unallocated",
					address,
				)
			}
		case 0x8000 ..= 0xffff:
			addr := address - 0x8000
			// If the PRG ROM size is 16 KB, mask out the highest
			// 3 bits of the address to mirror.
			if len(c.prg_rom) == 16 * KB {
				if addr >= 0x4000 {
					addr -= 0x4000
				}
			}
			data = c.prg_rom[addr]
		case:
			err = errorf(.Invalid_Address, "cannot read from $%04X", address)
		}
	case:
		panic("mapper not supported")
	}

	return
}


@(require_results)
cartridge_write_to_cpu_address :: proc(
	cartridge: Cartridge,
	data: u8,
	address: u16,
) -> (
	err: Maybe(Error),
) {
	c := cartridge
	switch m in c.mapper {
	case Mapper0:
		switch address {
		case 0x4020 ..< 0x6000:
			// expansion ROM
			err = errorf(
				.Invalid_Address,
				"cannot write to $04X, expansion area not supported by mapper 0 ($4020-$5FFF)",
				address,
			)
		case 0x6000 ..< 0x8000:
			if len(c.prg_ram) == 2 * 1024 {
				addr := address & 0x7ff
				c.prg_ram[addr] = data
			} else if len(c.prg_ram) == 4 * 1024 {
				addr := address & 0xfff
				c.prg_ram[addr] = data
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

