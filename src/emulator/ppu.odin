package emulator

PPU :: struct {
	// Miscellaneous settings ($2000 write-only)
	mmio_register_bank:     struct {
		ppuctrl:   bit_field u8 {
			nametable_base_address:           u8   | 2, // 0: $2000, 1: $2400, 2: $2800, 3: $2C00
			vram_address_increment:           u8   | 1, // 0: add 1, going across, 1: add 32 going down
			sprite_pattern_table_address:     u8   | 1, // 0: $0000, 1: $1000 (ignored for 8x16 sprites)
			background_pattern_table_address: u8   | 1, // 0: $0000, 1: $1000
			sprite_size:                      u8   | 1, // 0: 8x8 pixels, 1: 8x16 pixels (see PPU OAM#byte 1)
			master_slave_select:              u8   | 1, // 0: read backdrop from EXT pins, 1: output color on EXT pins
			vblank_nmi_enable:                bool | 1, // 0: off, 1: on
		},
		// Rendering settings ($2001 write-only)
		ppumask:   bit_field u8 {
			greyscale:                   bool | 1, // 0: normal color, 1: greyscale
			show_background:             bool | 1, // 0: hide, 1: show background in leftmost 8 pixels of screen
			show_sprites:                bool | 1, // 0: hide, 1: show sprites in leftmost 8 pixels of screen
			enable_background_rendering: bool | 1,
			enable_sprite_rendering:     bool | 1,
			emphasize_red:               bool | 1, // green on PAL/Dendy
			emphasize_green:             bool | 1, // red on PAL/Dendy
			emphasize_blue:              bool | 1,
		},
		// Rendering events ($2002 read-only)
		ppustatus: bit_field u8 {
			_unused:         u8   | 5,
			sprite_overflow: bool | 1,
			sprite_0_hit:    bool | 1,
			vblank:          bool | 1, // cleared on read (unreliable)
		},
		// Sprite RAM address ($2003 write-only)
		oamaddr:   u8,
		// Sprite RAM data ($2004 read-write)
		oamdata:   u8,
		// X and Y scroll ($2005 write-only)
		ppuscroll: u8,
		// VRAM address ($2006 write-only)
		ppuaddr:   u8,
		// VRAM data ($2007 read-write)
		ppudata:   u8,
		// Sprite DMA ($4014 write-only)
		oamdma:    u8,
	},
	internal_register_bank: struct {
		v: u8,
		t: u8,
		x: u8,
		w: u8,
	},
	pattern_table:          []u8,
	nametables:             [4]struct {
		nametable:       []u8,
		attribute_table: []u8,
	},
	oam:                    []u8,
	palette:                union {},
	memory_map:             []u8,
}

