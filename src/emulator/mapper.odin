package emulator

SUPPORTED_MAPPERS :: []int{0, 1, 2, 3, 4}

Mapper :: struct {
	write_to_address:      proc(m: ^Mapper, c: ^Cartridge, data: u8, address: u16) -> Maybe(Error),
	read_from_address:     proc(m: ^Mapper, c: ^Cartridge, address: u16) -> (u8, Maybe(Error)),
	verify_ines_integrity: proc(info: iNES_Info) -> Maybe(Error),
	delete:                proc(m: ^Mapper),
}


mapper_make_from_number :: proc(
	mapper_number: int,
	nametable_arrangement: Nametable_Arrangement,
) -> ^Mapper {
	switch mapper_number {
	case 0:
		return &mapper0_make(nametable_arrangement).m
	case 1:
		return &mapper1_make(nametable_arrangement).m
	case 2:
		return &mapper2_make(nametable_arrangement).m
	case 3:
		return &mapper3_make(nametable_arrangement).m
	case 4:
		return &mapper4_make(nametable_arrangement).m
	case:
		panic("mapper not supported")
	}
}

@(require_results)
nametable_arrangement_to_mirroring :: proc(
	arrangement: Nametable_Arrangement,
	alternative: Nametable_Mirroring = .Four_Screen,
) -> (
	mirroring: Nametable_Mirroring,
) {
	// Vertical nametable arrangement causes horizontal nametable
	// mirroring and likwise horizontal nametable arrangement
	// causes vertical nametable mirroring.
	switch arrangement {
	case .Vertical:
		mirroring = .Horizontal
	case .Horizontal:
		mirroring = .Vertical
	case .Alternative_Layout:
		mirroring = alternative
	}

	return
}

@(require_results)
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

