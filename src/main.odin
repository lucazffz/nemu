package nemu

import "base:builtin"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import emu "emulator"
import "utils"
import rlimgui "vendor/imgui_impl_raylib"
import imgui "vendor/odin-imgui"
import rl "vendor:raylib"

GAME_WIDTH :: 256
GAME_HEIGHT :: 240

Emulation_State :: enum {
	Run,
	Step,
	Pause,
	Run_Until_Instruction,
	Run_Until_Cycle,
	Run_Until_Frame,
}

// ASSETS_DIRECTORY_PATH :: #config(ASSETS_DIRECTORY_PATH, #directory + "./assets")

// default_context: runtime.Context

// Vec2 :: [2]f32
// Vec3 :: [2]f32


// All global program state is organized within this variable
g: struct #no_copy {
	rom_file_path:  string,
	multi_logger:   runtime.Logger,
	console_logger: runtime.Logger,
	// Global state related to emulator
	emulator:       struct {
		err:               Maybe(emu.Error),
		// @note state is written to by both threads without synchronization,
		// may cause data race but unsure if thats a problem
		state:             Emulation_State,
		console:           ^emu.Console,
		mapper:            emu.Mapper,
		frame_mutex:       sync.Mutex,
		frame_time:        time.Duration,
		target_frame_time: time.Duration,
	},
	// Global state related to game view
	view:           struct {
		target_refresh_rate: i32,
		render_mutex:        sync.Mutex,
		game_view_texture:   rl.Texture2D,
		front_buffer:        []emu.Color,
		back_buffer:         []emu.Color,
	},
	// Global state related to debug UI
	debug_ui:       struct {
		log_mutex:               sync.Mutex,
		logger:                  runtime.Logger,
		log_buf:                 imgui.TextBuffer,
		show:                    bool,
		dockspace_id:            imgui.ID,
		pattern_table_0_texture: rl.Texture2D,
		pattern_table_1_texture: rl.Texture2D,
		pattern_table_0_buffer:  []u32,
		pattern_table_1_buffer:  []u32,
	},
}

main :: proc() {
	console_logger := log.create_console_logger()
	context.logger = console_logger

	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer {
			context.logger = console_logger
			log_tracking_allocator_results(&track)
		}
	}

	if len(os.args) != 2 {
		log.errorf(
			"ERROR: Expected 1 argument of format 'nemu <rom file path>', got %d",
			len(os.args) - 1,
		)
		os.exit(1)
	}

	g.rom_file_path = os.args[1]

	initialize()

	// cannot setup imgui logger before initialization
	g.debug_ui.logger = utils.create_imgui_logger(
		&g.debug_ui.log_buf,
		&g.debug_ui.log_mutex,
		opt = {.Time},
	)

	g.multi_logger = log.create_multi_logger(console_logger, g.debug_ui.logger)
	context.logger = g.multi_logger

	th := thread.create_and_start(emulator_loop, context, .High)
	main_loop()

	thread.terminate(th, 0)
	shutdown()

	return

	log_tracking_allocator_results :: proc(track: ^mem.Tracking_Allocator) {
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

			mem.tracking_allocator_destroy(track)
		}
	}
}


initialize :: proc() {
	// Read ROM from iNES file
	rom, err := os.read_entire_file_or_err(g.rom_file_path)
	if err != nil {
		log.errorf("ERROR: could not open file '%s', %v", g.rom_file_path, err)
		os.exit(1)
	}
	defer delete(rom)

	if ok := emu.ines_is_nes_file_format(rom); !ok {
		log.errorf("ERROR: file '%s' is not in iNES format", g.rom_file_path)
		os.exit(1)
	}


	// Initialize console and mapper
	ines := emu.get_ines_from_bytes(rom)

	if err := emu.console_vet_ines(ines); err != nil {
		emu.error_log(err.?)
		os.exit(1)
	}

	g.emulator.console = emu.console_make()
	g.emulator.mapper = emu.mapper_make_from_ines(ines)

	emu.console_initialize_with_mapper(g.emulator.console, g.emulator.mapper)
	_ = emu.console_reset(g.emulator.console)

	g.emulator.target_frame_time = time.Second / 60

	g.view.front_buffer = make([]emu.Color, GAME_WIDTH * GAME_HEIGHT)
	g.view.back_buffer = make([]emu.Color, GAME_WIDTH * GAME_HEIGHT)

	g.debug_ui.pattern_table_0_buffer = make([]u32, 128 * 128)
	g.debug_ui.pattern_table_1_buffer = make([]u32, 128 * 128)


	// Intialize Raylib
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .WINDOW_ALWAYS_RUN, .VSYNC_HINT})
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

	pattern_table_0_img := rl.Image {
		data    = raw_data(g.debug_ui.pattern_table_0_buffer),
		width   = 128,
		height  = 128,
		mipmaps = 1,
		format  = rl.PixelFormat.UNCOMPRESSED_R8G8B8A8,
	}

	pattern_table_1_img := rl.Image {
		data    = raw_data(g.debug_ui.pattern_table_0_buffer),
		width   = 128,
		height  = 128,
		mipmaps = 1,
		format  = rl.PixelFormat.UNCOMPRESSED_R8G8B8A8,
	}

	g.debug_ui.pattern_table_0_texture = rl.LoadTextureFromImage(pattern_table_0_img)
	g.debug_ui.pattern_table_1_texture = rl.LoadTextureFromImage(pattern_table_1_img)

	g.emulator.state = .Run
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
	utils.destroy_imgui_logger(g.debug_ui.logger)
	log.destroy_multi_logger(g.multi_logger)

	rlimgui.shutdown()
	imgui.DestroyContext()

	rl.CloseWindow()

	emu.console_delete(g.emulator.console)
	emu.mapper_delete(g.emulator.mapper)

	delete(g.view.front_buffer)
	delete(g.view.back_buffer)

	delete(g.debug_ui.pattern_table_0_buffer)
	delete(g.debug_ui.pattern_table_1_buffer)
}

emulator_is_running :: proc() -> bool {
	s := g.emulator.state
	return(
		s == .Run ||
		s == .Run_Until_Instruction ||
		s == .Run_Until_Cycle ||
		s == .Run_Until_Frame \
	)
}

emulator_loop :: proc() {
	frame_complete, instr_complete: bool;err: Maybe(emu.Error)
	time_stamp: time.Time

	for {
		if frame_complete do time_stamp = time.now()

		switch g.emulator.state {
		case .Run, .Run_Until_Instruction, .Run_Until_Cycle, .Run_Until_Frame:
			frame_complete, instr_complete, err = emu.console_execute_clk_cycle(
				g.emulator.console,
				g.view.back_buffer,
			)
		case .Step:
			frame_complete, instr_complete, err = emu.console_execute_clk_cycle(
				g.emulator.console,
				g.view.back_buffer,
			)
			g.emulator.state = .Pause
		case .Pause:
		// do nothing
		}

		if err != nil do emu.error_log(err.?)


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

		free_all(context.temp_allocator)
	}
}

main_loop :: proc() {
	// monitor_num := rl.GetCurrentMonitor()
	// refresh_rate := rl.GetMonitorRefreshRate(monitor_num)
	// if refresh_rate == 0 {
	// 	log.warn("WARNING: Could not get monitor refresh rate, will default to 60 Hz")
	// 	g.view.target_refresh_rate = 60
	// } else {
	// 	g.view.target_refresh_rate = refresh_rate
	// 	log.infof("INFO: Refresh rate set to %d Hz", refresh_rate)
	// }

	// rl.SetTargetFPS(refresh_rate)

	for !rl.WindowShouldClose() {
		if rl.IsKeyPressed(.F3) do g.debug_ui.show = !g.debug_ui.show

		critical_section: if sync.guard(&g.view.render_mutex) {
			rl.UpdateTexture(g.view.game_view_texture, raw_data(g.view.front_buffer))
		}

		rl.BeginDrawing()
		// rl.ClearBackground(rl.BLACK)

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

	emu.controller_set_buttons(&g.emulator.console.controller1, buttons)
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
	@(static) show_game_view: bool = true
	@(static) show_log: bool = true
	@(static) show_pattern_tables: bool
	@(static) show_console_state: bool
	@(static) show_palettes: bool
	@(static) show_oam: bool

	imgui.DockSpaceOverViewport(g.debug_ui.dockspace_id)

	if imgui.BeginMainMenuBar() {
		if imgui.BeginMenu("Home") {
			imgui.EndMenu()
		}
		if imgui.BeginMenu("View") {
			imgui.Checkbox("Game View", &show_game_view)
			imgui.Checkbox("Log", &show_log)
			imgui.Checkbox("Pattern Tables", &show_pattern_tables)
			imgui.Checkbox("Console State", &show_console_state)
			imgui.Checkbox("Palettes", &show_palettes)
			imgui.Checkbox("PPU OAM", &show_oam)

			imgui.EndMenu()
		}

		if imgui.BeginMenu("Control") {
			if emulator_is_running() {
				if imgui.MenuItem("Pause") {
					g.emulator.state = .Pause
					log.info("INFO: Pause emulator")
				}
			} else {
				if imgui.MenuItem("Run") {
					g.emulator.state = .Run
					log.info("INFO: Run emulator")
				}
			}

			if imgui.MenuItem("Step", enabled = !emulator_is_running()) {
				g.emulator.state = .Step
				log.info("INFO: Step emulator")
			}

			if imgui.MenuItem("Reset", enabled = !emulator_is_running()) {
				slice.fill(g.view.front_buffer, 0x0)
				_ = emu.console_reset(g.emulator.console)
				log.info("INFO: Reset emulator")
			}

			// @note if reloading console while running the emulation thread
			// might try to access freed memory, therefore must ensure that
			// emulation is paused
			if imgui.MenuItem("Reload ROM", enabled = !emulator_is_running()) {
				slice.fill(g.view.front_buffer, 0x0)

				rom, err := os.read_entire_file_or_err(g.rom_file_path)
				if err != nil {
					log.errorf("ERROR: could not open file '%s', %v", g.rom_file_path, err)
					os.exit(1)
				}
				defer delete(rom)

				if ok := emu.ines_is_nes_file_format(rom); !ok {
					log.errorf("ERROR: file '%s' is not in iNES format", g.rom_file_path)
					os.exit(1)
				}


				// Initialize console and mapper
				ines := emu.get_ines_from_bytes(rom)

				if err := emu.console_vet_ines(ines); err != nil {
					emu.error_log(err.?)
					os.exit(1)
				}

				emu.console_delete(g.emulator.console)
				emu.mapper_delete(g.emulator.mapper)
				g.emulator.console = emu.console_make()
				g.emulator.mapper = emu.mapper_make_from_ines(ines)

				emu.console_initialize_with_mapper(g.emulator.console, g.emulator.mapper)
				_ = emu.console_reset(g.emulator.console)

				log.infof("INFO: Reload emulator from ROM '%s'", g.rom_file_path)
			}

			imgui.EndMenu()
		}

		imgui.EndMainMenuBar()
	}

	if show_game_view {
		flags := imgui.WindowFlags{.NoScrollbar, .MenuBar}
		imgui.PushStyleVarImVec2(imgui.StyleVar.WindowPadding, {})
		if imgui.Begin("Game View", &show_game_view, flags) {
			imgui.PopStyleVar()

			@(static) scaling_mode: enum {
				Keep_Aspect_Ratio,
				Fill_Space,
			} = .Keep_Aspect_Ratio

			if imgui.BeginMenuBar() {
				if imgui.BeginMenu("Scaling Options") {
					if imgui.RadioButton("Keep Aspect Ratio", scaling_mode == .Keep_Aspect_Ratio) {
						scaling_mode = .Keep_Aspect_Ratio
						log.infof("changed game window scaling mode to %v", scaling_mode)
						imgui.CloseCurrentPopup()
					}

					if imgui.RadioButton("Fill Window", scaling_mode == .Fill_Space) {
						scaling_mode = .Fill_Space
						log.infof("changed game window scaling mode to %v", scaling_mode)
						imgui.CloseCurrentPopup()
					}

					imgui.EndMenu()
				}

				imgui.EndMenuBar()
			}

			w := imgui.GetCurrentWindow()
			top_padding := w.TitleBarHeight + w.MenuBarHeight
			if scaling_mode == .Keep_Aspect_Ratio {
				window_height := w.Size.y - top_padding
				window_width := w.Size.x

				if window_height < window_width {
					game_view_size := window_height
					x := (window_width - game_view_size) / 2
					imgui.SetCursorPosX(x)
					rlimgui.image_size(&g.view.game_view_texture, game_view_size)
				} else {
					game_view_size := window_width
					y := ((window_height - game_view_size) / 2) + top_padding
					imgui.SetCursorPosY(y)
					rlimgui.image_size(&g.view.game_view_texture, game_view_size)
				}
			} else if scaling_mode == .Fill_Space {
				game_view_size: imgui.Vec2 = {w.Size.x, w.Size.y - top_padding}
				rlimgui.image_size(&g.view.game_view_texture, game_view_size)
			}
		}

		imgui.End()
	}

	if show_log {
		@(static) wrap_text := false
		@(static) enable_auto_scroll := true

		if imgui.Begin("Log", &show_log, {.MenuBar, .NoScrollbar}) {
			if imgui.BeginMenuBar() {
				if imgui.BeginMenu("Filter") {
					imgui.EndMenu()
				}

				imgui.Checkbox("Wrap Text", &wrap_text)

				if imgui.Button("Clear") {
					if sync.mutex_guard(&g.debug_ui.log_mutex) {
						imgui.TextBuffer_clear(&g.debug_ui.log_buf)
					}
					imgui.SetScrollHereY(1)
				}

				if imgui.Button("Scroll To Bottom") {
					imgui.SetScrollHereY(1)
					enable_auto_scroll = true
				}

				imgui.EndMenuBar()
			}

			str: cstring
			if sync.mutex_guard(&g.debug_ui.log_mutex) {
				str = imgui.TextBuffer_begin(&g.debug_ui.log_buf)
			}

			if wrap_text do imgui.TextWrapped("%s", str)
			else do imgui.TextUnformatted(str)

			// Handle auto scrolling, yes shit code. I dont even know how it works.
			// but that comment was fkn formatted so its okay
			// yes its 2 AM...
			if imgui.GetScrollY() >= imgui.GetScrollMaxY() - imgui.GetStyle().ScrollbarSize {
				enable_auto_scroll = true
			}

			if enable_auto_scroll &&
			   imgui.GetScrollY() >= imgui.GetScrollMaxY() - imgui.GetStyle().ScrollbarSize {
				imgui.SetScrollHereY(1)
			}

			if enable_auto_scroll &&
			   imgui.GetScrollY() < imgui.GetScrollMaxY() - imgui.GetStyle().ScrollbarSize * 2 {
				enable_auto_scroll = false
			}

			imgui.End()
		}
	}

	if show_palettes {
		imgui.Begin("Palette Table View", &show_palettes, {.MenuBar})

		@(static) orientation: enum {
			Vertical,
			Horizontal,
		} = .Horizontal

		if imgui.BeginMenuBar() {
			if imgui.BeginMenu("Orientation") {
				if imgui.RadioButton("Vertical", orientation == .Vertical) {
					orientation = .Vertical
					imgui.CloseCurrentPopup()
				}

				if imgui.RadioButton("Horizontal", orientation == .Horizontal) {
					orientation = .Horizontal
					imgui.CloseCurrentPopup()
				}

				imgui.EndMenu()
			}

			imgui.EndMenuBar()
		}


		draw_list := imgui.GetWindowDrawList()
		pos := imgui.GetWindowPos()
		w := imgui.GetCurrentWindow()
		padding_y := w.TitleBarHeight + w.MenuBarHeight

		v_num, h_num: f32

		palettes: f32 = 8
		colors_per_palette: f32 = 4
		ratio := palettes / colors_per_palette

		if orientation == .Vertical {
			v_num = palettes
			h_num = colors_per_palette
		} else {
			v_num = colors_per_palette
			h_num = palettes
		}

		box_height := (w.Size.y - padding_y) / v_num
		box_width := w.Size.x / h_num
		box_size := math.min(box_height, box_width)

		if box_height > box_width {
			pos.y += (w.Size.y - padding_y - (box_width * v_num)) / 2 + padding_y
		} else {
			pos.y += padding_y
			pos.x += (w.Size.x - (box_height * h_num)) / 2
		}

		for j in 0 ..< v_num {
			for i in 0 ..< h_num {
				pal, idx: int
				if orientation == .Vertical {
					pal = int(j)
					idx = int(i)
				} else {
					idx = int(i) % int(colors_per_palette)
					pal = int(j) * int(ratio) + (i >= colors_per_palette ? 1 : 0)
				}

				imgui.DrawList_AddRectFilled(
					draw_list,
					{pos.x + f32(i) * box_size, (pos.y + f32(j) * box_size)},
					{pos.x + (f32(i) + 1) * box_size, pos.y + (f32(j) + 1) * box_size},
					get_palette_color(pal, idx),
				)
			}
		}
		imgui.End()
	}

	if show_oam {
		@(static) wrap_text := false

		imgui.Begin("Object Attribute Memory View", &show_oam, {.MenuBar})

		@(static) align: enum {
			Left,
			Middle,
		} = .Middle

		if imgui.BeginMenuBar() {
			if imgui.BeginMenu("Alignment") {
				if imgui.RadioButton("Left", align == .Left) {
					align = .Left
					imgui.CloseCurrentPopup()
				}

				if imgui.RadioButton("Middle", align == .Middle) {
					align = .Middle
					imgui.CloseCurrentPopup()
				}

				imgui.EndMenu()
			}

			imgui.Checkbox("Wrap Text", &wrap_text)

			imgui.EndMenuBar()
		}

		for sprite in g.emulator.console.ppu.oam.sprites {
			cstr := fmt.ctprintf(
				"(%03d, %03d), ID: %03d, PAL: %d, PRI: %d, HFLIP: %d, VFLIP: %d",
				sprite.x_pos,
				sprite.y_pos,
				sprite.tile_index,
				sprite.attributes.palette_index,
				sprite.attributes.priority,
				sprite.attributes.flip_horizontally ? 1 : 0,
				sprite.attributes.flip_vertically ? 1 : 0,
			)

			if align == .Middle {
				w := imgui.GetCurrentWindow()
				text_size := imgui.CalcTextSize(cstr)
				x := (w.Size.x - text_size.x) / 2
				imgui.SetCursorPosX(x)
			}

			if wrap_text do imgui.TextWrapped("%s", cstr)
			else do imgui.TextUnformatted(cstr)
		}

		imgui.End()
	}

	if show_pattern_tables {
		imgui.PushStyleVarImVec2(imgui.StyleVar.WindowPadding, {})
		defer imgui.PopStyleVar()

		imgui.Begin("Pattern Table View", &show_pattern_tables, {.MenuBar})

		@(static) orientation: enum {
			Vertical,
			Horizontal,
		} = .Horizontal

		if imgui.BeginMenuBar() {
			if imgui.BeginMenu("Orientation") {
				if imgui.RadioButton("Vertical", orientation == .Vertical) {
					orientation = .Vertical
					imgui.CloseCurrentPopup()
				}

				if imgui.RadioButton("Horizontal", orientation == .Horizontal) {
					orientation = .Horizontal
					imgui.CloseCurrentPopup()
				}

				imgui.EndMenu()
			}

			imgui.EndMenuBar()
		}

		emu.ppu_pattern_table_palette_offset_to_buffer(
			g.emulator.console,
			g.debug_ui.pattern_table_0_buffer,
			0,
		)
		emu.ppu_pattern_table_palette_offset_to_buffer(
			g.emulator.console,
			g.debug_ui.pattern_table_1_buffer,
			1,
		)


		for &val in g.debug_ui.pattern_table_0_buffer {
			if val == 0 do continue
			val = 0xffffffff
		}

		for &val in g.debug_ui.pattern_table_1_buffer {
			if val == 0 do continue
			val = 0xffffffff
		}

		rl.UpdateTexture(
			g.debug_ui.pattern_table_0_texture,
			raw_data(g.debug_ui.pattern_table_0_buffer),
		)
		rl.UpdateTexture(
			g.debug_ui.pattern_table_1_texture,
			raw_data(g.debug_ui.pattern_table_1_buffer),
		)

		offset: imgui.Vec2
		w := imgui.GetCurrentWindow()
		padding_y := w.TitleBarHeight + w.MenuBarHeight

		v_num, h_num: f32

		if orientation == .Vertical {
			v_num = 2
			h_num = 1
		} else {
			v_num = 1
			h_num = 2
		}

		box_height := (w.Size.y - padding_y) / v_num
		box_width := w.Size.x / h_num
		box_size := math.min(box_height, box_width)

		if box_height > box_width {
			offset.y = (w.Size.y - padding_y - (box_width * v_num)) / 2 + padding_y
		} else {
			offset.y = padding_y
			offset.x = (w.Size.x - (box_height * h_num)) / 2
		}

		size: imgui.Vec2 = {box_size, box_size}
		imgui.SetCursorPos(offset)
		rlimgui.image_size(&g.debug_ui.pattern_table_0_texture, size)

		if orientation == .Horizontal {
			imgui.SameLine()
		} else {
			offset.y += box_size
			imgui.SetCursorPos(offset)
		}

		rlimgui.image_size(&g.debug_ui.pattern_table_1_texture, size)

		imgui.End()
	}

	get_palette_color :: proc(#any_int palette_index, offset: uint) -> u32 {
		c := emu.ppu_get_color_from_palette(g.emulator.console, palette_index, offset)
		return transmute(u32)c
	}
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

// }

