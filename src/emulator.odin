package nemu

import "base:runtime"

Console :: struct {
	cpu: CPU,
	ppu: PPU,
	apu: APU,
}

// NF - Negative Flag          : 1 when result is negative
// VF - Overflow Flag          : 1 on signed overflow
// BF - Break Flag             : 1 when pushed by inst (BRK/PHP) and 0 when popped by irq (NMI/IRQ)
// DF - Decmial Mode Flag      : 1 when CPU is in Decimal Mode
// IF - Interrupt Disable Flag : when 1, no interrupt will occur (except BRK and NMI)
// ZF - Zero Flag              : 1 when all bits of a result is 0
// CF - Carry Flag             : 1 on unsigned overflow
//
// Notes:
// - The BF bit does not actually exist inside the 6502.
//   The BF bit only exists in the status flag byte pushed to the stack.
//   When the flags are restored (via PLP or RTI), the BF bit is discarded. 
// - PHP (Push Processor Status) and PLP (Pull Processor Status) can be used to set or retrieve P directly via the stack. 
// - Interrupts (BRK / NMI / IRQ) implicitly push P to the stack.
//   Interrupts returning with RTI will implicitly pull P from the stack. 
// - The effect of toggling the IF flag is delayed by 1 instruction when caused by SEI, CLI, or PLP.
Processor_Status_Flags :: enum {
	NF,
	VF,
	BF,
	DF,
	IF,
	ZF,
	CF,
}

// For documentation regarding the CPU, please refer to:
// https://www.cpcwiki.eu/index.php/MOS_6505
CPU :: struct {
	x:      u8,
	y:      u8,
	acc:    u8,
	status: bit_set[Processor_Status_Flags;u16],
	// stack is located in page 1 ($0100-$01FF), sp is offset to this base
	sp:     u8,
	pc:     u16,
}

PPU :: struct {
}

APU :: struct {
}

MEM :: struct {
}

// allocate memory for console
// will not initialize default values, use console_init
console_make :: proc(
	allocator: runtime.Allocator = context.allocator,
	loc := #caller_location,
) -> (
	Console,
	runtime.Allocator_Error,
) {


	return {}, .None
}

// initialize default console values
// will not allocate memory, use console_make
console_init :: proc(console: ^Console) {

}

// free memory allocated to console
console_delete :: proc(console: ^Console) {

}


mem_write_to_address :: proc(mem: ^MEM, address: u16, data: u8) -> bool {

	return true
}


mem_read_from_address :: proc(mem: ^MEM, address: u16) -> u8 {

	return 0
}

