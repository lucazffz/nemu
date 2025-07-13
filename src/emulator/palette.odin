package emulator

import "core:os"

Palette :: [64]Color

PALETTES_DIR_PATH :: #directory + "../assets/palettes/"

PALETTE_DEFAULT_DATA :: #load(PALETTES_DIR_PATH + "2C02G_wiki.pal")

palette_make_from_filename :: proc(filename: string, hue_shift: int) -> (^Palette, Maybe(Error)) {
	data, err := os.read_entire_file_or_err(filename)
	if err != nil {
		return nil, errorf(
			.IO_Error,
			"could not open file '%s', %v",
			filename,
			err,
			severity = .Fatal,
		)
	}

	defer delete(data)

	pal := palette_make_from_bytes(data, hue_shift)
	return pal, nil
}

palette_make_from_bytes :: proc(data: []byte, hue_shift: int) -> ^Palette {
	PALETTE_SIZE_BYTES :: 64 * 3 // 64 colors in RGB8 format
	// One .pal file usually contains multiple (normally 8) palettes with
	// shifted hue values.
	hue_shift_num := len(data) / PALETTE_SIZE_BYTES
	assert(hue_shift >= 0 && hue_shift < hue_shift_num, "hue shift outside valid range")

	pal := new(Palette)

	for col_idx in 0 ..< 64 {
		offset := hue_shift * PALETTE_SIZE_BYTES + col_idx * 3
		r := data[offset]
		g := data[offset + 1]
		b := data[offset + 2]

		pal[col_idx] = Color{r, g, b, 0xff}
	}

	return pal
}

palette_delete :: proc(palette: ^Palette) {
	free(palette)
}

