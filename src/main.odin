package nemu

import "base:builtin"
import "base:runtime"
import "core:encoding/endian"
import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "emulator"
import rlimgui "vendor/imgui_impl_raylib"
import imgui "vendor/odin-imgui"
import rl "vendor:raylib"

GAME_WIDTH :: 256
GAME_HEIGHT :: 240

ASSETS_DIRECTORY_PATH :: #config(ASSETS_DIRECTORY_PATH, #directory + "./assets")

default_context: runtime.Context

Vec2 :: [2]f32
Vec3 :: [2]f32

pattern_table_0_texture: rl.Texture2D
pattern_table_1_texture: rl.Texture2D
game_view_texture: rl.Texture2D

@(private = "file")
console: ^emulator.Console

@(private = "file")
mapper: emulator.Mapper

main :: proc() {
	logger := log.create_console_logger(.Info)
	defer log.destroy_console_logger(logger)
	context.logger = logger

	// setup tracking allocator in debug mode and print unfreed allocations
	// on termination
	when ODIN_DEBUG {
		context.logger.lowest_level = .Debug

		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				// use temp allocator as to not interfere with the tracking allocator
				if builder, err := strings.builder_make_none(context.temp_allocator); err == nil {
					fmt.sbprintfln(
						&builder,
						"%v allocations not freed during termination:",
						len(track.allocation_map),
					)

					for _, entry in track.allocation_map {
						fmt.sbprintfln(&builder, " - %v bytes @ %v", entry.size, entry.location)
					}

					log.warn(strings.to_string(builder))
				} else {
					log.error("could not print unfreed allocations", err)
				}

				mem.tracking_allocator_destroy(&track)
			}
		}
	}

	// === INIT CONSOLE ===
	rom_file_path := #directory + "../../roms/Ice Climber (USA, Europe).nes"
	rom, err := os.read_entire_file_or_err(rom_file_path)
	if err != nil {
		log.errorf("ERROR: could not open file '%s', %v", rom_file_path, err)
		os.exit(1)
	}
	defer delete(rom)

	if ok := emulator.ines_is_nes_file_format(rom); !ok {
		log.errorf("ERROR: file '%s' is not in iNES format", rom_file_path)
		os.exit(1)
	}


	ines := emulator.get_ines_from_bytes(rom)

	if err := emulator.console_vet_ines(ines); err != nil {
		emulator.error_log(err.?)
		os.exit(1)
	}

	console = emulator.console_make();defer emulator.console_delete(console)
	mapper = emulator.mapper_make_from_ines(ines);defer emulator.mapper_delete(mapper)

	emulator.console_initialize_with_mapper(console, mapper)
	_ = emulator.console_reset(console)

	// emulator.console_set_program_counter(console, 0xc000)

	// emulator.ppu_write_to_address(console, 0xc, 0x3f00)
	// emulator.ppu_write_to_address(console, 0x2, 0x3f00 + 1)
	// emulator.ppu_write_to_address(console, 0x5, 0x3f00 + 2)
	// emulator.ppu_write_to_address(console, 0x6, 0x3f00 + 3)

	palette_index_buffer_0: [128 * 128]uint
	palette_index_buffer_1: [128 * 128]uint

	emulator.ppu_pattern_table_palette_offset_to_buffer(console, palette_index_buffer_0[:], 0)
	emulator.ppu_pattern_table_palette_offset_to_buffer(console, palette_index_buffer_1[:], 1)

	pattern_table_0_buf: [128 * 128]rl.Color
	pattern_table_1_buf: [128 * 128]rl.Color


	for v, i in palette_index_buffer_1 {
		if v == 0 do continue
		pattern_table_1_buf[i] = rl.GetColor(0xffffffff)
	}


	pattern_table_0_img: rl.Image = {
		data    = &pattern_table_0_buf,
		width   = 128,
		height  = 128,
		mipmaps = 1,
		format  = rl.PixelFormat.UNCOMPRESSED_R8G8B8A8,
	}

	pattern_table_1_img: rl.Image = {
		data    = &pattern_table_1_buf,
		width   = 128,
		height  = 128,
		mipmaps = 1,
		format  = rl.PixelFormat.UNCOMPRESSED_R8G8B8A8,
	}


	game_view_img := rl.Image {
		data    = raw_data(console.ppu.pixel_buffer),
		width   = GAME_WIDTH,
		height  = GAME_HEIGHT,
		mipmaps = 1,
		format  = rl.PixelFormat.UNCOMPRESSED_R8G8B8A8,
	}


	// === RENDER ===
	rl.SetConfigFlags({rl.ConfigFlag.WINDOW_RESIZABLE, rl.ConfigFlag.WINDOW_ALWAYS_RUN})
	rl.InitWindow(GAME_WIDTH * 2, GAME_HEIGHT * 2, "Raylib + ImGui in Odin");defer rl.CloseWindow()

	// Setup ImGui context
	ctx := imgui.CreateContext(nil);defer imgui.DestroyContext(nil)
	ctx.IO.ConfigFlags += {.ViewportsEnable}
	imgui.SetCurrentContext(ctx)

	// Init ImGui for Raylib
	rlimgui.init();defer rlimgui.shutdown()

	pattern_table_0_texture = rl.LoadTextureFromImage(pattern_table_0_img)
	pattern_table_1_texture = rl.LoadTextureFromImage(pattern_table_1_img)
	game_view_texture = rl.LoadTextureFromImage(game_view_img)

	should_run: bool = false

	@(static) show_debug_io: bool
	when ODIN_DEBUG do show_debug_io = true

	last_err: emulator.Error

	buf: [64]byte
	// Main loop
	for !rl.WindowShouldClose() {
		if rl.IsKeyPressed(rl.KeyboardKey.SPACE) do should_run = !should_run
		if rl.IsKeyPressed(rl.KeyboardKey.F3) do show_debug_io = !show_debug_io

		frame_complete, cpu_complete: bool;err: Maybe(emulator.Error)
		if (rl.IsKeyPressed(rl.KeyboardKey.S) || should_run) &&
		   (console.cpu.instruction_count < brk_point_instruction || brk_point_instruction == 0) {
			using emulator
			for (should_run || !cpu_complete) && !frame_complete {
				if frame_complete, cpu_complete, err = console_execute_clk_cycle(console);
				   err != nil {
					if err != last_err {
						err := err.?
						error_log(err, log.Level.Warning)
						last_err = err
					}
				}
			}

			rl.UpdateTexture(game_view_texture, raw_data(console.ppu.pixel_buffer))

			if show_debug_io && frame_complete {
				for v, i in palette_index_buffer_0 {
					// if v == 0 do continue
					// @note watch out for endianess when converting color from u32 to [4]u8
					c := emulator.ppu_get_color_from_palette(console, 0, v)
					col := rl.Color{c.b, c.g, c.r, 0xff}
					pattern_table_0_buf[i] = col
				}
				rl.UpdateTexture(pattern_table_0_texture, &pattern_table_0_buf)
			}
		}


		screen_width := rl.GetScreenWidth()
		screen_height := rl.GetScreenHeight()
		game_view_rectangle: rl.Rectangle

		if screen_height < screen_width {
			game_view_size := screen_height
			game_view_rectangle = {
				f32((screen_width - game_view_size) / 2),
				0,
				f32(game_view_size),
				f32(game_view_size),
			}
		} else {
			game_view_size := screen_width
			game_view_rectangle = {
				0,
				f32((screen_height - game_view_size) / 2),
				f32(game_view_size),
				f32(game_view_size),
			}
		}


		// rl.SetTargetFPS(60)

		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)

		// Raylib rendering
		rl.DrawTexturePro(
			game_view_texture,
			{0, 0, GAME_WIDTH, GAME_HEIGHT},
			game_view_rectangle,
			{},
			0,
			rl.WHITE,
		)


		if show_debug_io {
			rl.DrawFPS(15, 30)
			// ImGui begin (must be called each frame BEFORE using ImGui)
			rlimgui.begin()


			if show_debug_io {
				render_debug_ui()
			}

			imgui.Render()
			imgui.UpdatePlatformWindows()
			imgui.RenderPlatformWindowsDefault()

			rlimgui.end()
		}


		// Drawing on top of ImGui (call after 'rlimgui.end()' to do that, as showed here)
		// rl.DrawText("Drawing on top of ImGui window", 170, 370, 30, rl.BLUE)
		rl.EndDrawing()

		free_all(context.temp_allocator)
	}
}

brk_point_instruction: int

render_debug_ui :: proc() {
	@(static) show_pattern_tables: bool = false
	@(static) show_ppu_state: bool = false
	@(static) show_cpu_state: bool = false
	@(static) show_ppu_palettes: bool = false
	str_buf := make([]u8, 1024)
	defer delete(str_buf)

	imgui.ShowDemoWindow(nil)

	if imgui.BeginMainMenuBar() {
		imgui.Checkbox("Pattern Tables", &show_pattern_tables)
		imgui.Checkbox("CPU State", &show_cpu_state)
		imgui.Checkbox("PPU State", &show_ppu_state)
		imgui.Checkbox("Palettes", &show_ppu_palettes)
		imgui.InputScalar("pause at cycle", .U32, &brk_point_instruction)
	}
	imgui.EndMainMenuBar()


	if show_pattern_tables {
		imgui.Begin("Pattern Tables", nil, {.AlwaysAutoResize})
		val := emulator.ppu_read_from_address(console, 0x2000)
		rlimgui.image_size(&pattern_table_0_texture, {256, 256})
		imgui.SameLine()
		rlimgui.image_size(&pattern_table_1_texture, {256, 256})
		imgui.End()
	}

	if show_ppu_palettes {
		imgui.Begin("Palettes", nil)
		draw_list := imgui.GetWindowDrawList()
		pos := imgui.GetWindowPos()
		pos.y += 30
		size: f32 = 20
		for j in 0 ..< 8 {
			for i in 0 ..< 4 {
				imgui.DrawList_AddRectFilled(
					draw_list,
					{pos.x + f32(i) * size, (pos.y + f32(j) * size)},
					{pos.x + (f32(i) + 1) * size, pos.y + (f32(j) + 1) * size},
					get_palette_color(j, i),
				)
			}
		}
		imgui.End()
	}

	if show_cpu_state {
		imgui.Begin("CPU State", nil)
		imgui.BeginGroup()
		imgui.Text("X:  %02X", console.cpu.x)
		imgui.Text("Y:  %02X", console.cpu.y)
		imgui.Text("A:  %02X", console.cpu.acc)
		imgui.EndGroup()
		imgui.SameLine()
		imgui.BeginGroup()
		imgui.Text("SP: %02X", console.cpu.sp)
		imgui.Text("PC: %04X", console.cpu.pc)
		imgui.EndGroup()
		imgui.SameLine()
		imgui.BeginGroup()
		flag_text("C", .CF in console.cpu.status)
		imgui.SameLine()
		flag_text("Z", .ZF in console.cpu.status)
		imgui.SameLine()
		flag_text("I", .IF in console.cpu.status)
		imgui.SameLine()
		flag_text("V", .VF in console.cpu.status)
		imgui.SameLine()
		flag_text("N", .NF in console.cpu.status)
		imgui.Text("Cycle count:       %04d", console.cpu.cycle_count)
		imgui.Text("Instruction count: %04d", console.cpu.instruction_count)
		imgui.EndGroup()
		imgui.SeparatorText("Instructions")
		imgui.Text("%s", emulator.console_state_to_string(console))
		imgui.End()
	}

	if show_ppu_state {
		imgui.Begin("PPU State", nil)
		imgui.SeparatorText("PPUCTRL")
		imgui.BeginGroup()
		imgui.Text("nametable base address:           %d", console.ppu.ctrl.nametable_base_address)
		imgui.Text(
			"VRAM address increment:           %d",
			console.ppu.ctrl.vram_address_increment == 0 ? 1 : 32,
		)
		imgui.Text(
			"sprite pattern table address:     $%s",
			console.ppu.ctrl.sprite_pattern_table_address == 0 ? "0000" : "1000",
		)
		imgui.Text(
			"background pattern table address: $%s",
			console.ppu.ctrl.background_pattern_table_address == 0 ? "0000" : "1000",
		)
		imgui.EndGroup()
		imgui.SameLine()
		imgui.BeginGroup()
		imgui.Text("sprite size:         %s", console.ppu.ctrl.sprite_size == 0 ? "8x8" : "8x16")
		imgui.Text("master slave select: %d", console.ppu.ctrl.master_slave_select)
		imgui.Text(
			"vblank NMI enabled:  %s",
			console.ppu.ctrl.vblank_nmi_enable ? "true" : "false",
		)
		imgui.EndGroup()
		imgui.SeparatorText("PPUMASK")
		imgui.BeginGroup()
		flag_text("greyscale", console.ppu.mask.greyscale)
		flag_text("show background", console.ppu.mask.show_background)
		flag_text("show sprites", console.ppu.mask.show_sprites)
		flag_text("enable background rendering", console.ppu.mask.enable_background_rendering)
		imgui.EndGroup()
		imgui.SameLine()
		imgui.BeginGroup()
		flag_text("enable sprite rendering", console.ppu.mask.enable_sprite_rendering)
		flag_text("emphasize red", console.ppu.mask.emphasize_red)
		flag_text("emphasize green", console.ppu.mask.emphasize_green)
		flag_text("emphasize blue", console.ppu.mask.emphasize_blue)
		imgui.EndGroup()
		imgui.SeparatorText("PPUSTATUS")
		flag_text("sprite overflow", console.ppu.status.sprite_overflow)
		imgui.SameLine()
		flag_text("sprite_0_hit", console.ppu.status.sprite_0_hit)
		imgui.SameLine()
		flag_text("vblank", console.ppu.status.vblank)
		// imgui.SeparatorText("Other")
		// imgui.BeginGroup()
		// imgui.Text("OAM address:  $%02X", console.ppu.oamaddr)
		// imgui.Text("scroll:       %02X", console.ppu..ppuscroll)
		// imgui.EndGroup()
		// imgui.SameLine()
		// imgui.BeginGroup()
		// imgui.Text("VRAM address: $%04X", console.ppu.mmio_register_bank.ppuaddr)
		// imgui.Text("OAM DMA:      $%02X", console.ppu.mmio_register_bank.oamdma)
		// imgui.EndGroup()
		imgui.SeparatorText("Internal Registers")
		imgui.Text("scanline: %d", console.ppu.scanline)
		imgui.Text("cycle:    %d", console.ppu.cycle)


		imgui.End()


	}

	flag_text :: proc(text: cstring, cond: bool) {
		if !cond do imgui.PushStyleColor(.Text, 0xaaffffff)
		imgui.Text(text)
		if !cond do imgui.PopStyleColor()
	}

	get_palette_color :: proc(palette_index, offset: int) -> u32 {
		c := emulator.ppu_get_color_from_palette(console, uint(palette_index), uint(offset))
		// c.a = 0xff
		// return transmute(u32)c
		color := transmute(u32)c
		return reverse_bytes((color << 8) | 0xff)

		reverse_bytes :: proc(n: u32) -> u32 {
			result: u32 = 0
			result |= (n & 0x000000FF) << 24
			result |= (n & 0x0000FF00) << 8
			result |= (n & 0x00FF0000) >> 8
			result |= (n & 0xFF000000) >> 24
			return result
		}}
}

