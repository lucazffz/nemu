package emulator

import "core:fmt"
import "core:log"
import "core:slice"

Color :: distinct [4]u8

Loopy_Register :: bit_field u16 {
	coarse_x:    u16 | 5,
	coarse_y:    u16 | 5,
	nametable_x: u16 | 1,
	nametable_y: u16 | 1,
	fine_y:      u16 | 3,
	_unused:     u16 | 1,
}

Sprite :: struct {
	y_pos:      u8,
	tile_index: u8,
	attributes: bit_field u8 {
		palette_index:     uint | 2,
		_unused:           u8   | 3,
		priority:          u8   | 1, // 0: in front of background, 1: behind background
		flip_horizontally: bool | 1,
		flip_vertically:   bool | 1,
	},
	x_pos:      u8,
}

PPU :: struct {
	// Miscellaneous settings ($2000 write-only)
	// mmio_register_bank:     struct {
	ctrl:                       bit_field u8 {
		nametable_base_address:           u8   | 2, // 0: $2000, 1: $2400, 2: $2800, 3: $2C00
		vram_address_increment:           u8   | 1, // 0: add 1, going across, 1: add 32 going down
		sprite_pattern_table_address:     u8   | 1, // 0: $0000, 1: $1000 (ignored for 8x16 sprites)
		background_pattern_table_address: u8   | 1, // 0: $0000, 1: $1000
		sprite_size:                      u8   | 1, // 0: 8x8 pixels, 1: 8x16 pixels (see PPU OAM#byte 1)
		master_slave_select:              u8   | 1, // 0: read backdrop from EXT pins, 1: output color on EXT pins
		vblank_nmi_enable:                bool | 1, // 0: off, 1: on
	},
	// Rendering settings ($2001 write-only)
	mask:                       bit_field u8 {
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
	status:                     bit_field u8 {
		_unused:         u8   | 5,
		sprite_overflow: bool | 1,
		sprite_0_hit:    bool | 1,
		vblank:          bool | 1, // cleared on read (unreliable)
	},
	// Sprite RAM address ($2003 write-only)
	oamaddr:                    u8,
	// Sprite RAM data ($2004 read-write)
	// oamdata:                 u8,
	// X and Y scroll ($2005 write-only)
	// ppuscroll:           u8,
	// VRAM address ($2006 write-only)
	// ppuaddr:                 Loopy_Register,
	// VRAM data ($2007 read-write)
	// ppudata:                 u8,
	// Sprite DMA ($4014 write-only)
	// oamdma:              u8,
	// },
	// internal_register_bank: struct {
	read_buffer:                u8,
	v:                          Loopy_Register, // current VRAM address
	t:                          Loopy_Register, // temporary VRAM address (addr of top left onscreen tile)
	x:                          u8, // fine x scroll, 3 bits
	w:                          u8, // first or second byte write toggle, 1 bit
	// },
	// pattern_table:         []u8,
	// nametable:             []u8,
	vram:                       []u8,
	oam:                        struct #raw_union {
		sprites:  [64]Sprite,
		raw_data: [256]u8,
	},
	secondary_oam:              struct #raw_union {
		sprites:  [8]Sprite,
		raw_data: [32]u8,
	},
	palette:                    []u8,
	is_rendering:               bool, // active during scanlines -1 - 239
	// frame_complete:         bool,
	frame_count:                u64,
	cycle:                      int,
	scanline:                   int,
	// pixel_buffer:               []Color,
	cycle_count:                int,
	bg_next_tile_id:            u8,
	bg_next_tile_attribute:     u8,
	bg_next_tile_lsb:           u8,
	bg_next_tile_msb:           u8,
	bg_shifter_pattern_lo:      u16,
	bg_shifter_pattern_hi:      u16,
	bg_shifter_attribute_lo:    u16,
	bg_shifter_attribute_hi:    u16,
	// during sprite initialization (visible scanlines, cycles 1-64) OAM reads
	// from $2004 should always return 0xff
	// oam_always_read_ff:         bool,
	// sprite_evaluation_index: uint,
	// n:                       uint,
	// secondary_oam_index:     uint,
	sprite_count:               uint,
	sprite_shifter_pattern_lo:  [8]u8,
	sprite_shifter_pattern_hi:  [8]u8,
	sprite_zero_hit_possible:   bool,
	sprite_zero_being_rendered: bool,

	// current_sprite:          Sprite,
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
		data = ppu_oam_read_from_address(&console.ppu, console.ppu.oamaddr)
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

	ppu_oam_read_from_address :: proc(ppu: ^PPU, address: u8) -> u8 {
		// if ppu.oam_always_read_ff do return 0xff
		return ppu.oam.raw_data[address]
	}

	return
}

// ppu_write_to_oamdma :: proc(console: ^Console, address: u8) {
// 	// Writing to OAMDMA will cause an entire RAM page to be copied into OAM.
// 	// This is implemented as 256 pairs of RAM reads and OAMDATA writes in the
// 	// original hardware.

// 	num_of_copies := copy(console.ppu.oam.raw_data, console.ram[address:address + 255])
// 	assert(
// 		num_of_copies == 256,
// 		fmt.tprintf(
// 			"did not copy from RAM to OAM correctly, expected 256 bytes to be copied, only %d was",
// 			num_of_copies,
// 		),
// 	)

// 	// @todo 513 or 514??? 
// 	// suspend the CPU for 512 cycles
// 	console.cpu.stall_count += 512
// 	return
// 2

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
		console.ppu.oamaddr = data
	case 4:
		// OAMDATA - Sprite RAM data ($2004 read-write)
		// do not write if rendering
		// preform buggy OAMADDR increment using only 6 highest bits
		if console.ppu.is_rendering {
			addr := console.ppu.oamaddr
			addr = (((addr >> 2) + 1) << 2) | (addr & 0x3)
			console.ppu.oamaddr = addr
		} else {
			// when writing to OAMDATA, the data is immediately written to OAM
			ppu_oam_write_to_address(&console.ppu, data, console.ppu.oamaddr)
			// writes will increment OAMADDR after write to OAMDATA, reads do not
			console.ppu.oamaddr += 1
		}
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


	return
}

ppu_oam_write_to_address :: proc(ppu: ^PPU, data: u8, address: u8) {
	ppu.oam.raw_data[address] = data
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

				// second plane
				address = u16(table_index * 0x1000 + byte_offset + row + 8)
				tile_msb = ppu_read_from_address(console, address)

				for col in 0 ..< 8 {
					pixel_palette_offset := ((tile_lsb & 0x01) << 1) | (tile_msb & 0x01)
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
	return c

}

@(require_results)
ppu_execute_clk_cycle :: proc(
	console: ^Console,
	pixel_buffer: Maybe([]Color),
) -> (
	frame_complete: bool,
) {
	// the ppu will continue execution even when encountering read errors and
	// simply cascade them to the caller as warnings

	ppu := &console.ppu

	// reset
	ppu.is_rendering = false
	// ppu.oam_always_read_ff = false

	// skip the first idle tick on the first visible scanline (0,0) on odd frames
	if ppu.scanline == 0 && ppu.cycle == 0 {
		ppu.cycle = 1
	}

	// reset PPU status during pre-render scanline
	if ppu.scanline == -1 && ppu.cycle == 1 {
		ppu.status.vblank = false
		ppu.status.sprite_0_hit = false
		ppu.status.sprite_overflow = false

		slice.fill(ppu.sprite_shifter_pattern_lo[:], 0)
		slice.fill(ppu.sprite_shifter_pattern_hi[:], 0)
	}


	// --- Handle background rendering ---

	if ppu.scanline == -1 && ppu.cycle >= 280 && ppu.cycle < 305 {
		transfer_vertical(ppu)
	}

	// visible scanlines(0-239) + pre-render scanline (-1)
	// The pre-render scanline (-1) is a dummy scanline whose purpose is
	// to fill the shift registers for the first visible scanline (0).
	// It will do the same operations as a normal visible scanline.
	if ppu.scanline >= -1 && ppu.scanline < 240 {
		if ppu.mask.enable_background_rendering || ppu.mask.enable_sprite_rendering {
			ppu.is_rendering = true
		}
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

				if ppu.v.coarse_y & 0b10 > 0 do ppu.bg_next_tile_attribute >>= 4
				if ppu.v.coarse_x & 0b10 > 0 do ppu.bg_next_tile_attribute >>= 2
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
			shifters_load_latched_data(ppu) // should include??? Gemini says yes
			transfer_horizontal(ppu)
		}


		// @todo is this needed???
		// if ppu.cycle == 338 || ppu.cycle == 340 {
		// 	ppu.bg_next_tile_id = ppu_read_from_address(
		// 		console,
		// 		0x2000 | (u16(ppu.v) & 0x0fff),
		// 	) or_return
		// }

	}

	// --- Sprite rendering shit ---

	if ppu.scanline >= -1 && ppu.scanline < 340 {
		// @Note Sprite rendering does not follow the NES hardware timing.
		// Everything is calculated during the first non-visible cycle of each scanline.
		// This may cause compatability issues with certain games.

		sprite_evaluation: if ppu.cycle == 257 && ppu.scanline >= 0 {
			// Sprite initialization
			slice.fill(ppu.secondary_oam.raw_data[:], 0xff)
			ppu.sprite_count = 0
			ppu.sprite_zero_hit_possible = false

			oam_entry_num := 0
			// iterate one extra sprite count to be able to determine
			// value for sprite overflow flag
			for oam_entry_num < 64 && ppu.sprite_count < 9 {
				diff := int(ppu.scanline) - int(ppu.oam.sprites[oam_entry_num].y_pos)

				// sprite is visible on next scanline
				if diff >= 0 && diff < (ppu.ctrl.sprite_size == 1 ? 16 : 8) {
					if ppu.sprite_count < 8 {
						if oam_entry_num == 0 {
							ppu.sprite_zero_hit_possible = true
						}

						// copy sprite from OAM to secondary OAM
						ppu.secondary_oam.sprites[ppu.sprite_count] =
							ppu.oam.sprites[oam_entry_num]
						ppu.sprite_count += 1
					}
				}

				oam_entry_num += 1
			}

			ppu.status.sprite_overflow = ppu.sprite_count > 8
		}


		// last cycle of scanline
		sprite_data_fetch: if ppu.cycle == 340 {
			for sprite, i in ppu.secondary_oam.sprites[:ppu.sprite_count] {
				sprite_pattern_bits_lo, sprite_pattern_bits_hi: u8
				sprite_pattern_addr_lo, sprite_pattern_addr_hi: u16

				if ppu.ctrl.sprite_size == 0 {
					// 8x8 sprite mode
					if !sprite.attributes.flip_vertically {
						sprite_pattern_addr_lo =
							(u16(ppu.ctrl.sprite_pattern_table_address) << 12) |
							(u16(sprite.tile_index) << 4) |
							u16(ppu.scanline - int(sprite.y_pos))
					} else {
						sprite_pattern_addr_lo =
							(u16(ppu.ctrl.sprite_pattern_table_address) << 12) |
							(u16(sprite.tile_index) << 4) |
							u16(7 - (ppu.scanline - int(sprite.y_pos)))
					}
				} else {
					// 8x16 sprite mode
					if !sprite.attributes.flip_vertically {
						// top half of tile
						if ppu.scanline - int(sprite.y_pos) < 8 {
							sprite_pattern_addr_lo =
								(u16(sprite.tile_index & 0x01) << 12) |
								(u16(sprite.tile_index & 0xfe) << 4) |
								(u16(ppu.scanline - int(sprite.y_pos)) & 0x07)
						} else {
							// bottom half of tile
							sprite_pattern_addr_lo =
								(u16(sprite.tile_index & 0x01) << 12) |
								((u16(sprite.tile_index & 0xfe) + 1) << 4) |
								(u16(ppu.scanline - int(sprite.y_pos)) & 0x07)
						}
					} else {
						// top half of tile
						if ppu.scanline - int(sprite.y_pos) < 8 {
							sprite_pattern_addr_lo =
								(u16(sprite.tile_index & 0x01) << 12) |
								(u16(sprite.tile_index & 0xfe) << 4) |
								(u16(7 - (ppu.scanline - int(sprite.y_pos))) & 0x07)
						} else {
							// bottom half of tile
							sprite_pattern_addr_lo =
								(u16(sprite.tile_index & 0x01) << 12) |
								((u16(sprite.tile_index & 0xfe) + 1) << 4) |
								(u16(7 - ppu.scanline - int(sprite.y_pos) & 0x07))
						}
					}
				}

				sprite_pattern_addr_hi = sprite_pattern_addr_lo + 8
				sprite_pattern_bits_lo = ppu_read_from_address(console, sprite_pattern_addr_lo)
				sprite_pattern_bits_hi = ppu_read_from_address(console, sprite_pattern_addr_hi)

				if sprite.attributes.flip_horizontally {
					sprite_pattern_bits_lo = flip_byte(sprite_pattern_bits_lo)
					sprite_pattern_bits_hi = flip_byte(sprite_pattern_bits_hi)

					flip_byte :: proc(b: u8) -> u8 {
						b := b
						b = (b & 0xf0) >> 4 | (b & 0x0f) << 4
						b = (b & 0xcc) >> 2 | (b & 0x33) << 2
						b = (b & 0xaa) >> 1 | (b & 0x55) << 1
						return b
					}
				}

				ppu.sprite_shifter_pattern_lo[i] = sprite_pattern_bits_lo
				ppu.sprite_shifter_pattern_hi[i] = sprite_pattern_bits_hi
			}
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

	fg_pixel, fg_palette, fg_priority: uint
	sprite_rendering: if ppu.mask.enable_sprite_rendering {
		ppu.sprite_zero_being_rendered = false

		for sprite, i in ppu.secondary_oam.sprites[:ppu.sprite_count] {
			if sprite.x_pos == 0 {
				fg_pixel_lo := uint(ppu.sprite_shifter_pattern_lo[i] & 0x80 > 0)
				fg_pixel_hi := uint(ppu.sprite_shifter_pattern_hi[i] & 0x80 > 0)

				fg_pixel = uint((fg_pixel_hi << 1) | fg_pixel_lo)
				fg_palette = uint(sprite.attributes.palette_index) + 4
				fg_priority = uint(sprite.attributes.priority)

				if fg_pixel != 0 {
					if i == 0 do ppu.sprite_zero_being_rendered = true
					break
				}
			}

		}
	}


	bg_palette, bg_pixel: uint
	background_rendering: if ppu.mask.enable_background_rendering {
		bit_mux: u16 = 0x8000 >> ppu.x

		p0_pixel := uint((ppu.bg_shifter_pattern_lo & bit_mux) > 0)
		p1_pixel := uint((ppu.bg_shifter_pattern_hi & bit_mux) > 0)
		bg_pixel = (p1_pixel << 1) | p0_pixel

		bg_pal0 := uint((ppu.bg_shifter_attribute_lo & bit_mux) > 0)
		bg_pal1 := uint((ppu.bg_shifter_attribute_hi & bit_mux) > 0)
		bg_palette = (bg_pal1 << 1) | bg_pal0
	}

	pixel, palette: uint

	if bg_pixel == 0 && fg_pixel == 0 {
		pixel = 0x0
		palette = 0x0
	} else if bg_pixel == 0 && fg_pixel > 0 {
		pixel = fg_pixel
		palette = fg_palette
	} else if bg_pixel > 0 && fg_pixel == 0 {
		pixel = bg_pixel
		palette = bg_palette
	} else if bg_pixel > 0 && bg_pixel > 0 {
		if fg_priority == 0 {
			pixel = fg_pixel
			palette = fg_palette
		} else {
			pixel = bg_pixel
			palette = bg_palette
		}

		if ppu.sprite_zero_hit_possible && ppu.sprite_zero_being_rendered {
			if ppu.mask.enable_background_rendering && ppu.mask.enable_sprite_rendering {
				if !(ppu.mask.show_background_in_margin | ppu.mask.show_sprites_in_margin) {
					if ppu.cycle >= 9 && ppu.cycle < 258 {
						ppu.status.sprite_0_hit = true
					}
				} else {
					if ppu.cycle >= 1 && ppu.cycle < 258 {
						ppu.status.sprite_0_hit = true
					}
				}
			}
		}
	}

	if buffer, ok := pixel_buffer.?; ok {
		if ppu.cycle < 256 && ppu.scanline >= 0 && ppu.scanline < 240 {
			c := ppu_get_color_from_palette(console, palette, pixel)
			buffer[ppu.scanline * 256 + ppu.cycle] = c
		}
	}

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
			ppu.v.nametable_x = ppu.t.nametable_x
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

		// only shift the sprite if visible
		if ppu.mask.enable_sprite_rendering && ppu.cycle >= 1 && ppu.cycle < 258 {
			for &sprite, i in ppu.secondary_oam.sprites[:ppu.sprite_count] {
				if sprite.x_pos > 0 {
					sprite.x_pos -= 1
				} else {
					ppu.sprite_shifter_pattern_lo[i] <<= 1
					ppu.sprite_shifter_pattern_hi[i] <<= 1
				}
			}
		}
	}
}

