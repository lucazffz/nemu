package nemu

import "base:intrinsics"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"

RESOURCE_DIR_PATH :: #directory + "resources/"
RESOURCE_FILE_EXTENSION :: ".nres"
RESOURCE_TRACKER_PATH :: Resource_Path(RESOURCE_DIR_PATH + "tracker" + RESOURCE_FILE_EXTENSION)


Resource_Tracker :: struct($T: typeid) where intrinsics.type_is_union(T) {
	resource_descs:   [dynamic]Resource_Desc(T),
	loaded_resources: map[Resource_Path]Resource(T),
	// allocator:        mem.Allocator,
}

// absolute path to resource
Resource_Path :: distinct string

Rom :: struct {
	value:      int,
	save_paths: []Resource_Path,
}

Palette :: struct {
}

Somethin :: struct {
}

Resource_Type :: union #no_nil {
	Rom,
	Palette,
}

// Resources :: map[Resource_ID]Resource_Info

// g_resources: Resources


Resource_Desc :: struct($T: typeid) {
	name: string,
	path: Resource_Path,
	type: T,
}

Resource :: struct($T: typeid) {
	name: string,
	data: []byte,
	type: T,
}

resource_initialize_tracker :: proc($T: typeid) -> Resource_Tracker(T) {
	tracker: Resource_Tracker(T)
	if !os.exists(RESOURCE_DIR_PATH) {
		os.make_directory(RESOURCE_DIR_PATH)
		tracker = resource_make_default_tracker(T)
		data, _ := json.marshal(tracker)
		_ = os.write_entire_file_or_err(string(RESOURCE_TRACKER_PATH), data)
	} else {
		data, _ := os.read_entire_file_from_filename(string(RESOURCE_TRACKER_PATH))
		_ = json.unmarshal(data, &tracker)
	}

	return tracker
}

resource_make_default_tracker :: proc($T: typeid) -> Resource_Tracker(T) {
	tracker: Resource_Tracker(T)
	tracker.loaded_resources = make(map[Resource_Path]Resource(T))
	tracker.resource_descs = make([dynamic]Resource_Desc(T))

	// backing := make_slice([]byte, 2 * runtime.Megabyte)
	// arena := new(mem.Arena)
	// mem.arena_init(arena, backing)
	// allocator := mem.arena_allocator(arena)
	// tracker.allocator = allocator

	return {}
}

resource_destroy_tracker :: proc() {

}

// write to disk, add to resource tracker 
// bytes now owned by resouce system
resource_create_with_data :: proc(
	tracker: ^Resource_Tracker($T),
	desc: Resource_Desc(T),
	bytes: []byte,
) -> bool {
	// context.allocator = tracker.allocator
	if !os.exists(RESOURCE_DIR_PATH) do return false
	if resource_path_exists(tracker^, desc.path) do return false

	append_elem(&tracker.resource_descs, desc)
	data, _ := json.marshal(tracker^)
	resource_write_bytes(RESOURCE_TRACKER_PATH, data)

	_ = os.write_entire_file_or_err(string(desc.path), bytes)

	return true
}

resource_desc :: proc(name: string, type: $T) -> Resource_Desc(T) {
	path := resource_get_path_from_name(name)
	// dependency_paths := make([dynamic]Resource_Path)
	desc := Resource_Desc(T){name, path, type}
	return desc
}

resource_desc_add_dependency :: proc(desc: ^Resource_Desc($T), path: Resource_Path) {
	append_elem(&desc.dependency_paths, path)
}


resource_path_exists :: proc(tracker: Resource_Tracker($T), path: Resource_Path) -> bool {
	_, exists := resource_tracker_get_desc_from_path(tracker, path)
	return exists
}

resource_tracker_get_desc_from_name :: proc(
	tracker: Resource_Tracker($T),
	name: string,
) -> (
	Resource_Desc(T),
	bool,
) {
	path := resource_get_path_from_name(name)
	return resource_tracker_get_desc_from_path(path)
}

resource_tracker_get_desc_from_path :: proc(
	tracker: Resource_Tracker($T),
	path: Resource_Path,
) -> (
	Resource_Desc(T),
	bool,
) {
	for info in tracker.resource_descs {
		if info.path == path {
			return info, true
		}
	}

	return {}, false
}

resource_write_bytes :: proc(path: Resource_Path, bytes: []byte) {
	_ = os.write_entire_file_or_err(string(path), bytes)
}

resource_get_path_from_name :: proc(name: string) -> Resource_Path {
	return Resource_Path(fmt.tprint(RESOURCE_DIR_PATH, name, RESOURCE_FILE_EXTENSION))
}

// load resource and references from disk
resource_load_from_path :: proc(
	tracker: ^Resource_Tracker($T),
	path: Resource_Path,
) -> (
	resource: ^Resource(T),
	ok: bool,
) {
	// context.allocator = tracker.allocator

	// resource already loaded
	if v, ok := &tracker.loaded_resources[path]; ok {
		return v, true
	}

	desc := resource_tracker_get_desc_from_path(tracker^, path) or_return
	data := os.read_entire_file_from_filename(string(path)) or_return

	// for path in desc.dependency_paths {
	// 	resource = resource_load_from_path(tracker, path) or_return
	// 	append_elem(&dependencies, resource)
	// }

	tracker.loaded_resources[path] = {
		name = desc.name,
		data = data,
		type = desc.type,
	}

	return &tracker.loaded_resources[path], true
}

// deallocate bytes loaded from disk
resource_unload :: proc(info: Resource_Desc($T)) {

}

rom_resource_create_from_filename :: proc(tracker: ^Resource_Tracker($T), filename: string) {
	rom, e := os.read_entire_file_or_err(filename)
	name := filepath.base(filename)
	meta := Resource_Type(Rom{save_paths = {"some test path"}})
	desc := resource_desc(name, meta)
	resource_create_with_data(tracker, desc, rom)
}

