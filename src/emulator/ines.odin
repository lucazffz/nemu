package emulator

import "core:fmt"
import "core:slice"

NES20_Header :: struct {
	// all sizes are in units of bytes
	prg_rom_size:                 int,
	prg_ram_size:                 int,
	prg_nvram_size:               int,
	chr_rom_size:                 int,
	chr_ram_size:                 int,
	chr_nvram_size:               int,
	misc_rom_size:                int,
	mapper_number:                int,
	submapper_number:             int,
	nametable_arrangement:        Nametable_Arrangement,
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
}

NES20 :: struct {
	header:       NES20_Header,
	file_variant: iNES_File_Variant,
	trainer:      []byte,
	prg_rom:      []byte,
	chr_rom:      []byte,
	misc_rom:     []byte,
}

Nametable_Arrangement :: enum {
	Vertical,
	Horizontal,
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

iNES_File_Variant :: enum {
	Arachaic_iNES,
	iNES_07,
	iNES,
	NES_20,
}

iNES_Info :: struct {
	header:       NES20_Header,
	file_variant: iNES_File_Variant,
}

ines_check_compatability :: proc(info: iNES_Info) -> Maybe(Error) {
	h := info.header
	if !slice.contains(SUPPORTED_MAPPERS, h.mapper_number) {
		return errorf(.iNES_Error, "mapper %d is not supported", h.mapper_number)
	}

	if h.tv_system != .NTSC {
		return errorf(.iNES_Error, "TV system %v is not supported", h.tv_system)
	}

	if _, ok := h.console_type.(Nintendo_Entertainment_System); !ok {
		return errorf(.iNES_Error, "console system %v is not supported", h.console_type)
	}

	if h.cpu_ppu_timing_mode != .RP2C02 {
		return errorf(.iNES_Error, "timing mode %v is not supported", h.cpu_ppu_timing_mode)
	}

	if info.file_variant != .NES_20 && info.file_variant != .iNES {
		return errorf(
			.iNES_Error,
			"is of iNES variant '%v', only iNES 1.0 and 2.0 supported",
			info.file_variant,
			severity = .Fatal,
		)
	}

	return nil
}

ines_check_integrity :: proc(info: iNES_Info) -> Maybe(Error) {
	mapper := mapper_make_from_number(info.header.mapper_number)
	defer mapper->delete()
	return mapper.verify_ines_integrity(info)
}

@(require_results)
ines_info_to_string :: proc(info: iNES_Info) -> string {
	template := `File Variant:                 %v
Mapper Number:                %d
Mapper Subnumber:             %d

Nametable Arrangement:        %v
Alternative Nametable Layout: %s

TV System:                    %v
Console Type:                 %v
CPU PPU Timing Mode:          %v
		
Battery Present:              %s
Trainer Present:              %s

PRG ROM size:                 %dKB (%dB)
PRG RAM size:                 %dKB (%dB)
PRG NVRAM size:               %dKB (%dB)

CHR ROM size:                 %dKB (%dB)
CHR RAM size:                 %dKB (%dB)
CHR NVRAM size:               %dKB (%dB)

Miscellanious ROM size:       %dKB (%dB)
Miscellanious ROM Num:        %d
Default Expansion Device:     %d`


	h := info.header
	return fmt.tprintfln(
		template,
		info.file_variant,
		h.mapper_number,
		h.submapper_number,
		h.nametable_arrangement,
		bool_to_str(h.alternative_nametable_layout),
		h.tv_system,
		h.console_type,
		h.cpu_ppu_timing_mode,
		bool_to_str(h.battery_present),
		bool_to_str(h.trainer_present),
		h.prg_rom_size / KB,
		h.prg_rom_size,
		h.prg_ram_size / KB,
		h.prg_ram_size,
		h.prg_nvram_size / KB,
		h.prg_nvram_size,
		h.chr_rom_size / KB,
		h.chr_rom_size,
		h.chr_ram_size / KB,
		h.chr_ram_size,
		h.chr_nvram_size / KB,
		h.chr_nvram_size,
		h.misc_rom_size / KB,
		h.misc_rom_size,
		h.miscellaneous_roms_num,
		h.default_expansion_device,
	)

	bool_to_str :: proc(val: bool) -> string {
		if val do return "true"
		return "false"
	}
}


ines_get_info :: proc(ines: NES20) -> iNES_Info {
	return iNES_Info{header = ines.header, file_variant = ines.file_variant}
}

@(require_results)
ines_get_from_bytes :: proc(data: []byte) -> (ines: NES20, ok: bool) #optional_ok {
	if ok = ines_is_nes_file_format(data); !ok do return

	variant := ines_determine_format_variant_from_bytes(data)

	header := ines.header

	// if the most significant nibble is 0xF, an exponent-mutiplier
	// is used to calculate the PRG-ROM size
	prg_rom_size_msb := data[9] & 0x0f
	prg_rom_size_lsb := data[4]
	if prg_rom_size_msb == 0xf {
		multiplier := int(prg_rom_size_lsb & 0x03)
		exponent := uint(prg_rom_size_lsb & 0xfc)
		header.prg_rom_size = (multiplier * 2 + 1) * (1 << exponent)
	} else {
		header.prg_rom_size = int((prg_rom_size_msb << 4) | prg_rom_size_lsb) * 16 * KB
	}


	// if the most signitifcant nibble is 0xF, an exponent-mutiplier
	// is used to calculate the CHR-ROM size
	chr_rom_size_msb := (data[9] & 0xf0) >> 4
	chr_rom_size_lsb := data[5]
	if chr_rom_size_msb == 0xf {
		multiplier := int(chr_rom_size_lsb & 0x03)
		exponent := uint(chr_rom_size_lsb & 0xfc)
		header.chr_rom_size = (multiplier * 2 + 1) * (1 << exponent)
	} else {
		header.chr_rom_size = int((chr_rom_size_msb << 4) | chr_rom_size_lsb) * 8 * KB
	}

	header.nametable_arrangement = (data[6] & 0x01) == 1 ? .Horizontal : .Vertical
	header.battery_present = (data[6] & 0x02) > 0
	header.trainer_present = (data[6] & 0x04) > 0
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

	// backwards compatability with iNES
	if variant == .iNES {
		// if both CHR RAM and ROM are 0, default to 8KB CHR RAM
		if header.chr_rom_size == 0 && header.chr_ram_size == 0 {
			header.chr_ram_size = 8 * KB
		}

		// support iNES flag 8 and 9 (rarely used specification extensions)
		header.prg_ram_size = data[8] > 0 ? int(data[8]) * 8 * KB : 8 * KB // 0 infers 8KB
		header.tv_system = auto_cast (data[9] & 0x1)
	}

	// body
	ines.header = header

	prg_rom_base := 16
	if header.trainer_present {
		ines.trainer = data[16:16 + 512]
		prg_rom_base += 512
	}

	chr_rom_base := prg_rom_base + header.prg_rom_size
	misc_rom_base := chr_rom_base + header.chr_rom_size

	ines.prg_rom = data[prg_rom_base:prg_rom_base + header.prg_rom_size]
	ines.chr_rom = data[chr_rom_base:chr_rom_base + header.chr_rom_size]

	// misc rom size inferred from file size
	ines.misc_rom = data[misc_rom_base:]
	ines.header.misc_rom_size = len(ines.misc_rom)

	ines.file_variant = variant

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
	iNES_File_Variant,
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

