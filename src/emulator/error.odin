package emulator

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


@(require_results)
error :: proc(type: Error_Type, msg: string = "", loc := #caller_location) -> Error {
	return {type, msg, loc}
}

@(require_results)
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

@(require_results)
error_to_string :: proc(err: Error, prefix := "ERROR: ") -> string {
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

	return fmt.tprintf("%s%s, %v", prefix, msg, err.type)
}

error_log :: proc(err: Error, level := log.Level.Error, logger := context.logger) {
	prefix: string
	switch level {
	case .Debug:
		prefix = "DEBUG: "
	case .Info:
		prefix = "INFO: "
	case .Warning:
		prefix = "WARNING: "
	case .Error:
		prefix = "ERROR: "
	case .Fatal:
		prefix = "FATAL: "
	}
	msg := error_to_string(err, prefix)
	log.log(level, msg, location = err.loc)
}

