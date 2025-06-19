package nemu

import "base:runtime"
import "core:fmt"
import "core:log"

Error_Type :: union #shared_nil {
	Memory_Error,
	Instruction_Error,
}


Error :: struct {
	type: Error_Type,
	msg:  string,
	loc:  runtime.Source_Code_Location,
}

Instruction_Error :: enum {
	Test,
}

Memory_Error :: enum {
	Invalid_Address,
	Read_Only,
	Out_Of_Memory,
}


error :: proc(type: Error_Type, msg: string = "", loc := #caller_location) -> Error {
	return {type, msg, loc}
}

errorf :: proc(
	type: Error_Type,
	format: string,
	args: ..any,
	newline := false,
	loc := #caller_location,
) -> Error {
	msg := fmt.tprintf(format, ..args, newline = newline)
	return {type, msg, loc}
}

error_to_string :: proc(err: Error) -> string {
	msg := err.msg
	if msg == "" {
		switch err.type {
		case .Invalid_Address:
		case .Read_Only:
		case .Out_Of_Memory:
		case .Test:
		case:
			msg = "unexpected problem occurred"
		}

	}

	return fmt.tprint("ERROR: %s, %v", msg, err.type)
}

error_log :: proc(err: Error, logger := context.logger) {
	msg := error_to_string(err)
	log.error(msg, location = err.loc)
}

