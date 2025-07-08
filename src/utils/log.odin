package utils

import imgui "../vendor/odin-imgui"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"

ImGui_Logger_Data :: struct {
	text_buffer: ^imgui.TextBuffer,
	allocator:   runtime.Allocator,
	ident:       string,
	mutex:       Maybe(^sync.Mutex),
}

create_imgui_logger :: proc(
	buf: ^imgui.TextBuffer,
	mutex: ^sync.Mutex = nil,
	lowest := log.Level.Debug,
	opt := log.Default_Console_Logger_Opts,
	ident := "",
	allocator := context.allocator,
) -> log.Logger {
	data := new(ImGui_Logger_Data, allocator)
	data.allocator = allocator
	data.ident = ident
	data.text_buffer = buf
	data.mutex = mutex

	return log.Logger{imgui_logger_proc, rawptr(data), lowest, opt}
}

imgui_logger_proc :: proc(
	logger_data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	data := cast(^ImGui_Logger_Data)logger_data
	backing: [256]byte
	buf := strings.builder_from_bytes(backing[:])


	opts := options - {log.Option.Terminal_Color}
	log.do_level_header(opts, &buf, level)
	log.do_time_header(opts, &buf, time.now())
	log.do_location_header(opts, &buf, location)

	if .Thread_Id in opts {
		// NOTE(Oskar): not using context.thread_id here since that could be
		// incorrect when replacing context for a thread.
		fmt.sbprintf(&buf, "[{}] ", os.current_thread_id())
	}

	if data.ident != "" {
		fmt.sbprintf(&buf, "[%s] ", data.ident)
	}

	fmt.sbprintfln(&buf, text)
	//TODO(Hoej): When we have better atomics and such, make this thread-safe

	c_str, _ := strings.to_cstring(&buf)

	if mutex, ok := data.mutex.?; ok {
		sync.mutex_guard(mutex)
		imgui.TextBuffer_append(data.text_buffer, c_str)
	} else {
		imgui.TextBuffer_append(data.text_buffer, c_str)
	}
}

destroy_imgui_logger :: proc(log: log.Logger, allocator := context.allocator) {
	free(log.data, allocator)
}

