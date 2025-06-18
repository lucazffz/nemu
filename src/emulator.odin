package nemu
// @note small note, white space before package declaration make ols flip
// the hell out, yes it took days to realize...

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "utils"


Console :: struct {
	cpu:    CPU,
	ppu:    PPU,
	apu:    APU,
	// 2 KB of internal ram ($0000 - $07FF)
	ram:    []u8,
	// cycles: int,
	// stalls: int,
	mapper: ^Mapper,
}

// For documentation regarding the CPU, please refer to:
// https://www.cpcwiki.eu/index.php/MOS_6505
CPU :: struct {
	x:                 u8,
	y:                 u8,
	acc:               u8,
	status:            bit_set[Processor_Status_Flags], // Defaults to u8 for underlying type
	interrupt:         Hardware_Interrupt,
	// stack is located in page 1 ($0100-$01FF), sp is offset to this base
	sp:                u8,
	pc:                u16,
	cycle_count:       int,
	stall_count:       int,
	instruction_count: int,
	decmial_mode:      bool,
}

PAGE_1_ADDRESS :: 0x0100

PPU :: struct {
}

APU :: struct {
}

Memory_Error :: enum {
	None,
	Invalid_Address,
	Read_Only,
	Out_Of_Memory,
}

// NF - Negative Flag         : 1 when result is negative
// VF - Overflow Flag         : 1 on signed overflow
// BF - Break Flag            : 1 when pushed by inst (BRK/PHP) and 0 when popped by irq (NMI/IRQ)
// DF - Decmial Mode Flag     : 1 when CPU is in Decimal Mode
// IF - Interrupt Disable Flag: when 1, no interrupt will occur (except BRK and NMI)
// ZF - Zero Flag             : 1 when all bits of a result is 0
// CF - Carry Flag            : 1 on unsigned overflow
Processor_Status_Flags :: enum {
	CF, // bit 0
	ZF, // bit 1
	IF, // bit 2
	DF, // bit 3
	// BF, // bit 4 
	// _5, // bit 5
	VF, // bit 6
	NF, // bit 7
}

Instruction_Type :: enum {
	// alu instructions
	BIT  = 0, // Bit Test
	AND  = 1, // Logical AND
	EOR  = 2, // Exclusive OR
	ORA  = 3, // Logical Inclusive OR
	ADC  = 4, // Add with Carry
	SBC  = 5, // Subtract with Carry
	CMP  = 6, // Compare Accumulator
	CPX  = 7, // Compare X Register
	CPY  = 8, // Compare Y Register
	ASL  = 9, // Arithmetic Shift Left
	LSR  = 10, // Logical Shift Right
	ROL  = 11, // Rotate Left
	ROR  = 12, // Rotate Right
	DEC  = 13, // Decrement Memory
	INC  = 14, // Increment Memory
	DEX  = 15, // Decrement X Register
	DEY  = 16, // Decrement Y Register
	INX  = 17, // Increment X Register
	INY  = 18, // Increment Y Register

	// move instrucitons
	LDA  = 19, // Load Accumulator
	LDX  = 20, // Load X Register
	LDY  = 21, // Load Y Register
	STA  = 22, // Store Accumulator
	STX  = 23, // Store X Register
	STY  = 24, // Store Y Register
	TAX  = 25, // Transfer Accumulator to X
	TXA  = 26, // Transfer X to Accumulator
	TAY  = 27, // Transfer Accumulator to Y
	TYA  = 28, // Transfer Y to Accumulator
	TSX  = 29, // Transfer Stack Pointer to X
	TXS  = 30, // Transfer X to Stack Pointer
	PLP  = 31, // Pull Processor Status from Stack
	PLA  = 32, // Pull Accumulator from Stack
	PHP  = 33, // Push Processor Status on Stack
	PHA  = 34, // Push Accumulator on Stack

	// jump and flag instructions
	JMP  = 35, // Jump
	JSR  = 36, // Jump to Subroutine
	RTS  = 37, // Return from Subroutine
	RTI  = 38, // Return from Interrupt
	BRK  = 39, // Force Interrupt
	SEI  = 40, // Set Interrupt Disable
	CLI  = 41, // Clear Interrupt Disable
	SEC  = 42, // Set Carry Flag
	CLC  = 43, // Clear Carry Flag
	SED  = 44, // Set Decimal Mode
	CLD  = 45, // Clear Decimal Mode
	CLV  = 46, // Clear Overflow Flag
	NOP  = 47, // No Operation
	BPL  = 48, // Branch if Plus (Negative Clear)
	BMI  = 49, // Branch if Minus (Negative Set)
	BVC  = 50, // Branch if Overflow Clear
	BVS  = 51, // Branch if Overflow Set
	BCC  = 52, // Branch if Carry Clear
	BCS  = 53, // Branch if Carry Set
	BNE  = 54, // Branch if Not Equal (Zero Clear)
	BEQ  = 55, // Branch if Equal (Zero Set)

	// illegal instrucitons
	DCP  = 56, // DEC + CMP
	ISC  = 57, // INC + SBC
	RLA  = 58, // ROL + AND
	RRA  = 59, // ROR + ADC
	SLO  = 60, // ASL + ORA
	SRE  = 61, // LSR + EOR
	LAX  = 62, // LDA + LDX
	SAX  = 63, // Store A&X
	LAS  = 64, // LAX + TSX
	TAS  = 65, // (Unstable) Store A&X in S
	SHA  = 66, // (Unstable) Store A&X&(HighAddr+1)
	SHX  = 67, // (Unstable) Store X&(HighAddr+1)
	SHY  = 68, // (Unstable) Store Y&(HighAddr+1)
	ANE  = 69, // (Unstable) AND X + AND immediate
	LXA  = 70, // (Unstable) Store immediate in A and X
	ALR  = 71, // AND immediate + LSR
	ARR  = 72, // AND immediate + ROR
	ANC  = 73, // AND immediate, sets C as N
	ANC2 = 74, // Same as ANC
	SBX  = 75, // CMP + DEX
	USBC = 76, // SBC + NOP
	JAM  = 77, // Halt CPU
}


Instruction_Addressing_Mode :: enum {
	Implied             = 0, // Instruction requires no operand from memory
	Accumulator         = 1, // Instruction operates on the accumulator register
	Immediate           = 2, // Operand is the byte immediately after the opcode
	Zeropage            = 3, // Operand is an 8-bit address in the zero page ($00xx)
	Zeropage_X          = 4, // Operand is an 8-bit address in zero page, offset by X
	Zeropage_Y          = 5, // Operand is an 8-bit address in zero page, offset by Y
	Relative            = 6, // Operand is a signed 8-bit offset from the program counter
	Absolute            = 7, // Operand is a full 16-bit memory address
	Absolute_X          = 8, // Operand is a 16-bit address, offset by X
	Absolute_Y          = 9, // Operand is a 16-bit address, offset by Y
	Indirect            = 10, // Operand is a 16-bit address that points to the target address (JMP only)
	Zeropage_Indirect_X = 11, // (Indirect,X) Operand is from an address calculated using a zero-page address and X
	Zeropage_Indirect_Y = 12, // (Indirect),Y Operand is from an address calculated using a zero-page pointer and Y
}

Instruction_Category :: enum {
	Legal,
	Illegal,
	// Unstable,
}

Hardware_Interrupt :: enum {
	None,
	Reset,
	NMI,
	IRQ,
}

Instruction :: struct {
	type:                       Instruction_Type,
	addressing_mode:            Instruction_Addressing_Mode,
	byte_size:                  int,
	cycle_count:                int,
	page_boundary_extra_cycles: int,
	category:                   Instruction_Category,
}

get_instruction_from_opcode :: proc(opcode: u8) -> Instruction {
	return {
		type = Instruction_Type(instruction_type[opcode]),
		addressing_mode = Instruction_Addressing_Mode(instruction_addressing_mode[opcode]),
		byte_size = instruction_byte_size[opcode],
		cycle_count = instruction_cycle_count[opcode],
		page_boundary_extra_cycles = instruction_page_boundary_extra_cycles[opcode],
		category = Instruction_Category(instruction_category[opcode]),
	}
}

/*
Execute a single CPU instruction

If an hardware-interrupt is set, the interurpt will be handled instead.
The interrupt will be cleared (set to Hardware_Interrupt.None) automatically.

**An error will leave the console in an invalid state**

Inputs:
- console: The console to operate on

Returns:
- cycles: The number of cycles the instruction took to execute
- instruction: The executed instruction
- error: Memory error caused by writing/reading to/from an invalid address
*/
@(require_results)
console_cpu_step :: proc(
	console: ^Console,
) -> (
	cycles: int,
	instruction: Instruction,
	error: Memory_Error,
) {
	if console.cpu.stall_count > 0 {
		console.cpu.stall_count -= 1
		return
	}

	operand_addr: u16
	page_crossed: bool
	pc_incremented := false
	start_pc := console.cpu.pc

	// --- Handle interrupt ---

	defer {
		if error == nil {
			// branch, jump and some other instructions will directly set PC
			if !pc_incremented {
				console.cpu.pc = start_pc + u16(instruction.byte_size)
			}

			console.cpu.cycle_count += cycles
			console.cpu.interrupt = .None
		}
	}

	opcode := console_mem_read_from_address(console, start_pc) or_return
	instruction = get_instruction_from_opcode(opcode)
	// @todo handle interrupt hijacking
	handle_interrupts: {
		INTERRUPT_CYCLE_COUNT :: 7
		// the pushed PC is expected to point to the next
		// instruction to be executed
		//
		// interrupt priority from higest to lowest: resest, brk, nmi, irq
		switch console.cpu.interrupt {
		case .Reset:
			lo := console_mem_read_from_address(console, 0xfffc) or_return
			hi := console_mem_read_from_address(console, 0xfffd) or_return
			console.cpu.pc = (u16(hi) << 8 | u16(lo))
			cycles += INTERRUPT_CYCLE_COUNT
			pc_incremented = true
			return
		case .NMI:
			if instruction.type == .BRK do break handle_interrupts
			pc_to_push := start_pc
			cpu_stack_push(console, u8(pc_to_push >> 8)) or_return
			cpu_stack_push(console, u8(pc_to_push)) or_return
			status_byte := status_flags_to_byte(console.cpu.status, false)
			cpu_stack_push(console, status_byte) or_return
			lo := console_mem_read_from_address(console, 0xfffa) or_return
			hi := console_mem_read_from_address(console, 0xfffb) or_return
			console.cpu.status += {.IF}
			console.cpu.pc = (u16(hi) << 8) | u16(lo)
			cycles += INTERRUPT_CYCLE_COUNT
			pc_incremented = true
			return
		case .IRQ:
			if instruction.type == .BRK do break handle_interrupts
			if .IF in console.cpu.status do break handle_interrupts
			// same as for NMI onli different interrupt vector
			pc_to_push := start_pc
			cpu_stack_push(console, u8(pc_to_push >> 8)) or_return
			cpu_stack_push(console, u8(pc_to_push)) or_return
			status_byte := status_flags_to_byte(console.cpu.status, false)
			cpu_stack_push(console, status_byte) or_return
			lo := console_mem_read_from_address(console, 0xfffe) or_return
			hi := console_mem_read_from_address(console, 0xffff) or_return
			console.cpu.status += {.IF}
			console.cpu.pc = (u16(hi) << 8) | u16(lo)
			cycles += INTERRUPT_CYCLE_COUNT
			pc_incremented = true
			return
		case .None:
		}
	}

	// --- Execute instruction ---

	defer {
		if error == nil {
			// log.infof(
			// 	"[%03d] opcode %02x: %s",
			// 	console.cpu.instruction_count,
			// 	opcode,
			// 	instruction_to_string(instruction),
			// )

			cycles += instruction.cycle_count
			console.cpu.instruction_count += 1
		}
	}

	execute_instruction: {

		// pre-calculate address for modes that need it
		#partial switch instruction.addressing_mode {
		case .Accumulator, .Implied, .Relative:
		// no address to fetch
		case:
			operand_addr, page_crossed = get_operand_address(
				console,
				instruction.addressing_mode,
			) or_return
			if page_crossed {
				cycles += instruction.page_boundary_extra_cycles
			}
		}

		// if instruction.addressing_mode == .Zeropage_X {
		// 	fmt.printfln("op addr: %02x", operand_addr)

		// }


		#partial switch instruction.type {
		// === Arithmetic and Logical ===
		case .ADC, .SBC:
			// ADC and SBC are identical instruction with the only difference
			// that SBC will bit invert the operand
			val := console_mem_read_from_address(console, operand_addr) or_return
			if instruction.type == .SBC do val = ~val // invert operand if SBC
			a := console.cpu.acc
			c := .CF in console.cpu.status
			console.cpu.status -= {.CF, .VF}
			if u16(a) + u16(val) + u16(c) > 0xff do console.cpu.status += {.CF}
			result := a + val + u8(c)
			// @note the signed overflow could be calculated more gracefully
			// (a & 0x80) == (b & 0x80): are sign bits of a and b are the same 
			// (result & 0x80) != (a & 0x80): is sign bit of the result is
			// different from the sign bit of the original numbers
			signed_overflow := (a & 0x80) == (val & 0x80) && (result & 0x80) != (a & 0x80)
			if signed_overflow do console.cpu.status += {.VF}
			console.cpu.acc = result
			cpu_set_zn(console, console.cpu.acc)
		case .AND:
			val := console_mem_read_from_address(console, operand_addr) or_return
			console.cpu.acc &= val
			cpu_set_zn(console, console.cpu.acc)
		case .ORA:
			val := console_mem_read_from_address(console, operand_addr) or_return
			console.cpu.acc |= val
			cpu_set_zn(console, console.cpu.acc)
		case .EOR:
			val := console_mem_read_from_address(console, operand_addr) or_return
			console.cpu.acc ~= val
			cpu_set_zn(console, console.cpu.acc)
		// === Compare ===
		case .CMP:
			val := console_mem_read_from_address(console, operand_addr) or_return
			temp := console.cpu.acc - val
			console.cpu.status -= {.CF}
			if console.cpu.acc >= val do console.cpu.status += {.CF}
			cpu_set_zn(console, temp)
		case .CPX:
			val := console_mem_read_from_address(console, operand_addr) or_return
			temp := console.cpu.x - val
			console.cpu.status -= {.CF}
			if console.cpu.x >= val do console.cpu.status += {.CF}
			cpu_set_zn(console, temp)
		case .CPY:
			val := console_mem_read_from_address(console, operand_addr) or_return
			temp := console.cpu.y - val
			console.cpu.status -= {.CF}
			if console.cpu.y >= val do console.cpu.status += {.CF}
			cpu_set_zn(console, temp)
		// === Bit Test ===
		case .BIT:
			val := console_mem_read_from_address(console, operand_addr) or_return
			console.cpu.status -= {.ZF, .NF, .VF}
			if console.cpu.acc & val == 0 do console.cpu.status += {.ZF}
			if 0x80 & val != 0 do console.cpu.status += {.NF}
			if 0x40 & val != 0 do console.cpu.status += {.VF}
		// === Load/Store ===
		case .LDA:
			console.cpu.acc = console_mem_read_from_address(console, operand_addr) or_return
			cpu_set_zn(console, console.cpu.acc)
		case .LDX:
			console.cpu.x = console_mem_read_from_address(console, operand_addr) or_return
			cpu_set_zn(console, console.cpu.x)
		case .LDY:
			console.cpu.y = console_mem_read_from_address(console, operand_addr) or_return
			cpu_set_zn(console, console.cpu.y)
		case .STA:
			console_mem_write_to_address(console, operand_addr, console.cpu.acc) or_return
		case .STX:
			console_mem_write_to_address(console, operand_addr, console.cpu.x) or_return
		case .STY:
			console_mem_write_to_address(console, operand_addr, console.cpu.y) or_return
		// === Increment/Decrement ===
		case .INC:
			val := console_mem_read_from_address(console, operand_addr) or_return
			val += 1
			console_mem_write_to_address(console, operand_addr, val) or_return
			cpu_set_zn(console, val)
		case .DEC:
			val := console_mem_read_from_address(console, operand_addr) or_return
			val -= 1
			console_mem_write_to_address(console, operand_addr, val) or_return
			cpu_set_zn(console, val)
		case .INX:
			console.cpu.x += 1
			cpu_set_zn(console, console.cpu.x)
		case .INY:
			console.cpu.y += 1
			cpu_set_zn(console, console.cpu.y)
		case .DEX:
			console.cpu.x -= 1
			cpu_set_zn(console, console.cpu.x)
		case .DEY:
			console.cpu.y -= 1
			cpu_set_zn(console, console.cpu.y)
		// === Shifts and Rotates ===
		case .ASL:
			console.cpu.status -= {.CF}
			if instruction.addressing_mode == .Accumulator {
				if console.cpu.acc & 0x80 != 0 do console.cpu.status += {.CF}
				console.cpu.acc <<= 1
				cpu_set_zn(console, console.cpu.acc)
			} else {
				val := console_mem_read_from_address(console, operand_addr) or_return
				if val & 0x80 != 0 do console.cpu.status += {.CF}
				val <<= 1
				cpu_set_zn(console, val)
				console_mem_write_to_address(console, operand_addr, val) or_return
			}
		case .LSR:
			console.cpu.status -= {.CF}
			if instruction.addressing_mode == .Accumulator {
				if console.cpu.acc & 0x01 != 0 do console.cpu.status += {.CF}
				console.cpu.acc >>= 1
				cpu_set_zn(console, console.cpu.acc)
			} else {
				val := console_mem_read_from_address(console, operand_addr) or_return
				if val & 0x01 != 0 do console.cpu.status += {.CF}
				val >>= 1
				console_mem_write_to_address(console, operand_addr, val) or_return
				cpu_set_zn(console, val)
			}
		case .ROL:
			c := u8(.CF in console.cpu.status)
			console.cpu.status -= {.CF}
			if instruction.addressing_mode == .Accumulator {
				if console.cpu.acc & 0x80 != 0 do console.cpu.status += {.CF}
				console.cpu.acc = (console.cpu.acc << 1) | c
				cpu_set_zn(console, console.cpu.acc)
			} else {
				val := console_mem_read_from_address(console, operand_addr) or_return
				if val & 0x80 != 0 do console.cpu.status += {.CF}
				val = (val << 1) | c
				console_mem_write_to_address(console, operand_addr, val) or_return
				cpu_set_zn(console, val)
			}
		case .ROR:
			c := u8(.CF in console.cpu.status) << 7
			console.cpu.status -= {.CF}
			if instruction.addressing_mode == .Accumulator {
				if console.cpu.acc & 0x01 != 0 do console.cpu.status += {.CF}
				console.cpu.acc = (console.cpu.acc >> 1) | c
				cpu_set_zn(console, console.cpu.acc)
			} else {
				val := console_mem_read_from_address(console, operand_addr) or_return
				if val & 0x01 != 0 do console.cpu.status += {.CF}
				val = (val >> 1) | c
				console_mem_write_to_address(console, operand_addr, val) or_return
				cpu_set_zn(console, val)
			}
		// === Program Flow Control ===
		case .JMP:
			console.cpu.pc = operand_addr
			pc_incremented = true
		case .JSR:
			pc_to_push := start_pc + 2 // address of last byte of JSR instruction
			cpu_stack_push(console, u8(pc_to_push >> 8)) or_return
			cpu_stack_push(console, u8(pc_to_push)) or_return
			console.cpu.pc = operand_addr
			pc_incremented = true
		case .RTS:
			lo := cpu_stack_pull(console) or_return
			hi := cpu_stack_pull(console) or_return
			// add 1 since PC points to the last byte of the JSR instruction
			console.cpu.pc = ((u16(hi) << 8) | u16(lo)) + 1
			pc_incremented = true
		case .RTI:
			status_byte := cpu_stack_pull(console) or_return
			lo := cpu_stack_pull(console) or_return
			hi := cpu_stack_pull(console) or_return
			console.cpu.status = status_flags_from_byte(status_byte)
			// Dont add 1 since PC is expected to point to the first byte
			// of the next instruction when interrupt is triggered.
			// Different from subroutine jump (JSR) where PC is the last byte of
			// JSR.
			console.cpu.pc = (u16(hi) << 8) | u16(lo)
			pc_incremented = true
		// === Branches ===
		case .BCC:
			branch(console, .CF not_in console.cpu.status) or_return;pc_incremented = true
		case .BCS:
			branch(console, .CF in console.cpu.status) or_return;pc_incremented = true
		case .BEQ:
			branch(console, .ZF in console.cpu.status) or_return;pc_incremented = true
		case .BNE:
			branch(console, .ZF not_in console.cpu.status) or_return;pc_incremented = true
		case .BMI:
			branch(console, .NF in console.cpu.status) or_return;pc_incremented = true
		case .BPL:
			branch(console, .NF not_in console.cpu.status) or_return;pc_incremented = true
		case .BVC:
			branch(console, .VF not_in console.cpu.status) or_return;pc_incremented = true
		case .BVS:
			branch(console, .VF in console.cpu.status) or_return;pc_incremented = true
		// === Register Transfers ===
		case .TAX:
			console.cpu.x = console.cpu.acc;cpu_set_zn(console, console.cpu.x)
		case .TAY:
			console.cpu.y = console.cpu.acc;cpu_set_zn(console, console.cpu.y)
		case .TXA:
			console.cpu.acc = console.cpu.x;cpu_set_zn(console, console.cpu.acc)
		case .TYA:
			console.cpu.acc = console.cpu.y;cpu_set_zn(console, console.cpu.acc)
		case .TSX:
			console.cpu.x = console.cpu.sp;cpu_set_zn(console, console.cpu.x)
		case .TXS:
			console.cpu.sp = console.cpu.x
		// === Stack Operations ===
		case .PHA:
			cpu_stack_push(console, console.cpu.acc) or_return
		case .PHP:
			// when pushed, BF and _5 are set
			status_byte := status_flags_to_byte(console.cpu.status)
			cpu_stack_push(console, status_byte) or_return
		case .PLA:
			console.cpu.acc = cpu_stack_pull(console) or_return
			cpu_set_zn(console, console.cpu.acc)
		case .PLP:
			// when pulled, BF and _5 are set
			status_byte := cpu_stack_pull(console) or_return
			console.cpu.status = status_flags_from_byte(status_byte)
		// === Flag Set/Clear ===
		case .CLC:
			console.cpu.status -= {.CF}
		case .CLD:
			console.cpu.status -= {.DF}
		case .CLI:
			console.cpu.status -= {.IF}
		case .CLV:
			console.cpu.status -= {.VF}
		case .SEC:
			console.cpu.status += {.CF}
		case .SED:
			console.cpu.status += {.DF}
		case .SEI:
			console.cpu.status += {.IF}

		// === System and NOP ===
		case .BRK:
			// BRK is a software-triggered interrupt, and since both BRK and
			// hardware-triggered interrupts (IRQ) reuse the same microcode, BRK
			// is followed by an ignored padding byte to match IRQ. This is why
			// we add 2 to PC instead of 1.
			pc_to_push := start_pc + 2
			cpu_stack_push(console, u8(pc_to_push >> 8)) or_return
			cpu_stack_push(console, u8(pc_to_push)) or_return
			status_byte := status_flags_to_byte(console.cpu.status)
			cpu_stack_push(console, status_byte) or_return
			lo := console_mem_read_from_address(console, 0xfffe) or_return
			hi := console_mem_read_from_address(console, 0xffff) or_return
			console.cpu.status += {.IF}
			console.cpu.pc = (u16(hi) << 8) | u16(lo)
			pc_incremented = true
		case .NOP:
		// does nothing

		// === Illegal Opcodes ===
		// For now, most illegal opcodes will act as NOPs.
		// A full implementation requires emulating their specific, often quirky, behavior.
		case .LAX:
		// val := console_mem_read_from_address(console, addr)
		// console.cpu.acc = val
		// console.cpu.x = val
		// cpu_set_zn(&console.cpu, val)
		case .SAX:
		// val := console.cpu.acc & console.cpu.x
		// console_mem_write_to_address(console, addr, val)
		case .DCP:
		// val := console_mem_read_from_address(console, addr) - 1
		// console_mem_write_to_address(console, addr, val)
		// temp := console.cpu.acc - val
		// console.cpu.status[.CF] = console.cpu.acc >= val
		// cpu_set_zn(&console.cpu, temp)
		case .ISC:
		// val := console_mem_read_from_address(console, addr) + 1
		// console_mem_write_to_address(console, addr, val)
		// a := console.cpu.acc
		// c: u16 = 0; if console.cpu.status[.CF] {c=1}
		// temp: u16 = u16(a) - u16(val) - (1-c)
		// console.cpu.status[.CF] = temp < 0x100
		// console.cpu.status[.VF] = ((u16(a) ^ temp) & (u16(^val) ^ temp) & 0x80) != 0
		// console.cpu.acc = u8(temp)
		// cpu_set_zn(&console.cpu, console.cpu.acc)
		case .SLO:
		// val := console_mem_read_from_address(console, addr)
		// console.cpu.status[.CF] = (val & 0x80) != 0
		// val <<= 1
		// console_mem_write_to_address(console, addr, val)
		// console.cpu.acc |= val
		// cpu_set_zn(&console.cpu, console.cpu.acc)
		case .RLA:
		// c: u8 = 0; if console.cpu.status[.CF] {c=1}
		// val := console_mem_read_from_address(console, addr)
		// console.cpu.status[.CF] = (val & 0x80) != 0
		// val = (val << 1) | c
		// console_mem_write_to_address(console, addr, val)
		// console.cpu.acc &= val
		// cpu_set_zn(&console.cpu, console.cpu.acc)
		case .SRE:
		// val := console_mem_read_from_address(console, addr)
		// console.cpu.status[.CF] = (val & 0x01) != 0
		// val >>= 1
		// console_mem_write_to_address(console, addr, val)
		// console.cpu.acc ~= val
		// cpu_set_zn(&console.cpu, console.cpu.acc)
		case .RRA:
		// c: u8 = 0; if console.cpu.status[.CF] {c=128}
		// val := console_mem_read_from_address(console, addr)
		// carry_out := (val & 0x01) != 0
		// val = (val >> 1) | c
		// console_mem_write_to_address(console, addr, val)

		// a := console.cpu.acc
		// c_in: u16 = 0; if carry_out {c_in=1}
		// temp: u16 = u16(a) + u16(val) + c_in
		// console.cpu.status[.CF] = temp > 0xFF
		// console.cpu.status[.VF] = ((u16(a) ^ temp) & (u16(val) ^ temp) & 0x80) != 0
		// console.cpu.acc = u8(temp)
		// cpu_set_zn(&console.cpu, console.cpu.acc)

		case .JAM:
		// // Halt execution, effectively. We can do this by setting PC to itself.
		// console.cpu.pc = start_pc
		// pc_incremented = true

		case:
		// Default case for unhandled (mostly illegal) instructions
		// They will act like NOPs and just increment the PC.
		}


		return
	}


	@(require_results)
	cpu_stack_push :: proc(console: ^Console, data: u8) -> Memory_Error {
		err := console_mem_write_to_address(console, PAGE_1_ADDRESS + u16(console.cpu.sp), data)
		console.cpu.sp -= 1
		return err
	}

	@(require_results)
	cpu_stack_pull :: proc(console: ^Console) -> (u8, Memory_Error) {
		console.cpu.sp += 1
		data, err := console_mem_read_from_address(console, PAGE_1_ADDRESS + u16(console.cpu.sp))
		return data, err
	}

	cpu_set_zn :: proc(console: ^Console, data: u8) {
		console.cpu.status -= {.ZF, .NF}
		if data == 0 do console.cpu.status += {.ZF}
		if (data & 0x80) != 0 do console.cpu.status += {.NF}
	}

	// branch handles the logic for all conditional branch instructions
	@(require_results)
	branch :: proc(console: ^Console, condition: bool) -> Memory_Error {
		if condition {
			console.cpu.cycle_count += 1
			rel_addr := console_mem_read_from_address(console, console.cpu.pc + 1) or_return
			// + 2 to point to next instruction
			jump_addr := u16(i16(console.cpu.pc) + 2 + i16(i8(rel_addr)))

			if is_page_crossed(console.cpu.pc + 2, jump_addr) {
				console.cpu.cycle_count += 1 // page cross adds another cycle
			}
			console.cpu.pc = jump_addr
		} else {
			console.cpu.pc += 2
		}

		return .None
	}


}

is_page_crossed :: proc(address1, address2: u16) -> bool {
	return address1 & 0xff00 != address2 & 0xff00
}

// calculate the effective address for an instruction and checks for page crossing
// assumes that pc is pointing to opcode
@(require_results)
get_operand_address :: proc(
	console: ^Console,
	mode: Instruction_Addressing_Mode,
) -> (
	return_addr: u16,
	page_crossed: bool,
	error: Memory_Error,
) {
	// system is little endian so low byte is stored first in memory

	cpu := &console.cpu
	switch mode {
	case .Immediate:
		return_addr = cpu.pc + 1
	case .Zeropage:
		zp_addr := console_mem_read_from_address(console, cpu.pc + 1) or_return
		return_addr = u16(zp_addr)
	case .Zeropage_X:
		// overflow is ignored so 0x00ff (address) + 1 (X or Y) will cause
		// wraparound ensuring that the address is always contained within
		// the zeropage
		base_addr := console_mem_read_from_address(console, cpu.pc + 1) or_return
		// fmt.printfln("zero page base addr: %02x", base_addr)
		// fmt.printfln("zero page addr: %02x", u16(base_addr + cpu.x))
		return_addr = u16(base_addr + cpu.x) // emulate overflow properly
	case .Zeropage_Y:
		base_addr := console_mem_read_from_address(console, cpu.pc + 1) or_return
		return_addr = u16(base_addr + cpu.y)
	case .Absolute:
		lo := console_mem_read_from_address(console, cpu.pc + 1) or_return
		hi := console_mem_read_from_address(console, cpu.pc + 2) or_return
		return_addr = (u16(hi) << 8) | u16(lo)
	case .Absolute_X:
		lo := console_mem_read_from_address(console, cpu.pc + 1) or_return
		hi := console_mem_read_from_address(console, cpu.pc + 2) or_return
		base_addr := (u16(hi) << 8) | u16(lo)
		return_addr = base_addr + u16(cpu.x)
		page_crossed = is_page_crossed(base_addr, return_addr)
	case .Absolute_Y:
		lo := console_mem_read_from_address(console, cpu.pc + 1) or_return
		hi := console_mem_read_from_address(console, cpu.pc + 2) or_return
		base_addr := (u16(hi) << 8) | u16(lo)
		return_addr = base_addr + u16(cpu.y)
		page_crossed = is_page_crossed(base_addr, return_addr)
	case .Indirect:
		// the infamous JMP indirect bug: if the low byte of the address vector
		// is 0xFF, due to incorrect wraparound the high byte is fetched
		// from the start of the same page, not the next one.
		lo_ptr := console_mem_read_from_address(console, cpu.pc + 1) or_return
		hi_ptr := console_mem_read_from_address(console, cpu.pc + 2) or_return
		ptr := (u16(hi_ptr) << 8) | u16(lo_ptr)
		lo := console_mem_read_from_address(console, ptr) or_return
		hi_ptr_buggy := (ptr & 0xff00) | u16(u8(ptr + 1)) // emulate overflow
		hi := console_mem_read_from_address(console, hi_ptr_buggy) or_return
		return_addr = (u16(hi) << 8) | u16(lo)
	case .Zeropage_Indirect_X:
		zp_base := console_mem_read_from_address(console, cpu.pc + 1) or_return
		ptr := zp_base + cpu.x
		lo := console_mem_read_from_address(console, u16(ptr)) or_return
		hi := console_mem_read_from_address(console, u16(ptr + 1)) or_return
		return_addr = (u16(hi) << 8) | u16(lo)
	case .Zeropage_Indirect_Y:
		// zp_ptr, lo, hi: u8
		// error: Memory_Error
		zp_ptr := console_mem_read_from_address(console, cpu.pc + 1) or_return
		lo := console_mem_read_from_address(console, u16(zp_ptr)) or_return
		hi := console_mem_read_from_address(console, u16(zp_ptr + 1)) or_return
		base_addr := (u16(hi) << 8) | u16(lo)
		return_addr = base_addr + u16(cpu.y)
		page_crossed = is_page_crossed(base_addr, return_addr)
	case .Implied, .Accumulator, .Relative:
	// Implied, Accumulator, and Relative modes don't use this function.
	}

	return
}

// sets _5 and BF to 1
status_flags_to_byte :: proc(flags: bit_set[Processor_Status_Flags], set_BF := true) -> u8 {
	return(
		(u8(.NF in flags) << 7) |
		(u8(.VF in flags) << 6) |
		(u8(1 << 5)) |
		(u8(set_BF) << 4) |
		(u8(.DF in flags) << 3) |
		(u8(.IF in flags) << 2) |
		(u8(.ZF in flags) << 1) |
		(u8(.CF in flags) << 0) \
	)
}

status_flags_from_byte :: proc(byte: u8) -> (flags: bit_set[Processor_Status_Flags]) {
	// When pulled (PLP, RTI), bit 5 is always forced to 1, and bit 4 (BF) is forced to 0.
	// Other flags are set directly from the byte.

	// Initialize flags with ._5 set. Bit 5 is always 1 on PLP/RTI.
	// flags = {._5}


	// Set other flags based on the corresponding bits in the byte.
	// Bit 4 (BF) is intentionally ignored from the 'byte' value, as it's forced to 0 by hardware on PLP/RTI.
	if (byte & (1 << 7)) != 0 do flags += {.NF}
	if (byte & (1 << 6)) != 0 do flags += {.VF}
	// Bit 5 is already handled by the `flags = {._5}` initialization.
	// Bit 4 (BF) is not set from the byte, effectively forcing it to 0.
	if (byte & (1 << 3)) != 0 do flags += {.DF}
	if (byte & (1 << 2)) != 0 do flags += {.IF}
	if (byte & (1 << 1)) != 0 do flags += {.ZF}
	if (byte & (1 << 0)) != 0 do flags += {.CF}
	return
}

// allocate memory for console
// will not initialize default values, use console_init
console_make :: proc(
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	console: ^Console,
	err: runtime.Allocator_Error,
) #optional_allocator_error {
	// dont check error, know that interval is closed
	ram_size, _ := utils.interval_size(CPU_INTERNAL_RAM_INTERVAL)
	ram := make_slice([]u8, ram_size, allocator, loc) or_return
	console = new(Console, allocator, loc) or_return
	console.ram = ram

	return
}

// initialize default console values on startup
// will not allocate memory, use console_make
console_init :: proc(console: ^Console) {
	console.cpu = {
		x      = 0,
		y      = 0,
		acc    = 0,
		sp     = 0xfd,
		pc     = 0xc000,
		status = {.IF},
	}
}

@(require_results)
console_cpu_reset :: proc(console: ^Console, reset_vector: u16) -> Memory_Error {
	lo := u8(reset_vector)
	hi := u8(reset_vector >> 8)
	console_mem_write_to_address(console, 0xfffc, lo) or_return
	console_mem_write_to_address(console, 0xfffd, hi) or_return

	console.cpu.interrupt = .Reset
	_, _, error := console_cpu_step(console)
	return error
}

// free memory allocated to console
console_delete :: proc(
	console: ^Console,
	allocator := context.allocator,
	loc := #caller_location,
) -> runtime.Allocator_Error {
	delete_slice(console.ram, allocator, loc) or_return
	free(console, allocator, loc) or_return
	return .None
}


@(private = "file")
CPU_INTERNAL_RAM_INTERVAL :: utils.Interval(u16){0x0000, 0x1FFF, .Closed} // 2KB ram mirrored 4 times


@(require_results)
console_mem_write_to_address :: proc(console: ^Console, address: u16, data: u8) -> Memory_Error {
	switch address {
	case 0x0000 ..< 0x2000:
		// cpu internal RAM, 2 KB
		// RAM is mirrored every 2 KB from $0800-$1fff
		address := address % 0x0800
		console.ram[address] = data
	case 0x2000 ..< 4000:
		// PPU I/O registers
		// registers are mirrored every 8 bytes from $2008-$3fff
		address := address % 8
	case 0x4000 ..< 4020:
	// APU and I/O registers
	case 4020 ..< 6000:
		// expansion ROM
		assert(false, "expansion ROM not supported")
	case 6000 ..< 0xffff:
		// mapper
		console.mapper->write_to_address(address, data) or_return
	case:
		return .Invalid_Address
	}

	return .None
}


@(require_results)
console_mem_read_from_address :: proc(
	console: ^Console,
	address: u16,
) -> (
	data: u8,
	error: Memory_Error,
) {
	switch address {
	case 0x0000 ..< 0x2000:
		// cpu internal RAM, 2 KB
		// RAM is mirrored every 2 KB from $0800-$1fff
		address := address % 0x0800
		data = console.ram[address]
	// fmt.printf("%02x ", address)
	// fmt.print(data)
	case 0x2000 ..< 4000:
		// PPU I/O registers
		// registers are mirrored every 8 bytes from $2008-$3fff
		address := address % 8
	case 0x4000 ..< 4020:
	// APU and I/O registers
	case 4020 ..< 6000:
		// expansion ROM
		assert(false, "expansion ROM not supported")
	case 6000 ..< 0xffff:
		// mapper
		data = console.mapper->read_from_address(address) or_return
	case:
		error = .Invalid_Address
	}

	return
}


instruction_to_string :: proc(instruction: Instruction) -> string {
	i := instruction
	return fmt.tprintf(
		"(%s) B:%d C:%d PB:%d %7s %s",
		i.type,
		i.byte_size,
		i.cycle_count,
		i.page_boundary_extra_cycles,
		i.category,
		i.addressing_mode,
	)
}

