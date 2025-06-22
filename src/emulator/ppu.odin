package emulator

PPU :: struct {
	ppuctrl: bit_field u8 {
		nametable_base_address:           u8 | 2, // 0: $2000, 1: $2400, 2: $2800, 3: $2C00
		vram_address_increment:           u8 | 1, // 0: add 1, going across, 1: add 32 going down
		sprite_pattern_table_address:     u8 | 1, // 0: $0000, 1: $1000 (ignored for 8x16 sprites)
		background_pattern_table_address: u8 | 1, // 0: $0000, 1: $1000
		sprite_size:                      u8 | 1, // 0: 8x8 pixels, 1: 8x16 pixels (see PPU OAM#byte 1)
		master_slave_select:              u8 | 1, // 0: read backdrop from EXT pins, 1: output color on EXT pins
		vblank_nmi_enable:                u8 | 1, // 0: off, 1: on
	},
	ppumask: bit_field u8 {
		
	}
}

