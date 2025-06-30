package emulator

import "core:fmt"
import "core:log"

Color :: distinct [4]u8

Loopy_Register :: bit_field u16 {
	coarse_x:    u16 | 5,
	coarse_y:    u16 | 5,
	nametable_x: u16 | 1,
	nametable_y: u16 | 1,
	fine_y:      u16 | 3,
	_unused:     u16 | 1,
}

PPU :: struct {
	// Miscellaneous settings ($2000 write-only)
	// mmio_register_bank:     struct {
	ctrl:                    bit_field u8 {
		nametable_base_address:           u8   | 2, // 0: $2000, 1: $2400, 2: $2800, 3: $2C00
		vram_address_increment:           u8   | 1, // 0: add 1, going across, 1: add 32 going down
		sprite_pattern_table_address:     u8   | 1, // 0: $0000, 1: $1000 (ignored for 8x16 sprites)
		background_pattern_table_address: u8   | 1, // 0: $0000, 1: $1000
		sprite_size:                      u8   | 1, // 0: 8x8 pixels, 1: 8x16 pixels (see PPU OAM#byte 1)
		master_slave_select:              u8   | 1, // 0: read backdrop from EXT pins, 1: output color on EXT pins
		vblank_nmi_enable:                bool | 1, // 0: off, 1: on
	},
	// Rendering settings ($2001 write-only)
	mask:                    bit_field u8 {
		greyscale:                   bool | 1, // 0: normal color, 1: greyscale
		show_background_in_margin:   bool | 1, // 0: hide, 1: show background in leftmost 8 pixels of screen
		show_sprites_in_margin:      bool | 1, // 0: hide, 1: show sprites in leftmost 8 pixels of screen
		enable_background_rendering: bool | 1,
		enable_sprite_rendering:     bool | 1,
		emphasize_red:               bool | 1, // green on PAL/Dendy
		emphasize_green:             bool | 1, // red on PAL/Dendy
		emphasize_blue:              bool | 1,
	},
	// Rendering events ($2002 read-only)
	status:                  bit_field u8 {
		_unused:         u8   | 5,
		sprite_overflow: bool | 1,
		sprite_0_hit:    bool | 1,
		vblank:          bool | 1, // cleared on read (unreliable)
	},
	// Sprite RAM address ($2003 write-only)
	// oamaddr:             u8,
	// Sprite RAM data ($2004 read-write)
	// oamdata:   u8,
	// X and Y scroll ($2005 write-only)
	// ppuscroll:           u8,
	// VRAM address ($2006 write-only)
	// ppuaddr:   Loopy_Register,
	// VRAM data ($2007 read-write)
	// ppudata:   u8,
	// Sprite DMA ($4014 write-only)
	// oamdma:              u8,
	// },
	// internal_register_bank: struct {
	read_buffer:             u8,
	v:                       Loopy_Register, // current VRAM address
	t:                       Loopy_Register, // temporary VRAM address (addr of top left onscreen tile)
	x:                       u8, // fine x scroll, 3 bits
	w:                       u8, // first or second byte write toggle, 1 bit
	// },
	// pattern_table:         []u8,
	// nametable:             []u8,
	vram:                    []u8,
	oam:                     []u8,
	palette:                 []u8,
	// is_rendering:            bool,
	// frame_complete:         bool,
	frame_count:             u64,
	cycle:                   int,
	scanline:                int,
	pixel_buffer:            []Color,
	cycle_count:             int,
	bg_next_tile_id:         u8,
	bg_next_tile_attribute:  u8,
	bg_next_tile_lsb:        u8,
	bg_next_tile_msb:        u8,
	bg_shifter_pattern_lo:   u16,
	bg_shifter_pattern_hi:   u16,
	bg_shifter_attribute_lo: u16,
	bg_shifter_attribute_hi: u16,
}

@(require_results)
ppu_read_from_mmio_register :: proc(
	console: ^Console,
	address_offset: u8,
) -> (
	data: u8,
	err: Maybe(Error),
) {

	switch address_offset {
	case 0:
		// PPUSTATUS - Miscellaneous settings ($2000 write-only)
		err = error(.Write_Only, "cannot read from $2000, PPUCTRL is write-only", .Warning)
	case 1:
		// PPUMASK - Rendering settings ($2001 write-only)
		err = error(.Write_Only, "cannot read from $2001, PPUMASK is write-only", .Warning)
	case 2:
		// PPUSTATUS - Rendering events ($2002 read-only)
		data = (u8(console.ppu.status) & 0xe0) | (console.ppu.read_buffer & 0x1f)
		// reading has the side effect of clearing w and vblank
		console.ppu.w = 0
		console.ppu.status.vblank = false
	case 3:
		// OAMADDR - Sprite RAM address ($2003 write-only)
		err = error(.Write_Only, "cannot read from $2003, OAMADDR is write-only", .Warning)
	case 4:
	// OAMDATA - Sprite RAM data ($2004 read-write)
	// @todo implement
	// data = ppu_oam_read_from_address(
	// 	&console.ppu,
	// 	console.ppu.mmio_register_bank.oamaddr,
	// ) or_return
	case 5:
		// PPUSCROLL - X and Y scroll ($2005 write-only)
		err = error(.Write_Only, "cannot read from $2005, PPUSCROLL is write-only", .Warning)
	case 6:
		// PPUADDR - VRAM address ($2006 write-only)
		err = error(.Write_Only, "cannot read from $2006, PPUADDR is write-only", .Warning)
	case 7:
		// PPUDATA - VRAM data ($2007 read-write)
		// When reading from PPUDATA, the data is provided by a buffer due
		// to slow PPU bus speeds. The buffer is then updated with a new
		// value from VRAM[PPUADDR]. The buffer is ONLY updated after a read
		data = console.ppu.read_buffer
		console.ppu.read_buffer = ppu_read_from_address(console, u16(console.ppu.v))

		// the palette memory doesnt have this delay since its internal
		// to the ppu
		if u16(console.ppu.v) > 0x3f00 do data = console.ppu.read_buffer

		ppu_increment_loopy_register(&console.ppu.v, console.ppu.ctrl.vram_address_increment == 1)

	// if console.ppu.ctrl.vram_address_increment == 0 {
	// 	// @todo fix
	// 	// console.ppu.t += auto_cast 1
	// } else {
	// 	// @todo fix
	// 	// console.ppu.mmio_register_bank.ppuaddr += 32
	// }
	case:
		panic(fmt.tprintf("unrecognized PPU register at address offset %02x", address_offset))
	}

	// ppu_oam_read_from_address :: proc(ppu: ^PPU, address: u8) -> (data: u8, err: Maybe(Error)) {
	// 	data = ppu.oam[address]
	// 	return
	// }

	return
}

write_to_oamdma :: proc(console: ^Console, data: u8) {
	// @todo stall CPU for 513 or 514 cycles after writing
	// Writing to OAMDMA will cause an entire RAM page to be copied into OAM.
	// This is implemented as 256 pairs of RAM reads and OAMDATA writes in the
	// original hardware.
	// if console.ppu.is_rendering do return

	// console.ppu.mmio_register_bank.oamdma = data
	num_of_copies := copy(console.ppu.oam, console.ram[data:data + 255])
	assert(
		num_of_copies == 256,
		fmt.tprintf(
			"did not copy from RAM to OAM correctly, expected 256 bytes to be copied, only %d was",
			num_of_copies,
		),
	)
	// @fix should this be included?
	// console.ppu.mmio_register_bank.oamaddr = 0 // OAMADDR will be reset
	return
}

@(require_results)
ppu_write_to_mmio_register :: proc(
	console: ^Console,
	data: u8,
	address_offset: u8,
) -> (
	err: Maybe(Error),
) {
	switch address_offset {
	case 0:
		// PPUSTATUS - Miscellaneous settings ($2000 write-only)
		console.ppu.ctrl = auto_cast data
		console.ppu.t.nametable_x = u16(data & 0x1)
		console.ppu.t.nametable_y = u16((data >> 1) & 0x1)
	case 1:
		// PPUMASK - Rendering settings ($2001 write-only)
		console.ppu.mask = auto_cast data
	case 2:
		// PPUSTATUS - Rendering events ($2002 read-only)
		err = errorf(
			.Read_Only,
			"cannot write '%02X' to $2002, PPUSTATUS is read-only",
			data,
			severity = .Warning,
		)
	case 3:
	// OAMADDR - Sprite RAM address ($2003 write-only)
	// @todo implement
	// console.ppu.t = auto_cast data
	case 4:
	// OAMDATA - Sprite RAM data ($2004 read-write)
	// @todo implement
	// if console.ppu.is_rendering {
	// 	// do not write if rendering
	// 	// preform buggy OAMADDR increment using only 6 highest bits
	// 	// @todo maybe remove buggy increment
	// 	addr := console.ppu.mmio_register_bank.oamaddr
	// 	addr = (((addr >> 2) + 1) << 2) | (addr & 0x3)
	// 	console.ppu.mmio_register_bank.oamaddr = addr
	// } else {
	// console.ppu.mmio_register_bank.oamdata = data
	// // when writing to OAMDATA, the data is immediately written to OAM
	// ppu_oam_write_to_address(
	// 	&console.ppu,
	// 	data,
	// 	console.ppu.mmio_register_bank.oamaddr,
	// ) or_return
	// // writes will increment OAMADDR after write to OAMDATA, reads do not
	// console.ppu.mmio_register_bank.oamaddr += 1
	// }
	case 5:
		// PPUSCROLL - X and Y scroll ($2005 write-only)
		if console.ppu.w == 0 {
			console.ppu.x = (data & 0x7)
			console.ppu.t.coarse_x = u16(data >> 3)
			console.ppu.w = 1
		} else {
			console.ppu.t.fine_y = u16(data & 0x7)
			console.ppu.t.coarse_y = u16(data >> 3)
			console.ppu.w = 0
		}
	case 6:
		// PPUADDR - VRAM address ($2006 write-only)
		if console.ppu.w == 0 {
			// if w is 0, write high byte and set w
			console.ppu.t = auto_cast ((u16(data & 0x3f) << 8) | (u16(console.ppu.t) & 0x00ff))
			console.ppu.w = 1
		} else {
			// if w is 1, write low byte and clear w
			console.ppu.t = auto_cast ((u16(console.ppu.t) & 0xff00) | u16(data))
			console.ppu.v = console.ppu.t // write to v when have full address
			console.ppu.w = 0
		}
	case 7:
		// PPUDATA - VRAM data ($2007 read-write)
		// when writing to PPUDATA, the data is immediately written to VRAM
		// @todo implement increment behaviour during rendering
		err = ppu_write_to_address(console, data, u16(console.ppu.v))
		ppu_increment_loopy_register(&console.ppu.v, console.ppu.ctrl.vram_address_increment == 1)
	case:
		panic(fmt.tprintf("unrecognized PPU register at address offset %02x", address_offset))
	}

	// ppu_oam_write_to_address :: proc(ppu: ^PPU, data: u8, address: u8) -> (err: Maybe(Error)) {
	// 	ppu.oam[address] = data
	// 	return
	// }
	return
}

@(require_results)
ppu_write_to_address :: proc(console: ^Console, data: u8, address: u16) -> Maybe(Error) {
	address := address & 0x3fff
	switch address {
	case 0x0000 ..< 0x3f00:
		mapper_write_to_ppu_address_space(console, data, address) or_return
	case 0x3f00 ..= 0x3fff:
		// palette RAM (32 bytes)
		address := address & 0x001f
		// palette offset 0 is shared between
		// background and sprites so mirror addresses
		if address == 0x0010 do address = 0x0000
		if address == 0x0014 do address = 0x0004
		if address == 0x0018 do address = 0x0008
		if address == 0x001c do address = 0x000c
		console.ppu.palette[address] = data
	case:
		panic(fmt.tprintf("invalid address $%04X", address))
	}

	return nil
}

@(require_results)
ppu_read_from_address :: proc(console: ^Console, address: u16) -> u8 {
	address := address & 0x3fff
	switch address {
	case 0x0000 ..< 0x3f00:
		// cannot return error here since we know that the address is
		// within $0000-$3EFF
		data, err := mapper_read_from_ppu_address_space(console, address)
		assert(err == nil, "should never give an error here")
		return data
	case 0x3f00 ..= 0x3fff:
		// palette RAM (32 bytes)
		address := address & 0x001f
		// palette offset 0 is shared between
		// background and sprites so mirror
		if address == 0x0010 do address = 0x0000
		if address == 0x0014 do address = 0x0004
		if address == 0x0018 do address = 0x0008
		if address == 0x001c do address = 0x000c
		return console.ppu.palette[address]
	case:
		panic(fmt.tprintf("invalid address $%04X", address))
	}
}

ppu_increment_loopy_register :: proc(reg: ^Loopy_Register, vertical_increment: bool) {
	val := u16(reg^)
	if vertical_increment {
		val += 32
	} else {
		val += 1
	}
	reg^ = auto_cast (val & 0x7fff)
}

ppu_pattern_table_palette_offset_to_buffer :: proc(
	console: ^Console,
	buffer: []uint,
	table_index: uint,
) {
	ppu := console.ppu
	table_index := int(table_index) // avoid a whole bunch of type conversions 

	// each tile in a pattern table is 16 bytes (consistsof 8x8 pixels of 2 bits each)
	// each pattern table contain 16x16 tiles so each row is 256 bytes
	// the entire pattern table size is 4KB
	for ntile_y in 0 ..< 16 {
		for ntile_x in 0 ..< 16 {
			byte_offset := ntile_y * 256 + ntile_x * 16
			for row in 0 ..< 8 {
				tile_lsb, tile_msb: u8

				// first plane
				address := u16(table_index * 0x1000 + byte_offset + row + 0)
				tile_lsb = ppu_read_from_address(console, address)
				// ; err != nil {
				// 	return errorf(
				// 		.Pattern_Table_Read_Error,
				// 		"could not read pattern table %d byte from $%04X",
				// 		table_index,
				// 		address,
				// 	)
				// }

				// second plane
				address = u16(table_index * 0x1000 + byte_offset + row + 8)
				tile_msb = ppu_read_from_address(console, address)
				// ; err != nil {
				// 	return errorf(
				// 		.Pattern_Table_Read_Error,
				// 		"could not read pattern table %d byte from $%04X",
				// 		table_index,
				// 		address,
				// 	)
				// }

				for col in 0 ..< 8 {
					pixel_palette_offset := (tile_lsb & 0x01) + (tile_msb & 0x01)
					tile_lsb >>= 1;tile_msb >>= 1
					x := ntile_x * 8 + (7 - col)
					y := ntile_y * 8 + row
					buffer[y * 128 + x] = uint(pixel_palette_offset)
				}
			}
		}
	}

	return
}

@(require_results)
ppu_get_color_from_palette :: proc(console: ^Console, palette_index, offset: uint) -> Color {
	assert(palette_index < 8, "index must be 0-7")
	assert(offset < 4, "offset must be 0-2")

	address := u16(0x3f00 + (palette_index << 2) + offset)
	color_index := ppu_read_from_address(console, address)
	c := (ppu_palette_2C02[color_index & 0x3f])
	return transmute(Color)c
}

@(require_results)
ppu_execute_clk_cycle :: proc(console: ^Console) -> (frame_complete: bool) {
	// the ppu will continue execution even when encountering read errors and
	// simply cascade them to the caller as warnings

	ppu := &console.ppu

	// reset PPU status during pre-render scanline
	if ppu.scanline == -1 && ppu.cycle == 1 {
		ppu.status.vblank = false
		ppu.status.sprite_0_hit = false
		ppu.status.sprite_overflow = false
	}

	if ppu.scanline == -1 && ppu.cycle >= 280 && ppu.cycle < 305 {
		transfer_vertical(ppu)
	}

	// skip the first idle tick on the first visible scanline (0,0) on odd frames
	if ppu.scanline == 0 && ppu.cycle == 0 {
		ppu.cycle = 1
	}


	// visible scanlines(0-239) + pre-render scanline (-1)
	// The pre-render scanline (-1) is a dummy scanline whose purpose is
	// to fill the shift registers for the first visible scanline (0).
	// It will do the same operations as a normal visible scanline.
	if ppu.scanline >= -1 && ppu.scanline < 240 {
		/*
		Fetch the data for tile. It require 4 memory accesses: 

		- Nametable byte (bg_next_tile_id)
		- Attribute table byte (bg_next_tile_attribute)
		- Pattern table tile low (bg_next_tile_lsb)
		- Pattern table tile high (bg_next_tile_msb)

		Each access takes 2 cycles.
				
		The fetched data is placed into latches and fed to the appropriate
		shift registers every 8 cycles.
		*/

		// cycle 0 is idle

		if (ppu.cycle > 1 && ppu.cycle < 258) || (ppu.cycle >= 321 && ppu.cycle < 338) {
			// shifters shift the first time during cycle 2
			shifters_left_shift(ppu)

			switch (ppu.cycle - 1) % 8 {
			case 0:
				shifters_load_latched_data(ppu)
				address := 0x2000 | (u16(ppu.v) & 0x0fff)
				ppu.bg_next_tile_id = ppu_read_from_address(console, address)
			case 2:
				address :=
					0x23c0 |
					(ppu.v.nametable_y << 11) |
					(ppu.v.nametable_x << 10) |
					((ppu.v.coarse_y >> 2) << 3) |
					(ppu.v.coarse_x >> 2)

				ppu.bg_next_tile_attribute = ppu_read_from_address(console, address)

				if ppu.v.coarse_y & 0x02 == 1 do ppu.bg_next_tile_attribute >>= 4
				if ppu.v.coarse_x & 0x02 == 1 do ppu.bg_next_tile_attribute >>= 2
				ppu.bg_next_tile_attribute &= 0x03
			case 4:
				address :=
					(u16(ppu.ctrl.background_pattern_table_address) << 12) +
					(u16(ppu.bg_next_tile_id) << 4) +
					ppu.v.fine_y +
					0

				ppu.bg_next_tile_lsb = ppu_read_from_address(console, address)
			case 6:
				address :=
					(u16(ppu.ctrl.background_pattern_table_address) << 12) +
					(u16(ppu.bg_next_tile_id) << 4) +
					ppu.v.fine_y +
					8

				ppu.bg_next_tile_msb = ppu_read_from_address(console, address)
			case 7:
				coarse_x_increment_with_overflow(ppu)
			}
		}


		if ppu.cycle == 256 do fine_y_increment_with_overflow(ppu)

		if ppu.cycle == 257 {
			// shifters_load_latched_data(ppu) // @todo should include???
			transfer_horizontal(ppu)
		}

		// @todo is this needed???
		// if ppu.cycle == 338 || ppu.cycle == 340 {
		// 	ppu.bg_next_tile_id = ppu_read_from_address(
		// 		console,
		// 		0x2000 | (u16(ppu.v) & 0x0fff),
		// 	) or_return
		// }


		if ppu.cycle < 256 && ppu.scanline != -1 {
			bg_palette, bg_pixel: uint
			if ppu.mask.enable_background_rendering {
				bit_mux: u16 = 0x8000 >> ppu.x

				p0_pixel := uint((ppu.bg_shifter_pattern_lo & bit_mux) > 0)
				p1_pixel := uint((ppu.bg_shifter_pattern_hi & bit_mux) > 0)
				bg_pixel = (p1_pixel << 1) | p0_pixel

				bg_pal0 := uint((ppu.bg_shifter_attribute_lo & bit_mux) > 0)
				bg_pal1 := uint((ppu.bg_shifter_attribute_hi & bit_mux) > 0)
				bg_palette = (bg_pal1 << 1) | bg_pal0
			}

			c := ppu_get_color_from_palette(console, bg_palette, bg_pixel)
			c.a = 0xff
			ppu.pixel_buffer[ppu.scanline * 256 + ppu.cycle] = c
		}
	}

	// do nothing during scanline 240

	if ppu.scanline == 241 && ppu.cycle == 1 {
		ppu.status.vblank = true
		if ppu.ctrl.vblank_nmi_enable {
			console.cpu.interrupt = .NMI
		}
	}

	// Do nothing during 242-260, this is the vertical blank period
	// Well 241 is also included in vblank but yeah

	ppu.cycle += 1
	if ppu.cycle >= 341 {
		ppu.cycle = 0
		ppu.scanline += 1
		if ppu.scanline >= 261 {
			ppu.scanline = -1
			ppu.frame_count += 1
			frame_complete = true
		}
	}

	return

	transfer_horizontal :: proc(ppu: ^PPU) {
		if ppu.mask.enable_background_rendering || ppu.mask.enable_sprite_rendering {
			ppu.v.coarse_x = ppu.t.coarse_x
			ppu.v.nametable_x = ppu.v.nametable_x
		}
	}

	transfer_vertical :: proc(ppu: ^PPU) {
		if ppu.mask.enable_background_rendering || ppu.mask.enable_sprite_rendering {
			ppu.v.coarse_y = ppu.t.coarse_y
			ppu.v.nametable_y = ppu.t.nametable_y
			ppu.v.fine_y = ppu.t.fine_y
		}
	}

	coarse_x_increment_with_overflow :: proc(ppu: ^PPU) {
		if ppu.mask.enable_background_rendering || ppu.mask.enable_sprite_rendering {
			// coarse x of v ins incremented when the next tile is reached
			// overflow will toggle bit 10 to change nametable
			if ppu.v.coarse_x == 31 {
				ppu.v.coarse_x = 0
				ppu.v.nametable_x = ~ppu.v.nametable_x // switch horizontal nametable
			} else {
				ppu.v.coarse_x += 1
			}
		}
	}

	fine_y_increment_with_overflow :: proc(ppu: ^PPU) {
		if ppu.mask.enable_background_rendering || ppu.mask.enable_sprite_rendering {
			if ppu.v.fine_y < 7 {
				ppu.v.fine_y += 1
			} else {
				ppu.v.fine_y = 0
				y := ppu.v.coarse_y
				if y == 29 {
					y = 0
					ppu.v.nametable_y = ~ppu.v.nametable_y // switch vertical nametable
				} else if y == 31 {
					y = 0
				} else {
					y += 1
				}

				ppu.v.coarse_y = y
			}
		}
	}

	shifters_load_latched_data :: proc(ppu: ^PPU) {
		ppu.bg_shifter_pattern_lo =
			(ppu.bg_shifter_pattern_lo & 0xff00) | u16(ppu.bg_next_tile_lsb)
		ppu.bg_shifter_pattern_hi =
			(ppu.bg_shifter_pattern_hi & 0xff00) | u16(ppu.bg_next_tile_msb)

		ppu.bg_shifter_attribute_lo =
			(ppu.bg_shifter_attribute_lo & 0xff00) |
			((ppu.bg_next_tile_attribute & 0b01 > 0) ? 0xff : 0x00)
		ppu.bg_shifter_attribute_hi =
			(ppu.bg_shifter_attribute_hi & 0xff00) |
			((ppu.bg_next_tile_attribute & 0b10 > 0) ? 0xff : 0x00)
	}

	shifters_left_shift :: proc(ppu: ^PPU) {
		if ppu.mask.enable_background_rendering {
			ppu.bg_shifter_pattern_lo <<= 1
			ppu.bg_shifter_pattern_hi <<= 1
			ppu.bg_shifter_attribute_lo <<= 1
			ppu.bg_shifter_attribute_hi <<= 1
		}
	}
}

