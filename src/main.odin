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
import "core:sync"
import "core:thread"
import "core:time"
import emu "emulator"
import rlimgui "vendor/imgui_impl_raylib"
import imgui "vendor/odin-imgui"
import rl "vendor:raylib"

GAME_WIDTH :: 256
GAME_HEIGHT :: 240

// ASSETS_DIRECTORY_PATH :: #config(ASSETS_DIRECTORY_PATH, #directory + "./assets")

// default_context: runtime.Context

// Vec2 :: [2]f32
// Vec3 :: [2]f32

// pattern_table_0_texture: rl.Texture2D
// pattern_table_1_texture: rl.Texture2D

// All global program state is organized within this variable
@(private)
g: struct {
	console:       ^emu.Console,
	mapper:        emu.Mapper,
	rom_file_path: string,
	// Global state related to emulator
	emulator:      struct {
		// frame_cond:        sync.Cond,
		frame_mutex:       sync.Mutex,
		frame_time:        time.Duration,
		target_frame_time: time.Duration,
		// frame_complete:    bool,
		// instruction_complete: bool,
		run:               bool,
	},
	// Global state related to game view
	view:          struct {
		render_cond:       sync.Cond,
		render_mutex:      sync.Mutex,
		game_view_texture: rl.Texture2D,
		front_buffer:      []emu.Color,
		back_buffer:       []emu.Color,
	},
	// Global state related to debug UI
	debug_ui:      struct {
		show:                   bool,
		dockspace_id:           imgui.ID,
		patter_table_0_texture: rl.RenderTexture2D,
		patter_table_1_texture: rl.RenderTexture2D,
	},
}

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

	// emulator.console_set_program_counter(console, 0xc000)

	// emulator.ppu_write_to_address(console, 0xc, 0x3f00)
	// emulator.ppu_write_to_address(console, 0x2, 0x3f00 + 1)
	// emulator.ppu_write_to_address(console, 0x5, 0x3f00 + 2)
	// emulator.ppu_write_to_address(console, 0x6, 0x3f00 + 3)

	// palette_index_buffer_0: [128 * 128]uint
	// palette_index_buffer_1: [128 * 128]uint

	// emulator.ppu_pattern_table_palette_offset_to_buffer(console, palette_index_buffer_0[:], 0)
	// emulator.ppu_pattern_table_palette_offset_to_buffer(console, palette_index_buffer_1[:], 1)

	// pattern_table_0_buf: [128 * 128]rl.Color
	// pattern_table_1_buf: [128 * 128]rl.Color


	// for v, i in palette_index_buffer_1 {
	// 	if v == 0 do continue
	// 	pattern_table_1_buf[i] = rl.GetColor(0xffffffff)
	// }


	// pattern_table_0_img: rl.Image = {
	// 	data    = &pattern_table_0_buf,
	// 	width   = 128,
	// 	height  = 128,
	// 	mipmaps = 1,
	// 	format  = rl.PixelFormat.UNCOMPRESSED_R8G8B8A8,
	// }

	// pattern_table_1_img: rl.Image = {
	// 	data    = &pattern_table_1_buf,
	// 	width   = 128,
	// 	height  = 128,
	// 	mipmaps = 1,
	// 	format  = rl.PixelFormat.UNCOMPRESSED_R8G8B8A8,
	// }


	// game_view_img := rl.Image {
	// 	data    = raw_data(console.ppu.pixel_buffer),
	// 	width   = GAME_WIDTH,
	// 	height  = GAME_HEIGHT,
	// 	mipmaps = 1,
	// 	format  = rl.PixelFormat.UNCOMPRESSED_R8G8B8A8,
	// }


	// === RENDER ===
	// rl.SetConfigFlags({rl.ConfigFlag.WINDOW_RESIZABLE, rl.ConfigFlag.WINDOW_ALWAYS_RUN})
	// rl.InitWindow(GAME_WIDTH * 2, GAME_HEIGHT * 2, "Raylib + ImGui in Odin");defer rl.CloseWindow()

	// // Setup ImGui context
	// imgui.CreateContext(nil);defer imgui.DestroyContext(nil)

	// // Init ImGui for Raylib
	// rlimgui.init();defer rlimgui.shutdown()


	initialize()
	defer shutdown()

	thread.run(emulator_loop, nil, thread.Thread_Priority.High)

	main_loop()
	// pattern_table_0_texture = rl.LoadTextureFromImage(pattern_table_0_img)
	// pattern_table_1_texture = rl.LoadTextureFromImage(pattern_table_1_img)
	// game_view_texture = rl.LoadTextureFromImage(game_view_img)


	// when ODIN_DEBUG do show_debug_io = true

	// last_err: emu.Error

	// buf: [64]byte
	// Main loop
	// for !rl.WindowShouldClose() {
	// 	if rl.IsKeyPressed(rl.KeyboardKey.SPACE) do should_run = !should_run
	// 	if rl.IsKeyPressed(rl.KeyboardKey.F3) do show_debug_io = !show_debug_io


	// 	frame_complete, cpu_complete: bool;err: Maybe(emulator.Error)
	// 	if (rl.IsKeyPressed(rl.KeyboardKey.S) || should_run) &&
	// 	   (console.cpu.instruction_count < brk_point_instruction || brk_point_instruction == 0) {
	// 		using emulator
	// 		for (should_run || !cpu_complete) && !frame_complete {

	// 			if frame_complete, cpu_complete, err = console_execute_clk_cycle(console);
	// 			   err != nil {
	// 				if err != last_err {
	// 					err := err.?
	// 					error_log(err, log.Level.Warning)
	// 					last_err = err
	// 				}
	// 			}
	// 		}

	// 		rl.UpdateTexture(game_view_texture, raw_data(console.ppu.pixel_buffer))

	// 		if show_debug_io && frame_complete {
	// 			for v, i in palette_index_buffer_0 {
	// 				// if v == 0 do continue
	// 				// @note watch out for endianess when converting color from u32 to [4]u8
	// 				c := emulator.ppu_get_color_from_palette(console, 0, v)
	// 				pattern_table_0_buf[i] = auto_cast c
	// 			}
	// 			rl.UpdateTexture(pattern_table_0_texture, &pattern_table_0_buf)
	// 		}
	// 	}

	// 	screen_width := rl.GetScreenWidth()
	// 	screen_height := rl.GetScreenHeight()
	// 	game_view_rectangle: rl.Rectangle

	// 	if screen_height < screen_width {
	// 		game_view_size := screen_height
	// 		game_view_rectangle = {
	// 			f32((screen_width - game_view_size) / 2),
	// 			0,
	// 			f32(game_view_size),
	// 			f32(game_view_size),
	// 		}
	// 	} else {
	// 		game_view_size := screen_width
	// 		game_view_rectangle = {
	// 			0,
	// 			f32((screen_height - game_view_size) / 2),
	// 			f32(game_view_size),
	// 			f32(game_view_size),
	// 		}
	// 	}


	// 	rl.SetTargetFPS(60)

	// 	rl.BeginDrawing()
	// 	rl.ClearBackground(rl.BLACK)

	// 	// Raylib rendering
	// 	rl.DrawTexturePro(
	// 		game_view_texture,
	// 		{0, 0, GAME_WIDTH, GAME_HEIGHT},
	// 		game_view_rectangle,
	// 		{},
	// 		0,
	// 		rl.WHITE,
	// 	)


	// 	if show_debug_io {
	// 		rl.DrawFPS(15, 30)
	// 		// ImGui begin (must be called each frame BEFORE using ImGui)
	// 		rlimgui.begin()


	// 		if show_debug_io {
	// 			render_debug_ui()
	// 		}


	// 		rlimgui.end()
	// 	}


	// 	// Drawing on top of ImGui (call after 'rlimgui.end()' to do that, as showed here)
	// 	// rl.DrawText("Drawing on top of ImGui window", 170, 370, 30, rl.BLUE)
	// 	rl.EndDrawing()

	// 	free_all(context.temp_allocator)
	// }
}


initialize :: proc() {
	// Read ROM from iNES file
	rom_file_path := #directory + "../../roms/Super Mario Bros. (World).nes"
	rom, err := os.read_entire_file_or_err(rom_file_path)
	if err != nil {
		log.errorf("ERROR: could not open file '%s', %v", rom_file_path, err)
		os.exit(1)
	}
	defer delete(rom)

	if ok := emu.ines_is_nes_file_format(rom); !ok {
		log.errorf("ERROR: file '%s' is not in iNES format", rom_file_path)
		os.exit(1)
	}


	// Initialize console and mapper
	ines := emu.get_ines_from_bytes(rom)

	if err := emu.console_vet_ines(ines); err != nil {
		emu.error_log(err.?)
		os.exit(1)
	}

	g.console = emu.console_make()
	g.mapper = emu.mapper_make_from_ines(ines)

	emu.console_initialize_with_mapper(g.console, g.mapper)
	_ = emu.console_reset(g.console)

	g.emulator.target_frame_time = time.Second / 60

	g.view.front_buffer = make([]emu.Color, GAME_WIDTH * GAME_HEIGHT)
	g.view.back_buffer = make([]emu.Color, GAME_WIDTH * GAME_HEIGHT)

	when ODIN_DEBUG {
		g.debug_ui.show = true
	} else {
		g.emulator.run = true
	}

	// Intialize Raylib
	rl.SetConfigFlags({rl.ConfigFlag.WINDOW_RESIZABLE, rl.ConfigFlag.WINDOW_ALWAYS_RUN})
	rl.InitWindow(GAME_WIDTH * 2, GAME_HEIGHT * 2, "Nemu")

	// Initialize debug UI
	ctx := imgui.CreateContext()
	ctx.IO.ConfigFlags += {.DockingEnable}
	imgui.SetCurrentContext(ctx)

	rlimgui.init()


	rlimgui.begin()
	init_debug_ui()
	rlimgui.end()

	game_view_img := rl.Image {
		data    = raw_data(g.view.front_buffer),
		width   = GAME_WIDTH,
		height  = GAME_HEIGHT,
		mipmaps = 1,
		format  = rl.PixelFormat.UNCOMPRESSED_R8G8B8A8,
	}
	g.view.game_view_texture = rl.LoadTextureFromImage(game_view_img)


}

atomic_buffer_swap :: proc(buffer_1: ^[]$E, buffer_2: ^[]E, mutex: ^sync.Mutex) {
	assert(len(buffer_1) == len(buffer_2), "buffers must have same length")

	sync.mutex_lock(mutex)
	defer sync.mutex_unlock(mutex)

	temp := buffer_1^
	buffer_1^ = buffer_2^
	buffer_2^ = temp
}


shutdown :: proc() {
	emu.console_delete(g.console)
	emu.mapper_delete(g.mapper)
	rlimgui.shutdown()
	imgui.DestroyContext()
	rl.CloseWindow()
}

emulator_loop :: proc() {
	time_stamp: time.Time
	frame_complete, instr_complete: bool;err: Maybe(emu.Error)
	for {
		if frame_complete do time_stamp = time.now()

		if g.emulator.run {
			frame_complete, instr_complete, err = emu.console_execute_clk_cycle(
				g.console,
				g.view.back_buffer,
			)
		}

		if instr_complete {
			update_controller_input()
		}

		if frame_complete {
			atomic_buffer_swap(&g.view.front_buffer, &g.view.back_buffer, &g.view.render_mutex)

			dt := time.diff(time_stamp, time.now())
			sleep_time := math.max(0, g.emulator.target_frame_time - dt)
			time.sleep(sleep_time)

			g.emulator.frame_time = time.diff(time_stamp, time.now())
		}
	}
}

main_loop :: proc() {
	monitor_num := rl.GetMonitorCount()
	refresh_rate := rl.GetMonitorRefreshRate(monitor_num)
	if refresh_rate == 0 do refresh_rate = 60

	for !rl.WindowShouldClose() {
		rl.SetTargetFPS(refresh_rate)

		if rl.IsKeyPressed(.F3) do g.debug_ui.show = !g.debug_ui.show


		critical_section: if sync.guard(&g.view.render_mutex) {
			rl.UpdateTexture(g.view.game_view_texture, raw_data(g.view.front_buffer))
		}


		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)

		if !g.debug_ui.show {
			rl.DrawTexturePro(
				g.view.game_view_texture,
				{0, 0, GAME_WIDTH, GAME_HEIGHT},
				get_game_view_rectangle(f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())),
				{},
				0,
				rl.WHITE,
			)
		} else {
			// ImGui begin (must be called each frame BEFORE using ImGui)
			rlimgui.begin()
			render_debug_ui()
			rlimgui.end()

		}

		// Drawing on top of ImGui (call after 'rlimgui.end()' to do that, as showed here)
		// rl.DrawText("Drawing on top of ImGui window", 170, 370, 30, rl.BLUE)
		rl.EndDrawing()
	}

}

console_instruction_complete_cb :: proc() {
	update_controller_input()

}


get_game_view_rectangle :: proc(
	window_width: f32,
	window_height: f32,
	anchor: rl.Vector2 = {},
) -> rl.Rectangle {
	game_view_rectangle: rl.Rectangle

	if window_height < window_width {
		game_view_size := window_height
		game_view_rectangle = {
			f32((window_width - game_view_size) / 2) + anchor.x,
			anchor.y,
			f32(game_view_size),
			f32(game_view_size),
		}
	} else {
		game_view_size := window_width
		game_view_rectangle = {
			anchor.x,
			f32((window_height - game_view_size) / 2) + anchor.y,
			f32(game_view_size),
			f32(game_view_size),
		}
	}

	return game_view_rectangle
}

update_controller_input :: proc() {
	buttons: emu.Buttons

	if rl.IsKeyDown(.LEFT) do buttons += {.left}
	if rl.IsKeyDown(.RIGHT) do buttons += {.right}
	if rl.IsKeyDown(.UP) do buttons += {.up}
	if rl.IsKeyDown(.DOWN) do buttons += {.down}
	if rl.IsKeyDown(.X) do buttons += {.a}
	if rl.IsKeyDown(.Z) do buttons += {.b}
	if rl.IsKeyDown(.ONE) do buttons += {.select}
	if rl.IsKeyDown(.TWO) do buttons += {.start}

	if rl.IsGamepadAvailable(0) {
		if rl.IsGamepadButtonDown(0, .LEFT_FACE_LEFT) do buttons += {.left}
		if rl.IsGamepadButtonDown(0, .LEFT_FACE_RIGHT) do buttons += {.right}
		if rl.IsGamepadButtonDown(0, .LEFT_FACE_UP) do buttons += {.up}
		if rl.IsGamepadButtonDown(0, .LEFT_FACE_DOWN) do buttons += {.down}
		if rl.IsGamepadButtonDown(0, .RIGHT_FACE_DOWN) do buttons += {.a}
		if rl.IsGamepadButtonDown(0, .RIGHT_FACE_LEFT) do buttons += {.b}
		if rl.IsGamepadButtonDown(0, .MIDDLE_LEFT) do buttons += {.select}
		if rl.IsGamepadButtonDown(0, .MIDDLE_RIGHT) do buttons += {.start}
	}

	emu.controller_set_buttons(&g.console.controller1, buttons)
}

init_debug_ui :: proc() {
	dockspace_id := imgui.GetID("MainDockSpace")
	g.debug_ui.dockspace_id = dockspace_id

	viewport := imgui.GetMainViewport()

	if imgui.DockBuilderGetNode(dockspace_id) == nil {
		imgui.DockBuilderRemoveNode(dockspace_id)
		imgui.DockBuilderAddNode(dockspace_id)
		imgui.DockBuilderSetNodeSize(dockspace_id, viewport.Size)

		dock_id_main := dockspace_id
		dock_id_left: imgui.ID
		imgui.DockBuilderSplitNode(
			dock_id_main,
			imgui.Dir.Left,
			0.25,
			&dock_id_left,
			&dock_id_main,
		)

		imgui.DockBuilderDockWindow("Game View", dock_id_main)
		imgui.DockBuilderDockWindow("test", dock_id_left)

		imgui.DockBuilderFinish(dockspace_id)
	}
}

render_debug_ui :: proc() {
	@(static) show_game_view := true

	imgui.DockSpaceOverViewport(g.debug_ui.dockspace_id)

	if show_game_view {
		imgui.PushStyleVarImVec2(imgui.StyleVar.WindowPadding, {0, 0})
		defer imgui.PopStyleVar()

		imgui.Begin("Game View", &show_game_view)
		defer imgui.End()

		w := imgui.GetCurrentWindow()
		size: imgui.Vec2 = {w.Size.x, w.Size.y - w.TitleBarHeight}
		flags := imgui.WindowFlags{.NoScrollbar}
		rlimgui.image_size(&g.view.game_view_texture, size)
	}

	imgui.Begin("test")

	imgui.End()
}
// brk_point_instruction: int

// render_debug_ui :: proc() {
// 	@(static) show_pattern_tables: bool = false
// 	@(static) show_ppu_state: bool = false
// 	@(static) show_cpu_state: bool = false
// 	@(static) show_ppu_palettes: bool = false
// 	@(static) show_ppu_oam: bool = false
// 	str_buf := make([]u8, 1024)
// 	defer delete(str_buf)

// 	// imgui.ShowDemoWindow(nil)

// 	if imgui.BeginMainMenuBar() {
// 		imgui.Checkbox("Pattern Tables", &show_pattern_tables)
// 		imgui.Checkbox("CPU State", &show_cpu_state)
// 		imgui.Checkbox("PPU State", &show_ppu_state)
// 		imgui.Checkbox("Palettes", &show_ppu_palettes)
// 		imgui.Checkbox("OAM", &show_ppu_oam)
// 		imgui.InputScalar("pause at cycle", .U32, &brk_point_instruction)
// 	}
// 	imgui.EndMainMenuBar()


// 	if show_pattern_tables {
// 		imgui.Begin("Pattern Tables", nil, {.AlwaysAutoResize})
// 		val := emulator.ppu_read_from_address(console, 0x2000)
// 		rlimgui.image_size(&pattern_table_0_texture, {256, 256})
// 		imgui.SameLine()
// 		rlimgui.image_size(&pattern_table_1_texture, {256, 256})
// 		imgui.End()
// 	}

// 	if show_ppu_palettes {
// 		imgui.Begin("Palettes", nil)
// 		draw_list := imgui.GetWindowDrawList()
// 		pos := imgui.GetWindowPos()
// 		pos.y += 30
// 		size: f32 = 20
// 		for j in 0 ..< 8 {
// 			for i in 0 ..< 4 {
// 				imgui.DrawList_AddRectFilled(
// 					draw_list,
// 					{pos.x + f32(i) * size, (pos.y + f32(j) * size)},
// 					{pos.x + (f32(i) + 1) * size, pos.y + (f32(j) + 1) * size},
// 					get_palette_color(j, i),
// 				)
// 			}
// 		}
// 		imgui.End()
// 	}

// 	if show_ppu_oam {
// 		imgui.Begin("OAM", nil)
// 		for sprite in console.ppu.oam.sprites {
// 			imgui.Text(
// 				"(%d, %d), ID: %d, PAL: %d, PRI: %d, HFLIP: %d, VFLIP: %d",
// 				sprite.x_pos,
// 				sprite.y_pos,
// 				sprite.tile_index,
// 				sprite.attributes.palette_index,
// 				sprite.attributes.priority,
// 				sprite.attributes.flip_horizontally,
// 				sprite.attributes.flip_vertically,
// 			)
// 		}

// 		imgui.End()
// 	}

// 	if show_cpu_state {
// 		imgui.Begin("CPU State", nil)
// 		imgui.BeginGroup()
// 		imgui.Text("X:  %02X", console.cpu.x)
// 		imgui.Text("Y:  %02X", console.cpu.y)
// 		imgui.Text("A:  %02X", console.cpu.acc)
// 		imgui.EndGroup()
// 		imgui.SameLine()
// 		imgui.BeginGroup()
// 		imgui.Text("SP: %02X", console.cpu.sp)
// 		imgui.Text("PC: %04X", console.cpu.pc)
// 		imgui.EndGroup()
// 		imgui.SameLine()
// 		imgui.BeginGroup()
// 		flag_text("C", .CF in console.cpu.status)
// 		imgui.SameLine()
// 		flag_text("Z", .ZF in console.cpu.status)
// 		imgui.SameLine()
// 		flag_text("I", .IF in console.cpu.status)
// 		imgui.SameLine()
// 		flag_text("V", .VF in console.cpu.status)
// 		imgui.SameLine()
// 		flag_text("N", .NF in console.cpu.status)
// 		imgui.Text("Cycle count:       %04d", console.cpu.cycle_count)
// 		imgui.Text("Instruction count: %04d", console.cpu.instruction_count)
// 		imgui.EndGroup()
// 		imgui.SeparatorText("Instructions")
// 		imgui.Text("%s", emulator.console_state_to_string(console))
// 		imgui.End()
// 	}

// 	if show_ppu_state {
// 		imgui.Begin("PPU State", nil)
// 		imgui.SeparatorText("PPUCTRL")
// 		imgui.BeginGroup()
// 		imgui.Text("nametable base address:           %d", console.ppu.ctrl.nametable_base_address)
// 		imgui.Text(
// 			"VRAM address increment:           %d",
// 			console.ppu.ctrl.vram_address_increment == 0 ? 1 : 32,
// 		)
// 		imgui.Text(
// 			"sprite pattern table address:     $%s",
// 			console.ppu.ctrl.sprite_pattern_table_address == 0 ? "0000" : "1000",
// 		)
// 		imgui.Text(
// 			"background pattern table address: $%s",
// 			console.ppu.ctrl.background_pattern_table_address == 0 ? "0000" : "1000",
// 		)
// 		imgui.EndGroup()
// 		imgui.SameLine()
// 		imgui.BeginGroup()
// 		imgui.Text("sprite size:         %s", console.ppu.ctrl.sprite_size == 0 ? "8x8" : "8x16")
// 		imgui.Text("master slave select: %d", console.ppu.ctrl.master_slave_select)
// 		imgui.Text(
// 			"vblank NMI enabled:  %s",
// 			console.ppu.ctrl.vblank_nmi_enable ? "true" : "false",
// 		)
// 		imgui.EndGroup()
// 		imgui.SeparatorText("PPUMASK")
// 		imgui.BeginGroup()
// 		flag_text("greyscale", console.ppu.mask.greyscale)
// 		flag_text("show background", console.ppu.mask.show_background_in_margin)
// 		flag_text("show sprites", console.ppu.mask.show_sprites_in_margin)
// 		flag_text("enable background rendering", console.ppu.mask.enable_background_rendering)
// 		imgui.EndGroup()
// 		imgui.SameLine()
// 		imgui.BeginGroup()
// 		flag_text("enable sprite rendering", console.ppu.mask.enable_sprite_rendering)
// 		flag_text("emphasize red", console.ppu.mask.emphasize_red)
// 		flag_text("emphasize green", console.ppu.mask.emphasize_green)
// 		flag_text("emphasize blue", console.ppu.mask.emphasize_blue)
// 		imgui.EndGroup()
// 		imgui.SeparatorText("PPUSTATUS")
// 		flag_text("sprite overflow", console.ppu.status.sprite_overflow)
// 		imgui.SameLine()
// 		flag_text("sprite_0_hit", console.ppu.status.sprite_0_hit)
// 		imgui.SameLine()
// 		flag_text("vblank", console.ppu.status.vblank)
// 		// imgui.SeparatorText("Other")
// 		// imgui.BeginGroup()
// 		// imgui.Text("OAM address:  $%02X", console.ppu.oamaddr)
// 		// imgui.Text("scroll:       %02X", console.ppu..ppuscroll)
// 		// imgui.EndGroup()
// 		// imgui.SameLine()
// 		// imgui.BeginGroup()
// 		// imgui.Text("VRAM address: $%04X", console.ppu.mmio_register_bank.ppuaddr)
// 		// imgui.Text("OAM DMA:      $%02X", console.ppu.mmio_register_bank.oamdma)
// 		// imgui.EndGroup()
// 		imgui.SeparatorText("Internal Registers")
// 		imgui.Text("scanline: %d", console.ppu.scanline)
// 		imgui.Text("cycle:    %d", console.ppu.cycle)


// 		imgui.End()


// 	}

// 	flag_text :: proc(text: cstring, cond: bool) {
// 		if !cond do imgui.PushStyleColor(.Text, 0xaaffffff)
// 		imgui.Text(text)
// 		if !cond do imgui.PopStyleColor()
// 	}

// 	get_palette_color :: proc(palette_index, offset: int) -> u32 {
// 		c := emulator.ppu_get_color_from_palette(console, uint(palette_index), uint(offset))
// 		return transmute(u32)c
// 	}
// }

