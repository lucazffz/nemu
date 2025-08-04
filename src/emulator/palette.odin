package emulator

import "base:runtime"
import "core:os"

Palette :: [64]Color

PALETTE_DEFAULT_DATA :: #load(ASSETS_DIR_PATH + "2C02G_wiki.pal")

@(require_results)
palette_make_from_filename :: proc(
	filename: string,
	hue_shift: int,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	^Palette,
	Maybe(Error),
) {
	data, err := os.read_entire_file_or_err(filename, allocator, loc)
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

	pal :=
		palette_make_from_bytes(data, hue_shift, allocator, loc) or_else panic("allocation error")
	return pal, nil
}

@(require_results)
palette_make_default :: proc(
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	^Palette,
	runtime.Allocator_Error,
) #optional_allocator_error {
	return palette_make_from_bytes(PALETTE_DEFAULT_DATA, 0, allocator, loc)
}

@(require_results)
palette_make_from_bytes :: proc(
	data: []byte,
	hue_shift: int,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	pal: ^Palette,
	error: runtime.Allocator_Error,
) #optional_allocator_error {
	PALETTE_SIZE_BYTES :: 64 * 3 // 64 colors in RGB8 format
	// One .pal file usually contains multiple (normally 8) palettes with
	// shifted hue values.
	hue_shift_num := len(data) / PALETTE_SIZE_BYTES
	assert(hue_shift >= 0 && hue_shift < hue_shift_num, "hue shift outside valid range")

	pal = new(Palette, allocator, loc)

	for col_idx in 0 ..< 64 {
		offset := hue_shift * PALETTE_SIZE_BYTES + col_idx * 3
		r := data[offset]
		g := data[offset + 1]
		b := data[offset + 2]

		pal[col_idx] = Color{r, g, b, 0xff}
	}

	return
}

palette_delete :: proc(
	palette: ^Palette,
	allocator := context.allocator,
	loc := #caller_location,
) -> runtime.Allocator_Error {
	return free(palette, allocator, loc)
}

