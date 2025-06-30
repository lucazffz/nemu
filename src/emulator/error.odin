package emulator

import "base:runtime"
import "core:fmt"
import "core:log"

Error_Type :: union #shared_nil {
	Memory_Error,
	iNES_Error,
	PPU_Error,
	CPU_Error,
}

Error_Severity :: enum {
	Warning, // could recover, but may be an issue
	Error, // may or may not be recoverable (context dependent), should discard return value
	Fatal, // could not recover, should halt execution
}


Error :: struct {
	type:     Error_Type,
	severity: Error_Severity,
	msg:      string,
	loc:      runtime.Source_Code_Location,
}

CPU_Error :: enum {
	Operand_Error,
	Branch_Error,
	Stack_Error,
	Opcode_Error,
	Reset_Error,
}

PPU_Error :: enum {
	Nametable_Read_Error,
	Pattern_Table_Read_Error,
	Palette_Read_Error,
}

Memory_Error :: enum {
	Invalid_Address,
	Write_Only,
	Read_Only,
	// Out_Of_Memory,
	// Unused_Memory,
	Unallocated_Memory,
}

iNES_Error :: enum {
	Mapper_Number_Not_Supported,
	CPU_PPU_Timing_Mode_Not_Supported,
	Console_System_Not_Supported,
	TV_System_Not_Supported,
	Invalid_PRG_RAM_Size,
	Invalid_PRG_ROM_Size,
	Invalid_CHR_ROM_Size,
	CHR_RAM_Not_Supported,
	PRG_NVRAM_Not_Supported,
	CHR_NVRAM_Not_Supported,
}


@(require_results)
error :: proc(
	type: Error_Type,
	msg: string = "",
	severity: Error_Severity = .Error,
	loc := #caller_location,
) -> Error {
	return {type, severity, msg, loc}
}

@(require_results)
errorf :: proc(
	type: Error_Type,
	format: string,
	args: ..any,
	severity: Error_Severity = .Error,
	newline := false,
	loc := #caller_location,
) -> Error {
	msg := fmt.tprintf(format, ..args, newline = newline)
	return {type, severity, msg, loc}
}

@(require_results)
error_to_string :: proc(err: Error, prefix := "ERROR: ") -> string {
	msg := err.msg
	if msg == "" {
		switch err.type {
		case .Invalid_Address:
		case .Read_Only:
		// case .Out_Of_Memory:
		case:
			msg = "unexpected problem occurred"
		}

	}

	return fmt.tprintf("%s%s [%v]", prefix, msg, err.type)
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

