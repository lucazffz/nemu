package emulator

import "base:runtime"
import "core:fmt"
import "core:log"

Error_Type :: enum {
	Memory_Error,
	iNES_Error,
	PPU_Error,
	CPU_Error,
	IO_Error,
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
errorfln :: proc(
	type: Error_Type,
	format: string,
	args: ..any,
	severity: Error_Severity = .Error,
	loc := #caller_location,
) -> Error {
	msg := fmt.tprintf(format, ..args, newline = true)
	return {type, severity, msg, loc}
}

@(require_results)
error_to_string :: proc(err: Error, prefix := "ERROR: ") -> string {
	msg := err.msg
	if msg == "" do msg = "unexpected problem occured"
	return fmt.tprintf("%s%s [%v]", prefix, msg, err.type)
}

error_log :: proc(err: Error, level: Maybe(log.Level) = nil) {
	prefix: string
	log_level: log.Level

	// set log level to level if present, otherwise default to match the
	// error severity
	if level, ok := level.?; ok {
		log_level = level
	} else {
		switch err.severity {
		case .Warning:
			log_level = .Warning
		case .Error:
			log_level = .Error
		case .Fatal:
			log_level = .Fatal
		}
	}

	// set message prefix based on log level
	switch log_level {
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
	log.log(log_level, msg, location = err.loc)
}

