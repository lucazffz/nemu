package emulator

import "base:intrinsics"
import "base:runtime"
import "core:encoding/base64"
import "core:encoding/cbor"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:reflect"

RESOURCE_DIR_PATH :: #directory + "resources/"
RESOURCE_FILE_EXTENSION :: ".nres"

Resource_Path :: distinct string
Resource_Handle :: distinct u64

Resource :: struct {
	path:   Resource_Path,
	desc:   Resource_Desc,
	data:   []byte,
	_magic: u32,
}


// Resource_Handle :: struct {
// 	_ptr:   rawptr,
// 	_magic: u16,
// }

Resource_Manager :: struct {
	current_magic: u32,
	backing:       []byte,
	base_addr:     u32,
	arena:         mem.Arena,
	allocator:     mem.Allocator,
}

Rom_Meta_Data :: struct {
	saves: []Resource_Path,
}

Palette_Type :: struct {
}

Resource_Meta_Data :: union #no_nil {
	Rom_Meta_Data,
	Palette_Type,
}

Resource_Desc :: struct {
	path: Resource_Path,
	name: string,
	meta: Resource_Meta_Data,
}

resource_manager_make :: proc() -> Resource_Manager {
	m := Resource_Manager{}

	Megabyte :: 1024 * 1024
	m.backing = make([]byte, 32 * Megabyte)
	m.base_addr = u32(uintptr(&m.backing[0]) >> 32)
	mem.arena_init(&m.arena, m.backing[:])
	m.allocator = mem.arena_allocator(&m.arena)
	m.current_magic = 0

	resource_setup_directory()
	return m
}

resource_manager_destroy :: proc(m: ^Resource_Manager) {
	delete(m.backing)
}


resource_create_with_data :: proc(
	name: string,
	data: []byte,
	meta: Resource_Meta_Data = {},
) -> os.Error {

	path := resource_get_path_from_name(name)

	if !os.exists(RESOURCE_DIR_PATH) do return os.EEXIST
	if os.exists(string(path)) do return os.EEXIST

	desc: Resource_Desc = {
		path = path,
		name = name,
		meta = meta,
	}

	flags: int = os.O_WRONLY | os.O_CREATE
	mode := os.S_IRUSR | os.S_IWUSR | os.S_IRGRP | os.S_IROTH
	fd := os.open(string(path), flags, mode) or_return
	defer os.close(fd)

	desc_bytes := resource_type_to_bytes(desc)

	len_bytes: [8]byte
	assert(endian.put_u64(len_bytes[:], .Little, u64(len(desc_bytes))))
	os.write(fd, len_bytes[:]) or_return
	os.write(fd, desc_bytes) or_return
	os.write(fd, data) or_return

	return nil
}

resource_remove :: proc(name: string) -> os.Error {
	path := resource_get_path_from_name(name)
	os.remove(string(path)) or_return
	return nil
}

resource_load_from_path :: proc(
	m: ^Resource_Manager,
	path: Resource_Path,
) -> (
	handle: Resource_Handle,
	ok: bool,
) {
	data := os.read_entire_file_from_filename(string(path), m.allocator) or_return

	desc_sz := endian.get_u64(data[:8], .Little) or_else panic("could not get length")
	desc_bytes := data[8:desc_sz + 8]
	desc := resource_type_from_bytes(desc_bytes, Resource_Desc, m.allocator)

	resource, err := new(Resource, m.allocator)
	if err != nil {
		log.error(err)
		return {}, false
	}

	m.current_magic += 1

	resource.path = path
	resource.desc = desc
	resource._magic = m.current_magic
	resource.data = data[8 + desc_sz:]

	index := u32(uintptr(resource))
	log.info(index)
	handle = resource_handle(index, m.current_magic)

	return handle, true
}

resource_load_from_name :: proc(
	m: ^Resource_Manager,
	name: string,
) -> (
	handle: Resource_Handle,
	ok: bool,
) {
	path := resource_get_path_from_name(name)
	return resource_load_from_path(m, path)
}

// resource_write :: proc(handle: Resource_Handle) {
// 	assert_handle_valid(handle)
// 	resource := cast(^Resource)handle._ptr

// }


// resource_unload :: proc(m: ^Resource_Manager, handle: Resource_Handle) -> mem.Allocator_Error {
// 	assert_handle_valid(handle)
// 	free(handle._ptr, m.pool_allocator) or_return
// 	return nil
// }


handle_get_index :: proc(handle: Resource_Handle) -> u32 {
	return u32(handle >> 32)
}

handle_get_magic :: proc(handle: Resource_Handle) -> u32 {
	return u32(handle)
}

resource_handle :: proc(index: u32, magic: u32) -> Resource_Handle {
	return Resource_Handle(u64(index << 32) | u64(magic))
}

assert_handle_valid :: proc(m: Resource_Manager, handle: Resource_Handle) {
	magic := handle_get_magic(handle)
	index := handle_get_index(handle)
	resource := cast(^Resource)(uintptr(m.base_addr) + uintptr(index))
	assert(
		magic == resource._magic,
		"resource handle not valid, associated data has been freed or moved",
	)
}

resource_get_data :: proc(m: Resource_Manager, handle: Resource_Handle) -> []byte {
	resource := resource_get_ptr(m, handle)
	return resource.data
}

resource_get_ptr :: proc(m: Resource_Manager, handle: Resource_Handle) -> ^Resource {
	assert_handle_valid(m, handle)
	magic := handle_get_magic(handle)
	index := handle_get_index(handle)
	log.info(index)
	resource := cast(^Resource)((uintptr(m.base_addr) << 32) | uintptr(index))
	return resource

}

resource_get_desc :: proc(m: Resource_Manager, handle: Resource_Handle) -> Resource_Desc {
	resource := resource_get_ptr(m, handle)
	return resource.desc
}


resource_get_path_from_name :: proc(name: string) -> Resource_Path {
	return Resource_Path(fmt.tprint(RESOURCE_DIR_PATH, name, RESOURCE_FILE_EXTENSION, sep = ""))
}

is_resource_format_from_filename :: proc(filename: string) -> bool {
	return filepath.ext(filename) == RESOURCE_FILE_EXTENSION
}

resource_setup_directory :: proc() -> os.Error {
	if !os.exists(RESOURCE_DIR_PATH) {
		os.make_directory(RESOURCE_DIR_PATH) or_return
	}

	return nil
}

resource_type_to_bytes :: proc(type: $T, allocator := context.temp_allocator) -> []byte {
	bytes := json.marshal(type, allocator = allocator) or_else panic("could not marshal type")
	return bytes
}

resource_type_from_bytes :: proc(bytes: []byte, $T: typeid, allocator := context.allocator) -> T {
	type := T{}
	err := json.unmarshal(bytes, &type, allocator = allocator)
	assert(err == nil, "could not unmarshal data")
	return type
}

// test :: proc() {
// 	if err := resource_setup_directory(); err != nil {
// 		log.error(err)
// 		os.exit(1)
// 	}

// 	m := resource_manager_make()
// 	defer resource_manager_destroy(m)

// 	// meta := Rom_Meta_Data{10, {1, 1, 1}, nil}
// 	if err := resource_create_with_data("testtest", {1, 1, 1, 1}, meta); err != nil {
// 		log.error(err)
// 	}

// 	handle, ok := resource_load_from_name(m, "testtest")
// 	if !ok {
// 		log.error("could not load resource from disk")
// 		os.exit(1)
// 	}

// 	desc := resource_get_desc(handle)
// 	data := resource_get_data(handle)
// 	fmt.println(desc)
// 	fmt.println(data)

// 	// resource_manager_initialize(Resource_Meta_Data)
// 	// bytes: []byte
// 	// {
// 	// 	s := make(map[string]int)
// 	// 	s["value"] = 10
// 	// 	defer delete(s)
// 	// 	desc := Resource_Desc(Resource_Meta_Data) {
// 	// 		id   = 100,
// 	// 		path = Resource_Path("fuck yeah"),
// 	// 		name = "shit",
// 	// 		meta = Rom{10, {1, 1, 0, 2, 3, 1}, s},
// 	// 	}
// 	// 	bytes = resource_struct_to_bytes(desc)

// 	// }
// 	// type := resource_struct_from_bytes(bytes, Resource_Desc(Resource_Meta_Data))

// 	// fmt.print(type)
// }

