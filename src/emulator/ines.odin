package emulator

import "core:math"
import "core:os"
import "core:slice"

iNES20 :: struct {
	header:  struct {
		prg_rom_size:                 int,
		prg_ram_size:                 int,
		prg_nvram_size:               int,
		chr_rom_size:                 int,
		chr_ram_size:                 int,
		chr_nvram_size:               int,
		mapper_number:                int,
		submapper_number:             int,
		nametable_arrangement:        enum {
			Vertical, // horizontal mirrored (CIRAM A10 = PPU A11)
			Horizontal, // vertically mirrored (CIRAM A10 = PPU A10)
		},
		battery_present:              bool,
		trainer_present:              bool,
		alternative_nametable_layout: bool,
		tv_system:                    enum {
			NTSC,
			PAL,
		},
		console_type:                 union #no_nil {
			Nintendo_Entertainment_System,
			Nintendo_Vs_System,
			Nintendo_Playchoice_10,
			Extended_Console_Type,
		},
		cpu_ppu_timing_mode:          enum {
			RP2C02,
			RP2C07,
			Multiple_Region,
			UA6538,
		},
		miscellaneous_roms_num:       int,
		default_expansion_device:     int,
	},
	trainer: []byte,
	prg_rom: []byte,
	chr_rom: []byte,
}

Nintendo_Entertainment_System :: struct {
}
Extended_Console_Type :: distinct int
Nintendo_Playchoice_10 :: struct {
}
Nintendo_Vs_System :: struct {
	ppu_type:      int,
	hardware_type: int,
}

iNES_NES_FILE_VARIANT :: enum {
	Arachaic_iNES,
	iNES_07,
	iNES,
	NES_20,
}

@(require_results)
get_ines_from_bytes :: proc(data: []byte) -> (ines: iNES20, ok: bool) #optional_ok {
	if ok = ines_is_nes_file_format(data); !ok do return

	header := ines.header

	// if the MSB nibble is $f, an exponent-mutiplier is used to calculate
	// the PRG-ROM size
	prg_rom_size_msb := data[9] & 0x0f
	prg_rom_size_lsb := data[4]
	if prg_rom_size_msb == 0xff {
		multiplier := int(prg_rom_size_lsb & 0x03)
		exponent := uint(prg_rom_size_lsb & 0xfc)
		header.prg_rom_size = (multiplier * 2 + 1) * (1 << exponent)
	} else {
		header.prg_rom_size = int((prg_rom_size_msb << 4) | prg_rom_size_lsb)
	}


	// if the MSB nibble is $f, an exponent-mutiplier is used to calculate
	// the CHR-ROM size
	chr_rom_size_msb := (data[9] & 0xf0) >> 4
	chr_rom_size_lsb := data[5]
	if chr_rom_size_msb == 0xff {
		multiplier := int(chr_rom_size_lsb & 0x03)
		exponent := uint(chr_rom_size_lsb & 0xfc)
		header.chr_rom_size = (multiplier * 2 + 1) * (1 << exponent)
	} else {
		header.chr_rom_size = int((chr_rom_size_msb << 4) | chr_rom_size_lsb)
	}

	header.nametable_arrangement = (data[6] & 0x01) == 1 ? .Horizontal : .Vertical
	header.battery_present = (data[6] & 0x02) == 1
	header.trainer_present = (data[6] & 0x04) == 1
	header.alternative_nametable_layout = (data[6] & 0x08) == 1
	header.mapper_number = int(
		((data[8] & 0x0f) << 8) | (data[7] & 0xf0) | ((data[6] & 0xf0) >> 4),
	)

	switch data[7] & 0x03 {
	case 0:
		header.console_type = Nintendo_Entertainment_System{}
	case 1:
		header.console_type = Nintendo_Vs_System {
			ppu_type      = int(data[13] & 0x0f),
			hardware_type = int((data[13] & 0xf0) >> 4),
		}
	case 2:
		header.console_type = Nintendo_Playchoice_10{}
	case 3:
		header.console_type = Extended_Console_Type(data[13] & 0x0f)
	}

	header.submapper_number = int((data[8] & 0xf0) >> 4)

	prg_ram_shift_count := data[10] & 0x0f
	if (prg_ram_shift_count != 0) do header.prg_ram_size = 64 << prg_ram_shift_count
	prg_nvram_shift_count := (data[10] & 0xf0) >> 4
	if (prg_nvram_shift_count != 0) do header.prg_nvram_size = 64 << prg_nvram_shift_count

	chr_ram_shift_count := data[11] & 0x0f
	if (chr_ram_shift_count != 0) do header.chr_ram_size = 64 << chr_ram_shift_count
	chr_nvram_shift_count := (data[11] & 0xf0) >> 4
	if (chr_nvram_shift_count != 0) do header.chr_nvram_size = 64 << chr_nvram_shift_count

	switch data[12] & 0x3 {
	case 0:
		header.cpu_ppu_timing_mode = .RP2C02
	case 1:
		header.cpu_ppu_timing_mode = .RP2C07
	case 2:
		header.cpu_ppu_timing_mode = .Multiple_Region
	case 3:
		header.cpu_ppu_timing_mode = .UA6538
	}

	header.miscellaneous_roms_num = int(data[14] & 0x3)
	header.default_expansion_device = int(data[15] & 0x3f)

	prg_rom_size_bytes := header.prg_rom_size * 16 * 1024

	// body
	ines.header = header

	trainer_base := 16
	// assuming no trainer area
	prg_rom_base := 16
	chr_rom_base := 16 + prg_rom_size_bytes
	if header.trainer_present {
		ines.trainer = data[16:16 + 512]
		prg_rom_base += 512
		chr_rom_base += 512
	}

	ines.prg_rom = data[prg_rom_base:prg_rom_base + prg_rom_size_bytes]
	// nes.chr_rom = data[chr_rom_base:chr_rom_base + header.chr_rom_size]

	return
}

@(require_results)
ines_is_nes_file_format :: proc(data: []byte) -> bool {
	// bytes 0-3 should contain $4e $45 $53 $1a
	// (ascii "NES" followed by MS-DOS end-of-file)
	return data[0] == 0x4e && data[1] == 0x45 && data[2] == 0x53 && data[3] == 0x1a
}

@(require_results)
ines_determine_format_variant_from_bytes :: proc(
	data: []byte,
) -> (
	iNES_NES_FILE_VARIANT,
	bool,
) #optional_ok {
	if !ines_is_nes_file_format(data) do return {}, false
	// detection procedure follows the one recommended at
	// https://www.nesdev.org/wiki/INES
	// @todo take into account byte 9 and actual rom size
	if (data[7] & 0x0c == 0x08) do return .NES_20, true
	if (data[7] & 0x0c == 0x04) do return .Arachaic_iNES, true
	if (data[7] & 0x0c == 0x00) && slice.all_of(data[12:15], 0) do return .iNES, true
	return .iNES_07, true
}

