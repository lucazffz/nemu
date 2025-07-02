package emulator
// @note small note, white space before package declaration make ols flip
// the hell out, yes it took days to realize...

import "../utils"
import "base:runtime"
import "core:fmt"
import "core:strings"

// For documentation regarding the CPU, please refer to:
// https://www.cpcwiki.eu/index.php/MOS_6505
CPU :: struct {
	x:                   u8,
	y:                   u8,
	acc:                 u8,
	status:              bit_set[Processor_Status_Flags], // Defaults to u8 for underlying type
	interrupt:           enum {
		None,
		Reset,
		NMI,
		IRQ,
	},
	// stack is located in page 1 ($0100-$01FF), sp is offset to this base
	sp:                  u8,
	pc:                  u16,
	cycle_count:         int,
	stall_count:         int,
	instruction_count:   int,
	decmial_mode:        bool,
	// will be nil if an interrupt is being handled
	current_instruction: Maybe(Instruction),
	dma_page:            u8,
	dma_addr:            u8,
	dma_data:            u8,
	dma_transfer:        bool,
	dma_dummy:           bool,
}

PAGE_1_BASE_ADDRESS :: 0x0100

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
	Ilegal,
}

Instruction :: struct {
	type:                       Instruction_Type,
	addressing_mode:            Instruction_Addressing_Mode,
	byte_size:                  int,
	cycle_count:                int,
	page_boundary_extra_cycles: int,
	category:                   Instruction_Category,
}


@(require_results)
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
Executes a single CPU cycle

If an hardware-interrupt is set, the interurpt will be handled instead.
The interrupt will be cleared (set to Hardware_Interrupt.None) automatically.

**Will continue execution on all non-fatal errors**

A fatal error will be retunred if the CPU cannot fetch the current
instruction and its operand's. In this case, the CPU should be reset.

Inputs:
- console: The console to operate on

Returns:
- complete: Weather or not the current instruction or interrupt is finished
- error: Memory error caused by writing/reading to/from an invalid address
*/
@(require_results)
cpu_execute_clk_cycle :: proc(console: ^Console) -> (complete: bool, err: Maybe(Error)) {
	console.cpu.cycle_count += 1
	if console.cpu.stall_count > 0 {
		console.cpu.stall_count -= 1
		if console.cpu.stall_count == 0 do complete = true
		return
	}

	start_pc := console.cpu.pc
	if opcode, e := console_read_from_address(console, start_pc); e != nil {
		e := e.?
		return false, errorf(
			.Opcode_Error,
			"could not read opcode from $%04X: \"%s\"",
			start_pc,
			e.msg,
			severity = .Fatal,
		)
	} else {
		instr := get_instruction_from_opcode(opcode)
		console.cpu.current_instruction = nil

		// handle_interrupt and execute_instruction are mutually exclusive
		// meaning both will never be executed simultaneously
		switch console.cpu.interrupt {
		case .Reset:
			handle_interrupt(console)
		case .NMI:
			// BRK instruction has precedence over NMI
			if instr.type == .BRK {
				err = execute_instruction(console, instr)
			} else {
				handle_interrupt(console)
			}
		case .IRQ:
			// BRK instruction has precedence over IRQ
			// dont execute IRQ if IF (interrupt disable) flag is set
			if instr.type == .BRK || .IF in console.cpu.status {
				err = execute_instruction(console, instr)
			} else {
				handle_interrupt(console)
			}
		case .None:
			err = execute_instruction(console, instr)
		}
	}

	return

	handle_interrupt :: proc(console: ^Console) {
		// the pushed PC is expected to point to the next
		// instruction to be executed
		// interrupt priority from higest to lowest: reset, BRK, NMI, IRQ
		// @todo handle interrupt hijacking
		INTERRUPT_CYCLE_COUNT :: 7

		defer {
			console.cpu.stall_count = INTERRUPT_CYCLE_COUNT - 1
			console.cpu.interrupt = .None
		}

		switch console.cpu.interrupt {
		case .Reset:
			lo, hi: u8;e: Maybe(Error)
			lo, e = console_read_from_address(console, 0xfffc)
			hi, e = console_read_from_address(console, 0xfffd)
			assert(e == nil, "should always be able to read from $FFFC, $FFFD")
			console.cpu.pc = (u16(hi) << 8 | u16(lo))
		case .NMI:
			// if instr.type == .BRK do return true
			pc_to_push := console.cpu.pc
			stack_push(console, u8(pc_to_push >> 8))
			stack_push(console, u8(pc_to_push))
			status_byte := status_flags_to_byte(console.cpu.status, false)
			stack_push(console, status_byte)

			lo, hi: u8;e: Maybe(Error)
			lo, e = console_read_from_address(console, 0xfffa)
			hi, e = console_read_from_address(console, 0xfffb)
			assert(e == nil, "should always be able to read from $FFFA, $FFFB")

			console.cpu.status += {.IF}
			console.cpu.pc = (u16(hi) << 8) | u16(lo)
		case .IRQ:
			// if instr.type == .BRK do return true
			// if .IF in console.cpu.status do return true
			// same as for NMI only different interrupt vector
			pc_to_push := console.cpu.pc
			stack_push(console, u8(pc_to_push >> 8))
			stack_push(console, u8(pc_to_push))
			status_byte := status_flags_to_byte(console.cpu.status, false)
			stack_push(console, status_byte)

			lo, hi: u8;e: Maybe(Error)
			lo, e = console_read_from_address(console, 0xfffe)
			hi, e = console_read_from_address(console, 0xffff)
			assert(e == nil, "should always be able to read from $FFFE, $FFFF")

			console.cpu.status += {.IF}
			console.cpu.pc = (u16(hi) << 8) | u16(lo)
		case .None:
		// execute instruction
		}
	}

	execute_instruction :: proc(console: ^Console, instr: Instruction) -> (err: Maybe(Error)) {
		start_pc := console.cpu.pc
		op_addr: u16
		pc_incremented: bool
		cycles := instr.cycle_count

		defer {
			console.cpu.current_instruction = instr
			console.cpu.instruction_count += 1
			console.cpu.stall_count = cycles - 1

			// branch, jump and some other instructions will directly set PC
			if !pc_incremented {
				console.cpu.pc = start_pc + u16(instr.byte_size)
			}
		}

		// pre-calculate address for modes that need it
		#partial switch instr.addressing_mode {
		case .Accumulator, .Implied, .Relative:
		// no address to fetch
		case:
			page_crossed: bool
			if op_addr, page_crossed, err = get_instruction_operand_address(
				console,
				instr.addressing_mode,
			); err != nil {
				return errorf(
					.Operand_Error,
					"could not read instruction (%v) operand using addressing mode %v: \"%s\"",
					instr.type,
					instr.addressing_mode,
					err.?.msg,
					severity = .Fatal,
				)
			}

			if page_crossed {
				cycles += instr.page_boundary_extra_cycles
			}
		}

		#partial switch instr.type {
		// === Arithmetic and Logical ===
		case .ADC, .SBC, .USBC:
			// ADC and SBC are identical instruction with the only difference
			// that SBC will bit invert the operand
			val, e := read(console, op_addr, instr);err = e
			if instr.type == .SBC do val = ~val // invert operand if SBC
			if instr.type == .USBC do val = ~val // invert operand if USBC
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
			set_zn(console, console.cpu.acc)
		case .AND:
			val, e := read(console, op_addr, instr);err = e
			console.cpu.acc &= val
			set_zn(console, console.cpu.acc)
		case .ORA:
			val, e := read(console, op_addr, instr);err = e
			console.cpu.acc |= val
			set_zn(console, console.cpu.acc)
		case .EOR:
			val, e := read(console, op_addr, instr);err = e
			console.cpu.acc ~= val
			set_zn(console, console.cpu.acc)
		// === Compare ===
		case .CMP:
			val, e := read(console, op_addr, instr);err = e
			temp := console.cpu.acc - val
			console.cpu.status -= {.CF}
			if console.cpu.acc >= val do console.cpu.status += {.CF}
			set_zn(console, temp)
		case .CPX:
			val, e := read(console, op_addr, instr);err = e
			temp := console.cpu.x - val
			console.cpu.status -= {.CF}
			if console.cpu.x >= val do console.cpu.status += {.CF}
			set_zn(console, temp)
		case .CPY:
			val, e := read(console, op_addr, instr);err = e
			temp := console.cpu.y - val
			console.cpu.status -= {.CF}
			if console.cpu.y >= val do console.cpu.status += {.CF}
			set_zn(console, temp)
		// === Bit Test ===
		case .BIT:
			val, e := read(console, op_addr, instr);err = e
			console.cpu.status -= {.ZF, .NF, .VF}
			if console.cpu.acc & val == 0 do console.cpu.status += {.ZF}
			if 0x80 & val != 0 do console.cpu.status += {.NF}
			if 0x40 & val != 0 do console.cpu.status += {.VF}
		// === Load/Store ===
		case .LDA:
			console.cpu.acc, err = read(console, op_addr, instr)
			set_zn(console, console.cpu.acc)
		case .LDX:
			console.cpu.x, err = read(console, op_addr, instr)
			set_zn(console, console.cpu.x)
		case .LDY:
			console.cpu.y, err = read(console, op_addr, instr)
			set_zn(console, console.cpu.y)
		case .STA:
			err = write(console, op_addr, console.cpu.acc, instr)
		case .STX:
			err = write(console, op_addr, console.cpu.x, instr)
		case .STY:
			err = write(console, op_addr, console.cpu.y, instr)
		// === Increment/Decrement ===
		case .INC:
			val, e := read(console, op_addr, instr);err = e
			val += 1
			if e = write(console, op_addr, val, instr); e != nil do err = e
			set_zn(console, val)
		case .DEC:
			val, e := read(console, op_addr, instr);err = e
			val -= 1
			if e = write(console, op_addr, val, instr); e != nil do err = e
			set_zn(console, val)
		case .INX:
			console.cpu.x += 1
			set_zn(console, console.cpu.x)
		case .INY:
			console.cpu.y += 1
			set_zn(console, console.cpu.y)
		case .DEX:
			console.cpu.x -= 1
			set_zn(console, console.cpu.x)
		case .DEY:
			console.cpu.y -= 1
			set_zn(console, console.cpu.y)
		// === Shifts and Rotates ===
		case .ASL:
			console.cpu.status -= {.CF}
			if instr.addressing_mode == .Accumulator {
				if console.cpu.acc & 0x80 != 0 do console.cpu.status += {.CF}
				console.cpu.acc <<= 1
				set_zn(console, console.cpu.acc)
			} else {
				val, e := read(console, op_addr, instr);err = e
				if val & 0x80 != 0 do console.cpu.status += {.CF}
				val <<= 1
				set_zn(console, val)
				if e = write(console, op_addr, val, instr); e != nil do err = e
			}
		case .LSR:
			console.cpu.status -= {.CF}
			if instr.addressing_mode == .Accumulator {
				if console.cpu.acc & 0x01 != 0 do console.cpu.status += {.CF}
				console.cpu.acc >>= 1
				set_zn(console, console.cpu.acc)
			} else {
				val, e := read(console, op_addr, instr);err = e
				if val & 0x01 != 0 do console.cpu.status += {.CF}
				val >>= 1
				if e = write(console, op_addr, val, instr); e != nil do err = e
				set_zn(console, val)
			}
		case .ROL:
			c := u8(.CF in console.cpu.status)
			console.cpu.status -= {.CF}
			if instr.addressing_mode == .Accumulator {
				if console.cpu.acc & 0x80 != 0 do console.cpu.status += {.CF}
				console.cpu.acc = (console.cpu.acc << 1) | c
				set_zn(console, console.cpu.acc)
			} else {
				val, e := read(console, op_addr, instr);err = e
				if val & 0x80 != 0 do console.cpu.status += {.CF}
				val = (val << 1) | c
				if e = write(console, op_addr, val, instr); e != nil do err = e
				set_zn(console, val)
			}
		case .ROR:
			c := u8(.CF in console.cpu.status) << 7
			console.cpu.status -= {.CF}
			if instr.addressing_mode == .Accumulator {
				if console.cpu.acc & 0x01 != 0 do console.cpu.status += {.CF}
				console.cpu.acc = (console.cpu.acc >> 1) | c
				set_zn(console, console.cpu.acc)
			} else {
				val, e := read(console, op_addr, instr);err = e
				if val & 0x01 != 0 do console.cpu.status += {.CF}
				val = (val >> 1) | c
				if e = write(console, op_addr, val, instr); e != nil do err = e
				set_zn(console, val)
			}
		// === Program Flow Control ===
		case .JMP:
			console.cpu.pc = op_addr
			pc_incremented = true
		case .JSR:
			pc_to_push := start_pc + 2 // address of last byte of JSR instruction
			stack_push(console, u8(pc_to_push >> 8))
			stack_push(console, u8(pc_to_push))
			console.cpu.pc = op_addr
			pc_incremented = true
		case .RTS:
			lo := stack_pull(console)
			hi := stack_pull(console)
			// add 1 since PC points to the last byte of the JSR instruction
			console.cpu.pc = ((u16(hi) << 8) | u16(lo)) + 1
			pc_incremented = true
		case .RTI:
			status_byte := stack_pull(console)
			lo := stack_pull(console)
			hi := stack_pull(console)
			console.cpu.status = status_flags_from_byte(status_byte)
			// Dont add 1 since PC is expected to point to the first byte
			// of the next instruction when interrupt is triggered.
			// Different from subroutine jump (JSR) where PC is the last byte of
			// JSR.
			console.cpu.pc = (u16(hi) << 8) | u16(lo)
			pc_incremented = true
		// === Branches ===
		case .BCC:
			err = branch(console, .CF not_in console.cpu.status)
			pc_incremented = true
			err = write_error(err, instr)
		case .BCS:
			err = branch(console, .CF in console.cpu.status)
			pc_incremented = true
			err = write_error(err, instr)
		case .BEQ:
			err = branch(console, .ZF in console.cpu.status)
			pc_incremented = true
			err = write_error(err, instr)
		case .BNE:
			err = branch(console, .ZF not_in console.cpu.status)
			pc_incremented = true
			err = write_error(err, instr)
		case .BMI:
			err = branch(console, .NF in console.cpu.status)
			pc_incremented = true
			err = write_error(err, instr)
		case .BPL:
			err = branch(console, .NF not_in console.cpu.status)
			pc_incremented = true
			err = write_error(err, instr)
		case .BVC:
			err = branch(console, .VF not_in console.cpu.status)
			pc_incremented = true
			err = write_error(err, instr)
		case .BVS:
			err = branch(console, .VF in console.cpu.status)
			pc_incremented = true
			err = write_error(err, instr)
		// === Register Transfers ===
		case .TAX:
			console.cpu.x = console.cpu.acc;set_zn(console, console.cpu.x)
		case .TAY:
			console.cpu.y = console.cpu.acc;set_zn(console, console.cpu.y)
		case .TXA:
			console.cpu.acc = console.cpu.x;set_zn(console, console.cpu.acc)
		case .TYA:
			console.cpu.acc = console.cpu.y;set_zn(console, console.cpu.acc)
		case .TSX:
			console.cpu.x = console.cpu.sp;set_zn(console, console.cpu.x)
		case .TXS:
			console.cpu.sp = console.cpu.x
		// === Stack Operations ===
		case .PHA:
			stack_push(console, console.cpu.acc)
		case .PHP:
			// when pushed, BF and _5 are set
			status_byte := status_flags_to_byte(console.cpu.status)
			stack_push(console, status_byte)
		case .PLA:
			console.cpu.acc = stack_pull(console)
			set_zn(console, console.cpu.acc)
		case .PLP:
			// when pulled, BF and _5 are set
			status_byte := stack_pull(console)
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
			lo, hi: u8;e: Maybe(Error)
			pc_to_push := start_pc + 2
			stack_push(console, u8(pc_to_push >> 8))
			stack_push(console, u8(pc_to_push))
			status_byte := status_flags_to_byte(console.cpu.status)
			stack_push(console, status_byte)
			lo, e = console_read_from_address(console, 0xfffe)
			hi, e = console_read_from_address(console, 0xffff)
			assert(e == nil, "should always be able to read from $FFFE, $FFFF")
			console.cpu.status += {.IF}
			console.cpu.pc = (u16(hi) << 8) | u16(lo)
			pc_incremented = true
		case .NOP:
		// does nothing

		// === Illegal Opcodes ===
		case .LAX:
			val, e := read(console, op_addr, instr);err = e
			console.cpu.acc = val
			console.cpu.x = val
			set_zn(console, val)
		case .SAX:
			val := console.cpu.acc & console.cpu.x
			err = write(console, op_addr, val, instr)
		case .DCP:
			val, e := read(console, op_addr, instr);err = e
			val -= 1
			if e = write(console, op_addr, val, instr); e != nil do err = e
			temp := console.cpu.acc - val
			console.cpu.status -= {.CF}
			if console.cpu.acc >= val do console.cpu.status += {.CF}
			set_zn(console, temp)
		case .ISC:
			val, e := read(console, op_addr, instr);err = e
			val += 1
			if e = write(console, op_addr, val, instr); e != nil do err = e

			val = ~val // invert operand
			a := console.cpu.acc
			c := .CF in console.cpu.status
			console.cpu.status -= {.CF, .VF}
			if u16(a) + u16(val) + u16(c) > 0xff do console.cpu.status += {.CF}
			result := a + val + u8(c)
			signed_overflow := (a & 0x80) == (val & 0x80) && (result & 0x80) != (a & 0x80)
			if signed_overflow do console.cpu.status += {.VF}
			console.cpu.acc = result
			set_zn(console, console.cpu.acc)
		case .SLO:
			val, e := read(console, op_addr, instr);err = e
			console.cpu.status -= {.CF}
			if val & 0x80 != 0 do console.cpu.status += {.CF}
			val <<= 1
			if e = write(console, op_addr, val, instr); e != nil do err = e
			console.cpu.acc |= val
			set_zn(console, console.cpu.acc)
		case .RLA:
			c := u8(.CF in console.cpu.status)
			console.cpu.status -= {.CF}
			val, e := read(console, op_addr, instr);err = e
			if val & 0x80 != 0 do console.cpu.status += {.CF}
			val = (val << 1) | c
			if e = write(console, op_addr, val, instr); e != nil do err = e
			console.cpu.acc &= val
			set_zn(console, console.cpu.acc)
		case .SRE:
			val, e := read(console, op_addr, instr);err = e
			console.cpu.status -= {.CF}
			if val & 0x01 != 0 do console.cpu.status += {.CF}
			val >>= 1
			if e = write(console, op_addr, val, instr); e != nil do err = e
			console.cpu.acc ~= val
			set_zn(console, console.cpu.acc)
		case .RRA:
			c := u8(.CF in console.cpu.status) << 7
			console.cpu.status -= {.CF}
			val, e := read(console, op_addr, instr);err = e
			if val & 0x01 != 0 do console.cpu.status += {.CF}
			val = (val >> 1) | c
			if e = write(console, op_addr, val, instr); e != nil do err = e

			a := console.cpu.acc
			c_in := .CF in console.cpu.status
			console.cpu.status -= {.CF, .VF}
			if u16(a) + u16(val) + u16(c_in) > 0xff do console.cpu.status += {.CF}
			result := a + val + u8(c_in)
			signed_overflow := (a & 0x80) == (val & 0x80) && (result & 0x80) != (a & 0x80)
			if signed_overflow do console.cpu.status += {.VF}
			console.cpu.acc = result
			set_zn(console, console.cpu.acc)
		case .JAM:
			// Halt execution, can do this by setting PC to itself.
			console.cpu.pc = start_pc
			pc_incremented = true
		case:
			panic(fmt.tprintf("unhandled instruction: %v", instr.type))
		}

		return

		@(require_results)
		read :: proc(
			console: ^Console,
			address: u16,
			instruction: Instruction,
		) -> (
			u8,
			Maybe(Error),
		) {
			if data, err := console_read_from_address(console, address); err != nil {
				return 0, read_error(err, instruction)
			} else {
				return data, nil
			}
		}

		@(require_results)
		write :: proc(
			console: ^Console,
			address: u16,
			data: u8,
			instruction: Instruction,
		) -> Maybe(Error) {
			if err := console_write_to_address(console, address, data); err != nil {
				return write_error(err, instruction)
			} else {
				return nil
			}
		}

		@(require_results)
		read_error :: proc(err: Maybe(Error), instr: Instruction) -> Maybe(Error) {
			if err == nil do return nil

			err := err.?
			msg_template := "cannot read operand for '%v' (%v addressing): \"%s\""
			return errorf(
				err.type,
				msg_template,
				instr.type,
				instr.addressing_mode,
				err.msg,
				severity = .Error,
			)
		}

		@(require_results)
		write_error :: proc(err: Maybe(Error), instr: Instruction) -> Maybe(Error) {
			if err == nil do return nil

			err := err.?
			msg_template := "'%v' (%v addressing) cannot write: \"%s\""
			return errorf(
				err.type,
				msg_template,
				instr.type,
				instr.addressing_mode,
				err.msg,
				severity = .Warning,
			)
		}

		set_zn :: proc(console: ^Console, data: u8) {
			console.cpu.status -= {.ZF, .NF}
			if data == 0 do console.cpu.status += {.ZF}
			if (data & 0x80) != 0 do console.cpu.status += {.NF}
		}

		// branch handles the logic for all conditional branch instructions
		@(require_results)
		branch :: proc(console: ^Console, condition: bool) -> (err: Maybe(Error)) {
			if condition {
				console.cpu.cycle_count += 1
				address := console.cpu.pc + 1
				rel_addr: u8
				if rel_addr, err = console_read_from_address(console, address); err != nil {
					err = errorf(
						.Branch_Error,
						"could not read relative address from $%04X",
						address,
					)
				}

				// + 2 to point to next instruction
				jump_addr := u16(i16(console.cpu.pc) + 2 + i16(i8(rel_addr)))

				if is_page_crossed(console.cpu.pc + 2, jump_addr) {
					console.cpu.cycle_count += 1 // page cross adds another cycle
				}
				console.cpu.pc = jump_addr
			} else {
				console.cpu.pc += 2
			}

			return
		}
	}

	stack_push :: proc(console: ^Console, data: u8) {
		// the stack pointer will wraparound on overflow and underflow
		// so its always contained within addresses $0100-01ff, a write
		// error cannot occur here
		address := PAGE_1_BASE_ADDRESS + u16(console.cpu.sp)
		e := console_write_to_address(console, address, data)
		assert(e == nil, "SP should never be outside of range $0100-$01FF")

		console.cpu.sp -= 1
	}

	@(require_results)
	stack_pull :: proc(console: ^Console) -> u8 {
		// the stack pointer will wraparound on overflow and underflow
		// so its always contained within addresses $0100-01ff, a write
		// error cannot occur here
		console.cpu.sp += 1
		address := PAGE_1_BASE_ADDRESS + u16(console.cpu.sp)
		data, e := console_read_from_address(console, address)
		assert(e == nil, "SP should never be outside of range $0100-$01FF")
		return data
	}
}

// calculate the effective address for an instruction and checks for page crossing
// assumes that pc is pointing to opcode
@(require_results)
get_instruction_operand_address :: proc(
	console: ^Console,
	mode: Instruction_Addressing_Mode,
) -> (
	return_addr: u16,
	page_crossed: bool,
	err: Maybe(Error),
) {
	// system is little endian so low byte is stored first in memory
	cpu := console.cpu
	err_msg_template := "could not read instruction operand at $%04X"
	switch mode {
	case .Immediate:
		return_addr = cpu.pc + 1
	case .Zeropage:
		zp_addr := console_read_from_address(console, cpu.pc + 1) or_return
		return_addr = u16(zp_addr)
	case .Zeropage_X:
		// overflow is ignored so 0x00ff (address) + 1 (X or Y) will cause
		// wraparound ensuring that the address is always contained within
		// the zeropage
		base_addr := console_read_from_address(console, cpu.pc + 1) or_return
		return_addr = u16(base_addr + cpu.x) // emulate overflow properly
	case .Zeropage_Y:
		base_addr := console_read_from_address(console, cpu.pc + 1) or_return
		return_addr = u16(base_addr + cpu.y)
	case .Absolute:
		lo := console_read_from_address(console, cpu.pc + 1) or_return
		hi := console_read_from_address(console, cpu.pc + 2) or_return
		return_addr = (u16(hi) << 8) | u16(lo)
	case .Absolute_X:
		lo := console_read_from_address(console, cpu.pc + 1) or_return
		hi := console_read_from_address(console, cpu.pc + 2) or_return
		base_addr := (u16(hi) << 8) | u16(lo)
		return_addr = base_addr + u16(cpu.x)
		page_crossed = is_page_crossed(base_addr, return_addr)
	case .Absolute_Y:
		lo := console_read_from_address(console, cpu.pc + 1) or_return
		hi := console_read_from_address(console, cpu.pc + 2) or_return
		base_addr := (u16(hi) << 8) | u16(lo)
		return_addr = base_addr + u16(cpu.y)
		page_crossed = is_page_crossed(base_addr, return_addr)
	case .Indirect:
		// the infamous JMP indirect bug: if the low byte of the address vector
		// is 0xFF, due to incorrect wraparound the high byte is fetched
		// from the start of the same page, not the next one.
		lo_ptr := console_read_from_address(console, cpu.pc + 1) or_return
		hi_ptr := console_read_from_address(console, cpu.pc + 2) or_return
		ptr := (u16(hi_ptr) << 8) | u16(lo_ptr)
		lo := console_read_from_address(console, ptr) or_return
		hi_ptr_buggy := (ptr & 0xff00) | u16(u8(ptr + 1)) // emulate overflow
		hi := console_read_from_address(console, hi_ptr_buggy) or_return
		return_addr = (u16(hi) << 8) | u16(lo)
	case .Zeropage_Indirect_X:
		zp_base := console_read_from_address(console, cpu.pc + 1) or_return
		ptr := zp_base + cpu.x
		lo := console_read_from_address(console, u16(ptr)) or_return
		hi := console_read_from_address(console, u16(ptr + 1)) or_return
		return_addr = (u16(hi) << 8) | u16(lo)
	case .Zeropage_Indirect_Y:
		// zp_ptr, lo, hi: u8
		// error: Memory_Error
		zp_ptr := console_read_from_address(console, cpu.pc + 1) or_return
		lo := console_read_from_address(console, u16(zp_ptr)) or_return
		hi := console_read_from_address(console, u16(zp_ptr + 1)) or_return
		base_addr := (u16(hi) << 8) | u16(lo)
		return_addr = base_addr + u16(cpu.y)
		page_crossed = is_page_crossed(base_addr, return_addr)
	case .Implied, .Accumulator, .Relative:
		// Implied, Accumulator, and Relative modes don't use this function.
		panic(fmt.tprintf("tried to fetch instruction operand using address mode %v", mode))
	}

	return
}

@(require_results)
is_page_crossed :: proc(address1, address2: u16) -> bool {
	return address1 & 0xff00 != address2 & 0xff00
}

@(require_results)
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

@(require_results)
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

