package nemu

import "core:fmt"
import "core:mem" // For map initialization, if needed on specific backends
import "core:strings"
import "core:strconv"

// failure_explanations is a map to store the hexadecimal failure codes
// and their associated string explanations.
// It is populated once when the program initializes.
failure_explanations: map[u16]string;

// populate_failure_explanations fills the `failure_explanations` map
// with all the test failure codes and their meanings as provided in the
// NES CPU test ROM documentation.
// If a code appears multiple times in the document, the last explanation
// listed for that code will be the one stored, reflecting the document's
// implicit hierarchy where later, more specific entries might override
// earlier, more general ones.
@(init)
populate_failure_explanations :: proc() {
    // Note: The document presents codes in groups. Some codes are duplicated
    // across these groups (e.g., 0x001h appears in branch tests, SBC failure
    // for byte 03h, and RRA invalid opcode tests). This map's behavior is
    // to store the latest assignment for a given key. The blank entries at
    // the very end of the source text are considered incomplete/template
    // and are intentionally omitted for practical utility.

    // --- (byte 02h only) errors ---

    failure_explanations[0x000] = "tests completed successfully";

    // Branch tests
    failure_explanations[0x001] = "BCS failed to branch";
    failure_explanations[0x002] = "BCS branched when it shouldn't have";
    failure_explanations[0x003] = "BCC branched when it shouldn't have";
    failure_explanations[0x004] = "BCC failed to branch";
    failure_explanations[0x005] = "BEQ failed to branch";
    failure_explanations[0x006] = "BEQ branched when it shouldn't have";
    failure_explanations[0x007] = "BNE failed to branch";
    failure_explanations[0x008] = "BNE branched when it shouldn't have";
    failure_explanations[0x009] = "BVS failed to branch";
    failure_explanations[0x00A] = "BVC branched when it shouldn't have";
    failure_explanations[0x00B] = "BVC failed to branch";
    failure_explanations[0x00C] = "BVS branched when it shouldn't have";
    failure_explanations[0x00D] = "BPL failed to branch";
    failure_explanations[0x00E] = "BPL branched when it shouldn't have";
    failure_explanations[0x00F] = "BMI failed to branch";
    failure_explanations[0x010] = "BMI branched when it shouldn't have";

    // Flag tests
    failure_explanations[0x011] = "PHP/flags failure (bits set)";
    failure_explanations[0x012] = "PHP/flags failure (bits clear)";
    failure_explanations[0x013] = "PHP/flags failure (misc bit states)";
    failure_explanations[0x014] = "PLP/flags failure (misc bit states)";
    failure_explanations[0x015] = "PLP/flags failure (misc bit states)";
    failure_explanations[0x016] = "PHA/PLA failure (PLA didn't affect Z and N properly)";
    failure_explanations[0x017] = "PHA/PLA failure (PLA didn't affect Z and N properly)";

    // Immediate instruction tests (some codes are duplicated/re-used later in the text)
    failure_explanations[0x018] = "ORA # failure";
    failure_explanations[0x019] = "ORA # failure";
    failure_explanations[0x01A] = "AND # failure";
    failure_explanations[0x01B] = "AND # failure";
    failure_explanations[0x01C] = "EOR # failure";
    failure_explanations[0x01D] = "EOR # failure";
    failure_explanations[0x01E] = "ADC # failure (overflow/carry problems)";
    failure_explanations[0x01F] = "ADC # failure (decimal mode was turned on)";
    failure_explanations[0x020] = "ADC # failure";
    failure_explanations[0x021] = "ADC # failure";
    failure_explanations[0x022] = "ADC # failure";
    failure_explanations[0x023] = "LDA # failure (didn't set N and Z correctly)";
    failure_explanations[0x024] = "LDA # failure (didn't set N and Z correctly)";
    failure_explanations[0x025] = "CMP # failure (messed up flags)";
    failure_explanations[0x026] = "CMP # failure (messed up flags)";
    failure_explanations[0x027] = "CMP # failure (messed up flags)";
    failure_explanations[0x028] = "CMP # failure (messed up flags)";
    failure_explanations[0x029] = "CMP # failure (messed up flags)";
    failure_explanations[0x02A] = "CMP # failure (messed up flags)";
    failure_explanations[0x02B] = "CPY # failure (messed up flags)";
    failure_explanations[0x02C] = "CPY # failure (messed up flags)";
    failure_explanations[0x02D] = "CPY # failure (messed up flags)";
    failure_explanations[0x02E] = "CPY # failure (messed up flags)";
    failure_explanations[0x02F] = "CPY # failure (messed up flags)";
    failure_explanations[0x030] = "CPY # failure (messed up flags)";
    failure_explanations[0x031] = "CPY # failure (messed up flags)";
    failure_explanations[0x032] = "CPX # failure (messed up flags)";
    failure_explanations[0x033] = "CPX # failure (messed up flags)";
    failure_explanations[0x034] = "CPX # failure (messed up flags)";
    failure_explanations[0x035] = "CPX # failure (messed up flags)";
    failure_explanations[0x036] = "CPX # failure (messed up flags)";
    failure_explanations[0x037] = "CPX # failure (messed up flags)";
    failure_explanations[0x038] = "CPX # failure (messed up flags)";
    failure_explanations[0x039] = "LDX # failure (didn't set N and Z correctly)";
    failure_explanations[0x03A] = "LDX # failure (didn't set N and Z correctly)";
    failure_explanations[0x03B] = "LDY # failure (didn't set N and Z correctly)";
    failure_explanations[0x03C] = "LDY # failure (didn't set N and Z correctly)";
    failure_explanations[0x03D] = "compare(s) stored the result in a register (whoops!)";
    failure_explanations[0x071] = "SBC # failure"; // This block is out of sequential order in the text
    failure_explanations[0x072] = "SBC # failure";
    failure_explanations[0x073] = "SBC # failure";
    failure_explanations[0x074] = "SBC # failure";
    failure_explanations[0x075] = "SBC # failure";

    // Implied instruction tests (continues the sequence from above)
    failure_explanations[0x03E] = "INX/DEX/INY/DEY did something bad";
    failure_explanations[0x03F] = "INY/DEY messed up overflow or carry";
    failure_explanations[0x040] = "INX/DEX messed up overflow or carry";
    failure_explanations[0x041] = "TAY did something bad (changed wrong regs, messed up flags)";
    failure_explanations[0x042] = "TAX did something bad (changed wrong regs, messed up flags)";
    failure_explanations[0x043] = "TYA did something bad (changed wrong regs, messed up flags)";
    failure_explanations[0x044] = "TXA did something bad (changed wrong regs, messed up flags)";
    failure_explanations[0x045] = "TXS didn't set flags right, or TSX touched flags and it shouldn't have";

    // Stack tests
    failure_explanations[0x046] = "wrong data popped, or data not in right location on stack";
    failure_explanations[0x047] = "JSR didn't work as expected";
    failure_explanations[0x048] = "RTS/JSR shouldn't have affected flags";
    failure_explanations[0x049] = "RTI/RTS didn't work right when return addys/data were manually pushed";

    // Accumulator tests
    failure_explanations[0x04A] = "LSR A failed";
    failure_explanations[0x04B] = "ASL A failed";
    failure_explanations[0x04C] = "ROR A failed";
    failure_explanations[0x04D] = "ROL A failed";

    // (indirect,x) tests
    failure_explanations[0x058] = "LDA didn't load the data it expected to load";
    failure_explanations[0x059] = "STA didn't store the data where it was supposed to";
    failure_explanations[0x05A] = "ORA failure";
    failure_explanations[0x05B] = "ORA failure";
    failure_explanations[0x05C] = "AND failure";
    failure_explanations[0x05D] = "AND failure";
    failure_explanations[0x05E] = "EOR failure";
    failure_explanations[0x05F] = "EOR failure";
    failure_explanations[0x060] = "ADC failure";
    failure_explanations[0x061] = "ADC failure";
    failure_explanations[0x062] = "ADC failure";
    failure_explanations[0x063] = "ADC failure";
    failure_explanations[0x064] = "ADC failure";
    failure_explanations[0x065] = "CMP failure";
    failure_explanations[0x066] = "CMP failure";
    failure_explanations[0x067] = "CMP failure";
    failure_explanations[0x068] = "CMP failure";
    failure_explanations[0x069] = "CMP failure";
    failure_explanations[0x06A] = "CMP failure";
    failure_explanations[0x06B] = "CMP failure";
    failure_explanations[0x06C] = "SBC failure";
    failure_explanations[0x06D] = "SBC failure";
    failure_explanations[0x06E] = "SBC failure";
    failure_explanations[0x06F] = "SBC failure";
    failure_explanations[0x070] = "SBC failure";

    // Zeropage tests (continues from 0x075 in Immediate instruction tests, then lists new codes starting 0x076)
    failure_explanations[0x076] = "LDA didn't set the flags properly";
    failure_explanations[0x077] = "STA affected flags it shouldn't";
    failure_explanations[0x078] = "LDY didn't set the flags properly";
    failure_explanations[0x079] = "STY affected flags it shouldn't";
    failure_explanations[0x07A] = "LDX didn't set the flags properly";
    failure_explanations[0x07B] = "STX affected flags it shouldn't";
    failure_explanations[0x07C] = "BIT failure";
    failure_explanations[0x07D] = "BIT failure";
    failure_explanations[0x07E] = "ORA failure";
    failure_explanations[0x07F] = "ORA failure";
    failure_explanations[0x080] = "AND failure";
    failure_explanations[0x081] = "AND failure";
    failure_explanations[0x082] = "EOR failure";
    failure_explanations[0x083] = "EOR failure";
    failure_explanations[0x084] = "ADC failure";
    failure_explanations[0x085] = "ADC failure";
    failure_explanations[0x086] = "ADC failure";
    failure_explanations[0x087] = "ADC failure";
    failure_explanations[0x088] = "ADC failure";
    failure_explanations[0x089] = "CMP failure";
    failure_explanations[0x08A] = "CMP failure";
    failure_explanations[0x08B] = "CMP failure";
    failure_explanations[0x08C] = "CMP failure";
    failure_explanations[0x08D] = "CMP failure";
    failure_explanations[0x08E] = "CMP failure";
    failure_explanations[0x08F] = "CMP failure";
    failure_explanations[0x090] = "SBC failure";
    failure_explanations[0x091] = "SBC failure";
    failure_explanations[0x092] = "SBC failure";
    failure_explanations[0x093] = "SBC failure";
    failure_explanations[0x094] = "SBC failure";
    failure_explanations[0x095] = "CPX failure";
    failure_explanations[0x096] = "CPX failure";
    failure_explanations[0x097] = "CPX failure";
    failure_explanations[0x098] = "CPX failure";
    failure_explanations[0x099] = "CPX failure";
    failure_explanations[0x09A] = "CPX failure";
    failure_explanations[0x09B] = "CPX failure";
    failure_explanations[0x09C] = "CPY failure";
    failure_explanations[0x09D] = "CPY failure";
    failure_explanations[0x09E] = "CPY failure";
    failure_explanations[0x09F] = "CPY failure";
    failure_explanations[0x0A0] = "CPY failure";
    failure_explanations[0x0A1] = "CPY failure";
    failure_explanations[0x0A2] = "CPY failure";
    failure_explanations[0x0A3] = "LSR failure";
    failure_explanations[0x0A4] = "LSR failure";
    failure_explanations[0x0A5] = "ASL failure";
    failure_explanations[0x0A6] = "ASL failure";
    failure_explanations[0x0A7] = "ROL failure";
    failure_explanations[0x0A8] = "ROL failure";
    failure_explanations[0x0A9] = "ROR failure";
    failure_explanations[0x0AA] = "ROR failure";
    failure_explanations[0x0AB] = "INC failure";
    failure_explanations[0x0AC] = "INC failure";
    failure_explanations[0x0AD] = "DEC failure";
    failure_explanations[0x0AE] = "DEC failure";
    failure_explanations[0x0AF] = "DEC failure";

    // Absolute tests
    failure_explanations[0x0B0] = "LDA didn't set the flags properly";
    failure_explanations[0x0B1] = "STA affected flags it shouldn't";
    failure_explanations[0x0B2] = "LDY didn't set the flags properly";
    failure_explanations[0x0B3] = "STY affected flags it shouldn't";
    failure_explanations[0x0B4] = "LDX didn't set the flags properly";
    failure_explanations[0x0B5] = "STX affected flags it shouldn't";
    failure_explanations[0x0B6] = "BIT failure";
    failure_explanations[0x0B7] = "BIT failure";
    failure_explanations[0x0B8] = "ORA failure";
    failure_explanations[0x0B9] = "ORA failure";
    failure_explanations[0x0BA] = "AND failure";
    failure_explanations[0x0BB] = "AND failure";
    failure_explanations[0x0BC] = "EOR failure";
    failure_explanations[0x0BD] = "EOR failure";
    failure_explanations[0x0BE] = "ADC failure";
    failure_explanations[0x0BF] = "ADC failure";
    failure_explanations[0x0C0] = "ADC failure";
    failure_explanations[0x0C1] = "ADC failure";
    failure_explanations[0x0C2] = "ADC failure";
    failure_explanations[0x0C3] = "CMP failure";
    failure_explanations[0x0C4] = "CMP failure";
    failure_explanations[0x0C5] = "CMP failure";
    failure_explanations[0x0C6] = "CMP failure";
    failure_explanations[0x0C7] = "CMP failure";
    failure_explanations[0x0C8] = "CMP failure";
    failure_explanations[0x0C9] = "CMP failure";
    failure_explanations[0x0CA] = "SBC failure";
    failure_explanations[0x0CB] = "SBC failure";
    failure_explanations[0x0CC] = "SBC failure";
    failure_explanations[0x0CD] = "SBC failure";
    failure_explanations[0x0CE] = "SBC failure";
    failure_explanations[0x0CF] = "CPX failure";
    failure_explanations[0x0D0] = "CPX failure";
    failure_explanations[0x0D1] = "CPX failure";
    failure_explanations[0x0D2] = "CPX failure";
    failure_explanations[0x0D3] = "CPX failure";
    failure_explanations[0x0D4] = "CPX failure";
    failure_explanations[0x0D5] = "CPX failure";
    failure_explanations[0x0D6] = "CPY failure";
    failure_explanations[0x0D7] = "CPY failure";
    failure_explanations[0x0D8] = "CPY failure";
    failure_explanations[0x0D9] = "CPY failure";
    failure_explanations[0x0DA] = "CPY failure";
    failure_explanations[0x0DB] = "CPY failure";
    failure_explanations[0x0DC] = "CPY failure";
    failure_explanations[0x0DD] = "LSR failure";
    failure_explanations[0x0DE] = "LSR failure";
    failure_explanations[0x0DF] = "ASL failure";
    failure_explanations[0x0E0] = "ASL failure";
    failure_explanations[0x0E1] = "ROR failure";
    failure_explanations[0x0E2] = "ROR failure";
    failure_explanations[0x0E3] = "ROL failure";
    failure_explanations[0x0E4] = "ROL failure";
    failure_explanations[0x0E5] = "INC failure";
    failure_explanations[0x0E6] = "INC failure";
    failure_explanations[0x0E7] = "DEC failure";
    failure_explanations[0x0E8] = "DEC failure";
    failure_explanations[0x0E9] = "DEC failure";

    // (indirect),y tests
    failure_explanations[0x0EA] = "LDA didn't load what it was supposed to";
    failure_explanations[0x0EB] = "read location should've wrapped around ffffh to 0000h";
    failure_explanations[0x0EC] = "should've wrapped zeropage address";
    failure_explanations[0x0ED] = "ORA failure";
    failure_explanations[0x0EE] = "ORA failure";
    failure_explanations[0x0EF] = "AND failure";
    failure_explanations[0x0F0] = "AND failure";
    failure_explanations[0x0F1] = "EOR failure";
    failure_explanations[0x0F2] = "EOR failure";
    failure_explanations[0x0F3] = "ADC failure";
    failure_explanations[0x0F4] = "ADC failure";
    failure_explanations[0x0F5] = "ADC failure";
    failure_explanations[0x0F6] = "ADC failure";
    failure_explanations[0x0F7] = "ADC failure";
    failure_explanations[0x0F8] = "CMP failure";
    failure_explanations[0x0F9] = "CMP failure";
    failure_explanations[0x0FA] = "CMP failure";
    failure_explanations[0x0FB] = "CMP failure";
    failure_explanations[0x0FC] = "CMP failure";
    failure_explanations[0x0FD] = "CMP failure";
    failure_explanations[0x0FE] = "CMP failure";

    // --- (error byte location 03h starts here) ---

    failure_explanations[0x000] = "no error, all tests pass"; // Overwrites 0x000 from byte 02h
    failure_explanations[0x001] = "SBC failure"; // Overwrites existing 0x001 from byte 02h
    failure_explanations[0x002] = "SBC failure"; // Overwrites existing 0x002 from byte 02h
    failure_explanations[0x003] = "SBC failure"; // Overwrites existing 0x003 from byte 02h
    failure_explanations[0x004] = "SBC failure"; // Overwrites existing 0x004 from byte 02h
    failure_explanations[0x005] = "SBC failure"; // Overwrites existing 0x005 from byte 02h
    failure_explanations[0x006] = "STA failure"; // Overwrites existing 0x006 from byte 02h
    failure_explanations[0x007] = "JMP () data reading didn't wrap properly (this fails on a 65C02)"; // Overwrites existing 0x007 from byte 02h

    // Zeropage,x tests (many codes are duplicated/re-used, overwriting earlier entries)
    failure_explanations[0x008] = "LDY,X failure";
    failure_explanations[0x009] = "LDY,X failure";
    failure_explanations[0x00A] = "STY,X failure";
    failure_explanations[0x00B] = "ORA failure";
    failure_explanations[0x00C] = "ORA failure";
    failure_explanations[0x00D] = "AND failure";
    failure_explanations[0x00E] = "AND failure";
    failure_explanations[0x00F] = "EOR failure";
    failure_explanations[0x010] = "EOR failure";
    failure_explanations[0x011] = "ADC failure";
    failure_explanations[0x012] = "ADC failure";
    failure_explanations[0x013] = "ADC failure";
    failure_explanations[0x014] = "ADC failure";
    failure_explanations[0x015] = "ADC failure";
    failure_explanations[0x016] = "CMP failure";
    failure_explanations[0x017] = "CMP failure";
    failure_explanations[0x018] = "CMP failure";
    failure_explanations[0x019] = "CMP failure";
    failure_explanations[0x01A] = "CMP failure";
    failure_explanations[0x01B] = "CMP failure";
    failure_explanations[0x01C] = "CMP failure";
    failure_explanations[0x01D] = "SBC failure";
    failure_explanations[0x01E] = "SBC failure";
    failure_explanations[0x01F] = "SBC failure";
    failure_explanations[0x020] = "SBC failure";
    failure_explanations[0x021] = "SBC failure";
    failure_explanations[0x022] = "LDA failure";
    failure_explanations[0x023] = "LDA failure";
    failure_explanations[0x024] = "STA failure";
    failure_explanations[0x025] = "LSR failure";
    failure_explanations[0x026] = "LSR failure";
    failure_explanations[0x027] = "ASL failure";
    failure_explanations[0x028] = "ASL failure";
    failure_explanations[0x029] = "ROR failure";
    failure_explanations[0x02A] = "ROR failure";
    failure_explanations[0x02B] = "ROL failure";
    failure_explanations[0x02C] = "ROL failure";
    failure_explanations[0x02D] = "INC failure";
    failure_explanations[0x02E] = "INC failure";
    failure_explanations[0x02F] = "DEC failure";
    failure_explanations[0x030] = "DEC failure";
    failure_explanations[0x031] = "DEC failure";
    failure_explanations[0x032] = "LDX,Y failure";
    failure_explanations[0x033] = "LDX,Y failure";
    failure_explanations[0x034] = "STX,Y failure";
    failure_explanations[0x035] = "STX,Y failure";

    // Absolute,y tests (many codes are duplicated/re-used, overwriting earlier entries)
    failure_explanations[0x036] = "LDA failure";
    failure_explanations[0x037] = "LDA failure to wrap properly from ffffh to 0000h";
    failure_explanations[0x038] = "LDA failure, page cross";
    failure_explanations[0x039] = "ORA failure";
    failure_explanations[0x03A] = "ORA failure";
    failure_explanations[0x03B] = "AND failure";
    failure_explanations[0x03C] = "AND failure";
    failure_explanations[0x03D] = "EOR failure";
    failure_explanations[0x03E] = "EOR failure";
    failure_explanations[0x03F] = "ADC failure";
    failure_explanations[0x040] = "ADC failure";
    failure_explanations[0x041] = "ADC failure";
    failure_explanations[0x042] = "ADC failure";
    failure_explanations[0x043] = "ADC failure";
    failure_explanations[0x044] = "CMP failure";
    failure_explanations[0x045] = "CMP failure";
    failure_explanations[0x046] = "CMP failure";
    failure_explanations[0x047] = "CMP failure";
    failure_explanations[0x048] = "CMP failure";
    failure_explanations[0x049] = "CMP failure";
    failure_explanations[0x04A] = "CMP failure";
    failure_explanations[0x04B] = "SBC failure";
    failure_explanations[0x04C] = "SBC failure";
    failure_explanations[0x04D] = "SBC failure";
    failure_explanations[0x04E] = "SBC failure";
    failure_explanations[0x04F] = "SBC failure";
    failure_explanations[0x050] = "STA failure";

    // Absolute,x tests (many codes are duplicated/re-used, overwriting earlier entries)
    failure_explanations[0x051] = "LDY,X failure";
    failure_explanations[0x052] = "LDY,X failure (didn't page cross)";
    failure_explanations[0x053] = "ORA failure";
    failure_explanations[0x054] = "ORA failure";
    failure_explanations[0x055] = "AND failure";
    failure_explanations[0x056] = "AND failure";
    failure_explanations[0x057] = "EOR failure";
    failure_explanations[0x058] = "EOR failure";
    failure_explanations[0x059] = "ADC failure";
    failure_explanations[0x05A] = "ADC failure";
    failure_explanations[0x05B] = "ADC failure";
    failure_explanations[0x05C] = "ADC failure";
    failure_explanations[0x05D] = "ADC failure";
    failure_explanations[0x05E] = "CMP failure";
    failure_explanations[0x05F] = "CMP failure";
    failure_explanations[0x060] = "CMP failure";
    failure_explanations[0x061] = "CMP failure";
    failure_explanations[0x062] = "CMP failure";
    failure_explanations[0x063] = "CMP failure";
    failure_explanations[0x064] = "CMP failure";
    failure_explanations[0x065] = "SBC failure";
    failure_explanations[0x066] = "SBC failure";
    failure_explanations[0x067] = "SBC failure";
    failure_explanations[0x068] = "SBC failure";
    failure_explanations[0x069] = "SBC failure";
    failure_explanations[0x06A] = "LDA failure";
    failure_explanations[0x06B] = "LDA failure (didn't page cross)";
    failure_explanations[0x06C] = "STA failure";
    failure_explanations[0x06D] = "LSR failure";
    failure_explanations[0x06E] = "LSR failure";
    failure_explanations[0x06F] = "ASL failure";
    failure_explanations[0x070] = "ASL failure";
    failure_explanations[0x071] = "ROR failure";
    failure_explanations[0x072] = "ROR failure";
    failure_explanations[0x073] = "ROL failure";
    failure_explanations[0x074] = "ROL failure";
    failure_explanations[0x075] = "INC failure";
    failure_explanations[0x076] = "INC failure";
    failure_explanations[0x077] = "DEC failure";
    failure_explanations[0x078] = "DEC failure";
    failure_explanations[0x079] = "DEC failure";
    failure_explanations[0x07A] = "LDX,Y failure";
    failure_explanations[0x07B] = "LDX,Y failure";

    // --- Invalid opcode tests (all errors are reported in byte 03h unless specified) ---

    // NOP - "invalid" opcode tests (error byte 02h - these will overwrite some 03h codes)
    // Note: These codes were listed under 'Invalid opcode tests' but explicitly state they are reported in byte 02h.
    // They are inserted *after* all byte 03h specific sections, so they will overwrite if duplicated.
    failure_explanations[0x04E] = "absolute,X NOPs less than 3 bytes long";
    failure_explanations[0x04F] = "implied NOPs affects regs/flags";
    failure_explanations[0x050] = "ZP,X NOPs less than 2 bytes long";
    failure_explanations[0x051] = "absolute NOP less than 3 bytes long";
    failure_explanations[0x052] = "ZP NOPs less than 2 bytes long";
    failure_explanations[0x053] = "absolute,X NOPs less than 3 bytes long";
    failure_explanations[0x054] = "implied NOPs affects regs/flags";
    failure_explanations[0x055] = "ZP,X NOPs less than 2 bytes long";
    failure_explanations[0x056] = "absolute NOP less than 3 bytes long";
    failure_explanations[0x057] = "ZP NOPs less than 2 bytes long";

    // LAX - "invalid" opcode tests (errors reported in byte 03h)
    failure_explanations[0x07C] = "LAX (indr,x) failure"; // Overwrites 0x07C from Zeropage tests
    failure_explanations[0x07D] = "LAX (indr,x) failure"; // Overwrites 0x07D from Zeropage tests
    failure_explanations[0x07E] = "LAX zeropage failure"; // Overwrites 0x07E from Zeropage tests
    failure_explanations[0x07F] = "LAX zeropage failure"; // Overwrites 0x07F from Zeropage tests
    failure_explanations[0x080] = "LAX absolute failure"; // Overwrites 0x080 from Zeropage tests
    failure_explanations[0x081] = "LAX absolute failure"; // Overwrites 0x081 from Zeropage tests
    failure_explanations[0x082] = "LAX (indr),y failure"; // Overwrites 0x082 from Zeropage tests
    failure_explanations[0x083] = "LAX (indr),y failure"; // Overwrites 0x083 from Zeropage tests
    failure_explanations[0x084] = "LAX zp,y failure"; // Overwrites 0x084 from Zeropage tests
    failure_explanations[0x085] = "LAX zp,y failure"; // Overwrites 0x085 from Zeropage tests
    failure_explanations[0x086] = "LAX abs,y failure"; // Overwrites 0x086 from Zeropage tests
    failure_explanations[0x087] = "LAX abs,y failure"; // Overwrites 0x087 from Zeropage tests

    // SAX - "invalid" opcode tests (errors reported in byte 03h)
    failure_explanations[0x088] = "SAX (indr,x) failure"; // Overwrites 0x088 from Zeropage tests
    failure_explanations[0x089] = "SAX (indr,x) failure"; // Overwrites 0x089 from Zeropage tests
    failure_explanations[0x08A] = "SAX zeropage failure"; // Overwrites 0x08A from Zeropage tests
    failure_explanations[0x08B] = "SAX zeropage failure"; // Overwrites 0x08B from Zeropage tests
    failure_explanations[0x08C] = "SAX absolute failure"; // Overwrites 0x08C from Zeropage tests
    failure_explanations[0x08D] = "SAX absolute failure"; // Overwrites 0x08D from Zeropage tests
    failure_explanations[0x08E] = "SAX zp,y failure"; // Overwrites 0x08E from Zeropage tests
    failure_explanations[0x08F] = "SAX zp,y failure"; // Overwrites 0x08F from Zeropage tests

    // SBC - "invalid" opcode test (errors reported in byte 03h)
    failure_explanations[0x090] = "SBC failure"; // Overwrites 0x090 from Zeropage tests
    failure_explanations[0x091] = "SBC failure"; // Overwrites 0x091 from Zeropage tests
    failure_explanations[0x092] = "SBC failure"; // Overwrites 0x092 from Zeropage tests
    failure_explanations[0x093] = "SBC failure"; // Overwrites 0x093 from Zeropage tests
    failure_explanations[0x094] = "SBC failure"; // Overwrites 0x094 from Zeropage tests

    // DCP - "invalid" opcode tests (errors reported in byte 03h)
    failure_explanations[0x095] = "DCP (indr,x) failure"; // Overwrites 0x095 from Zeropage tests
    failure_explanations[0x096] = "DCP (indr,x) failure"; // Overwrites 0x096 from Zeropage tests
    failure_explanations[0x097] = "DCP (indr,x) failure"; // Overwrites 0x097 from Zeropage tests
    failure_explanations[0x098] = "DCP zeropage failure"; // Overwrites 0x098 from Zeropage tests
    failure_explanations[0x099] = "DCP zeropage failure"; // Overwrites 0x099 from Zeropage tests
    failure_explanations[0x09A] = "DCP zeropage failure"; // Overwrites 0x09A from Zeropage tests
    failure_explanations[0x09B] = "DCP absolute failure"; // Overwrites 0x09B from Zeropage tests
    failure_explanations[0x09C] = "DCP absolute failure"; // Overwrites 0x09C from Zeropage tests
    failure_explanations[0x09D] = "DCP absolute failure"; // Overwrites 0x09D from Zeropage tests
    failure_explanations[0x09E] = "DCP (indr),y failure"; // Overwrites 0x09E from Zeropage tests
    failure_explanations[0x09F] = "DCP (indr),y failure"; // Overwrites 0x09F from Zeropage tests
    failure_explanations[0x0A0] = "DCP (indr),y failure"; // Overwrites 0x0A0 from Zeropage tests
    failure_explanations[0x0A1] = "DCP zp,x failure"; // Overwrites 0x0A1 from Zeropage tests
    failure_explanations[0x0A2] = "DCP zp,x failure"; // Overwrites 0x0A2 from Zeropage tests
    failure_explanations[0x0A3] = "DCP zp,x failure"; // Overwrites 0x0A3 from Zeropage tests
    failure_explanations[0x0A4] = "DCP abs,y failure"; // Overwrites 0x0A4 from Zeropage tests
    failure_explanations[0x0A5] = "DCP abs,y failure"; // Overwrites 0x0A5 from Zeropage tests
    failure_explanations[0x0A6] = "DCP abs,y failure"; // Overwrites 0x0A6 from Zeropage tests
    failure_explanations[0x0A7] = "DCP abs,x failure"; // Overwrites 0x0A7 from Zeropage tests
    failure_explanations[0x0A8] = "DCP abs,x failure"; // Overwrites 0x0A8 from Zeropage tests
    failure_explanations[0x0A9] = "DCP abs,x failure"; // Overwrites 0x0A9 from Zeropage tests

    // ISB - "invalid" opcode tests (errors reported in byte 03h)
    failure_explanations[0x0AA] = "DCP (indr,x) failure"; // Overwrites 0x0AA from Zeropage tests. Text says "DCP" but these are ISB opcodes. Following text.
    failure_explanations[0x0AB] = "DCP (indr,x) failure";
    failure_explanations[0x0AC] = "DCP (indr,x) failure";
    failure_explanations[0x0AD] = "DCP zeropage failure";
    failure_explanations[0x0AE] = "DCP zeropage failure";
    failure_explanations[0x0AF] = "DCP zeropage failure";
    failure_explanations[0x0B0] = "DCP absolute failure"; // Overwrites 0x0B0 from Absolute tests
    failure_explanations[0x0B1] = "DCP absolute failure"; // Overwrites 0x0B1 from Absolute tests
    failure_explanations[0x0B2] = "DCP absolute failure"; // Overwrites 0x0B2 from Absolute tests
    failure_explanations[0x0B3] = "DCP (indr),y failure"; // Overwrites 0x0B3 from Absolute tests
    failure_explanations[0x0B4] = "DCP (indr),y failure"; // Overwrites 0x0B4 from Absolute tests
    failure_explanations[0x0B5] = "DCP (indr),y failure"; // Overwrites 0x0B5 from Absolute tests
    failure_explanations[0x0B6] = "DCP zp,x failure"; // Overwrites 0x0B6 from Absolute tests
    failure_explanations[0x0B7] = "DCP zp,x failure"; // Overwrites 0x0B7 from Absolute tests
    failure_explanations[0x0B8] = "DCP zp,x failure"; // Overwrites 0x0B8 from Absolute tests
    failure_explanations[0x0B9] = "DCP abs,y failure"; // Overwrites 0x0B9 from Absolute tests
    failure_explanations[0x0BA] = "DCP abs,y failure"; // Overwrites 0x0BA from Absolute tests
    failure_explanations[0x0BB] = "DCP abs,y failure"; // Overwrites 0x0BB from Absolute tests
    failure_explanations[0x0BC] = "DCP abs,x failure"; // Overwrites 0x0BC from Absolute tests
    failure_explanations[0x0BD] = "DCP abs,x failure"; // Overwrites 0x0BD from Absolute tests
    failure_explanations[0x0BE] = "DCP abs,x failure"; // Overwrites 0x0BE from Absolute tests

    // SLO - "invalid" opcode tests (errors reported in byte 03h)
    failure_explanations[0x0BF] = "SLO (indr,x) failure"; // Overwrites 0x0BF from Absolute tests
    failure_explanations[0x0C0] = "SLO (indr,x) failure"; // Overwrites 0x0C0 from Absolute tests
    failure_explanations[0x0C1] = "SLO (indr,x) failure"; // Overwrites 0x0C1 from Absolute tests
    failure_explanations[0x0C2] = "SLO zeropage failure"; // Overwrites 0x0C2 from Absolute tests
    failure_explanations[0x0C3] = "SLO zeropage failure"; // Overwrites 0x0C3 from Absolute tests
    failure_explanations[0x0C4] = "SLO zeropage failure"; // Overwrites 0x0C4 from Absolute tests
    failure_explanations[0x0C5] = "SLO absolute failure"; // Overwrites 0x0C5 from Absolute tests
    failure_explanations[0x0C6] = "SLO absolute failure"; // Overwrites 0x0C6 from Absolute tests
    failure_explanations[0x0C7] = "SLO absolute failure"; // Overwrites 0x0C7 from Absolute tests
    failure_explanations[0x0C8] = "SLO (indr),y failure"; // Overwrites 0x0C8 from Absolute tests
    failure_explanations[0x0C9] = "SLO (indr),y failure"; // Overwrites 0x0C9 from Absolute tests
    failure_explanations[0x0CA] = "SLO (indr),y failure"; // Overwrites 0x0CA from Absolute tests
    failure_explanations[0x0CB] = "SLO zp,x failure"; // Overwrites 0x0CB from Absolute tests
    failure_explanations[0x0CC] = "SLO zp,x failure"; // Overwrites 0x0CC from Absolute tests
    failure_explanations[0x0CD] = "SLO zp,x failure"; // Overwrites 0x0CD from Absolute tests
    failure_explanations[0x0CE] = "SLO abs,y failure"; // Overwrites 0x0CE from Absolute tests
    failure_explanations[0x0CF] = "SLO abs,y failure"; // Overwrites 0x0CF from Absolute tests
    failure_explanations[0x0D0] = "SLO abs,y failure"; // Overwrites 0x0D0 from Absolute tests
    failure_explanations[0x0D1] = "SLO abs,x failure"; // Overwrites 0x0D1 from Absolute tests
    failure_explanations[0x0D2] = "SLO abs,x failure"; // Overwrites 0x0D2 from Absolute tests
    failure_explanations[0x0D3] = "SLO abs,x failure"; // Overwrites 0x0D3 from Absolute tests

    // RLA - "invalid" opcode tests (errors reported in byte 03h)
    failure_explanations[0x0D4] = "RLA (indr,x) failure"; // Overwrites 0x0D4 from Absolute tests
    failure_explanations[0x0D5] = "RLA (indr,x) failure"; // Overwrites 0x0D5 from Absolute tests
    failure_explanations[0x0D6] = "RLA (indr,x) failure"; // Overwrites 0x0D6 from Absolute tests
    failure_explanations[0x0D7] = "RLA zeropage failure"; // Overwrites 0x0D7 from Absolute tests
    failure_explanations[0x0D8] = "RLA zeropage failure"; // Overwrites 0x0D8 from Absolute tests
    failure_explanations[0x0D9] = "RLA zeropage failure"; // Overwrites 0x0D9 from Absolute tests
    failure_explanations[0x0DA] = "RLA absolute failure"; // Overwrites 0x0DA from Absolute tests
    failure_explanations[0x0DB] = "RLA absolute failure"; // Overwrites 0x0DB from Absolute tests
    failure_explanations[0x0DC] = "RLA absolute failure"; // Overwrites 0x0DC from Absolute tests
    failure_explanations[0x0DD] = "RLA (indr),y failure"; // Overwrites 0x0DD from Absolute tests
    failure_explanations[0x0DE] = "RLA (indr),y failure"; // Overwrites 0x0DE from Absolute tests
    failure_explanations[0x0DF] = "RLA (indr),y failure"; // Overwrites 0x0DF from Absolute tests
    failure_explanations[0x0E0] = "RLA zp,x failure"; // Overwrites 0x0E0 from Absolute tests
    failure_explanations[0x0E1] = "RLA zp,x failure"; // Overwrites 0x0E1 from Absolute tests
    failure_explanations[0x0E2] = "RLA zp,x failure"; // Overwrites 0x0E2 from Absolute tests
    failure_explanations[0x0E3] = "RLA abs,y failure"; // Overwrites 0x0E3 from Absolute tests
    failure_explanations[0x0E4] = "RLA abs,y failure"; // Overwrites 0x0E4 from Absolute tests
    failure_explanations[0x0E5] = "RLA abs,y failure"; // Overwrites 0x0E5 from Absolute tests
    failure_explanations[0x0E6] = "RLA abs,x failure"; // Overwrites 0x0E6 from Absolute tests
    failure_explanations[0x0E7] = "RLA abs,x failure"; // Overwrites 0x0E7 from Absolute tests
    failure_explanations[0x0E8] = "RLA abs,x failure"; // Overwrites 0x0E8 from Absolute tests

    // SRE - "invalid" opcode tests (errors reported in byte 03h)
    // Note: 0xE8 is again duplicated from RLA, SRE, and also earlier Absolute tests.
    // The sequence is not strictly increasing across all invalid opcode tests.
    failure_explanations[0x0E8] = "SRE (indr,x) failure";
    failure_explanations[0x0EA] = "SRE (indr,x) failure"; // Overwrites 0x0EA from (indirect),y tests
    failure_explanations[0x0EB] = "SRE (indr,x) failure"; // Overwrites 0x0EB from (indirect),y tests
    failure_explanations[0x0EC] = "SRE zeropage failure"; // Overwrites 0x0EC from (indirect),y tests
    failure_explanations[0x0ED] = "SRE zeropage failure"; // Overwrites 0x0ED from (indirect),y tests
    failure_explanations[0x0EE] = "SRE zeropage failure"; // Overwrites 0x0EE from (indirect),y tests
    failure_explanations[0x0EF] = "SRE absolute failure"; // Overwrites 0x0EF from (indirect),y tests
    failure_explanations[0x0F0] = "SRE absolute failure"; // Overwrites 0x0F0 from (indirect),y tests
    failure_explanations[0x0F1] = "SRE absolute failure"; // Overwrites 0x0F1 from (indirect),y tests
    failure_explanations[0x0F2] = "SRE (indr),y failure"; // Overwrites 0x0F2 from (indirect),y tests
    failure_explanations[0x0F3] = "SRE (indr),y failure"; // Overwrites 0x0F3 from (indirect),y tests
    failure_explanations[0x0F4] = "SRE (indr),y failure"; // Overwrites 0x0F4 from (indirect),y tests
    failure_explanations[0x0F5] = "SRE zp,x failure"; // Overwrites 0x0F5 from (indirect),y tests
    failure_explanations[0x0F6] = "SRE zp,x failure"; // Overwrites 0x0F6 from (indirect),y tests
    failure_explanations[0x0F7] = "SRE zp,x failure"; // Overwrites 0x0F7 from (indirect),y tests
    failure_explanations[0x0F8] = "SRE abs,y failure"; // Overwrites 0x0F8 from (indirect),y tests
    failure_explanations[0x0F9] = "SRE abs,y failure"; // Overwrites 0x0F9 from (indirect),y tests
    failure_explanations[0x0FA] = "SRE abs,y failure"; // Overwrites 0x0FA from (indirect),y tests
    failure_explanations[0x0FB] = "SRE abs,x failure"; // Overwrites 0x0FB from (indirect),y tests
    failure_explanations[0x0FC] = "SRE abs,x failure"; // Overwrites 0x0FC from (indirect),y tests
    failure_explanations[0x0FD] = "SRE abs,x failure"; // Overwrites 0x0FD from (indirect),y tests

    // RRA - "invalid" opcode tests (errors reported in byte 03h)
    // These entries will overwrite some of the previously assigned codes from the 03h category.
    failure_explanations[0x001] = "RRA (indr,x) failure";
    failure_explanations[0x002] = "RRA (indr,x) failure";
    failure_explanations[0x003] = "RRA (indr,x) failure";
    failure_explanations[0x004] = "RRA zeropage failure";
    failure_explanations[0x005] = "RRA zeropage failure";
    failure_explanations[0x006] = "RRA zeropage failure";
    failure_explanations[0x007] = "RRA absolute failure";
    failure_explanations[0x008] = "RRA absolute failure";
    failure_explanations[0x009] = "RRA absolute failure";
    failure_explanations[0x00A] = "RRA (indr),y failure";
    failure_explanations[0x00B] = "RRA (indr),y failure";
    failure_explanations[0x00C] = "RRA (indr),y failure";
    failure_explanations[0x00D] = "RRA zp,x failure";
    failure_explanations[0x00E] = "RRA zp,x failure";
    failure_explanations[0x00F] = "RRA zp,x failure";
    failure_explanations[0x010] = "RRA abs,y failure";
    failure_explanations[0x011] = "RRA abs,y failure";
    failure_explanations[0x012] = "RRA abs,y failure";
    failure_explanations[0x013] = "RRA abs,x failure";
    failure_explanations[0x014] = "RRA abs,x failure";
    failure_explanations[0x015] = "RRA abs,x failure";

    // The final blank entries (001h-010h) are omitted as they seem to be
    // formatting errors or unfinished templates, and would overwrite
    // more descriptive error messages.
}

// get_test_failure_explanation takes a test failure code as a hexadecimal
// string (e.g., "001h", "07Fh") and returns its corresponding explanation
// as a string. If the code is not found, it returns an "Unknown" message.
// get_test_failure_explanation :: proc(failure_code_hex_string: string) -> string {
//     // Remove "h" suffix if present to prepare for parsing
//     code_str := strings.trim_suffix(failure_code_hex_string, "h");

//     // Parse the hexadecimal string to a u16 integer.
//     // Handles potential parsing errors.
//     code, err := strconv.parse_uint(code_str, 16, 16);
//     if err != nil {
//         return fmt.aprintf("Error parsing failure code '%s': %s", failure_code_hex_string, err);
//     }

//     // Look up the explanation in the pre-populated map.
//     // `u16(code)` casts the parsed uint to u16 for map lookup.
//     explanation, ok := failure_explanations[u16(code)];
//     if ok {
//         return explanation;
//     } else {
//         // If the code is not found in the map
//         return fmt.aprintf("Unknown test failure code: %s", failure_code_hex_string);
//     }
// }

// main function to demonstrate the usage of get_test_failure_explanation.
// It includes a few example failure codes to test the function.
// main :: proc() {
//     using fmt;
//     // The `populate_failure_explanations` proc will automatically run due to @(init)
//     // but calling it explicitly here for clarity in a simple example.
//     populate_failure_explanations();

//     // Example test codes
//     codes := []string{
//         "000h",   // Should be "no error, all tests pass" (from 03h)
//         "001h",   // Should be "RRA (indr,x) failure" (overwritten multiple times)
//         "011h",   // Should be "ADC failure" (from zeropage,x tests)
//         "03Dh",   // Should be "EOR failure" (from absolute,y tests)
//         "075h",   // Should be "INC failure" (from absolute,x tests)
//         "0B4h",   // Should be "DCP (indr),y failure" (from ISB invalid opcodes)
//         "07Ch",   // Should be "LAX (indr,x) failure" (from LAX invalid opcodes)
//         "0F0h",   // Should be "SRE absolute failure" (from SRE invalid opcodes)
//         "100h",   // An unknown code
//         "invalid" // An unparsable string
//     };

//     println("--- NES CPU Test Failure Code Explanations ---");
//     for code in codes {
//         println(code, ": ", get_test_failure_explanation(code));
//     }
// }

