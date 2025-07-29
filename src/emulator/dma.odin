package emulator

DMA :: struct {
	cycle_count:         u64,
	halt_cycle:          bool,
	oam_page:            u8,
	oam_addr:            u8,
	oam_data:            u8,
	oam_alignment_cycle: bool,
	oam_state:           DMA_State,
	dmc_state:           DMA_State,
	dmc_schedule_count:  int,
	dmc_dummy_cycle:     bool,
	dmc_alignment_cycle: bool,
}

DMA_State :: enum {
	Inactive,
	Schedule,
	Transfer,
	Complete,
}

dma_initialize :: proc(dma: ^DMA) {
	dma^ = DMA{}
}

dma_query_dmc_state_complete :: proc(dma: ^DMA) -> bool {
	complete := dma.dmc_state == .Complete
	if complete {
		dma.dmc_state = .Inactive
	}

	return complete
}

dma_query_oam_state_complete :: proc(dma: ^DMA) -> bool {
	complete := dma.oam_state == .Complete
	if complete {
		dma.oam_state = .Inactive
	}

	return complete
}

dma_schedule_oam_transfer :: proc(dma: ^DMA, page: u8) -> bool {
	if dma.oam_state == .Inactive {
		reset(dma)
		dma.oam_state = .Schedule
		dma.oam_page = page
		return true
	}

	return false

	reset :: proc(dma: ^DMA) {
		dma.oam_addr = 0
		dma.oam_alignment_cycle = true
		if dma.dmc_state != .Transfer {
			dma.halt_cycle = true
		}
	}
}

dma_schedule_dmc_transfer :: proc(dma: ^DMA) -> bool {
	if dma.dmc_state == .Inactive {
		reset(dma)
		dma.dmc_state = .Schedule
		if is_apu_clk1(dma.cycle_count) {
			dma.dmc_schedule_count = 3
		}

		if is_apu_clk2(dma.cycle_count) {
			dma.dmc_schedule_count = 4
		}

		return true

	}

	return false

	reset :: proc(dma: ^DMA) {
		dma.dmc_dummy_cycle = true
		dma.dmc_alignment_cycle = true
		if dma.oam_state != .Transfer {
			dma.halt_cycle = true
		}
	}
}

@(require_results)
dma_execute_clk_cycle :: proc(c: ^Console) -> (halt_cpu: bool) {
	dma := &c.dma
	dmc_active: bool // OAM DMA cannot operate while DMC DMA is active
	defer dma.cycle_count += 1

	dmc_state_update: {
		if dma.dmc_state == .Schedule {
			dma.dmc_schedule_count -= 1
			if dma.dmc_schedule_count <= 0 {
				if cpu_get_last_executed_cycle_type(c.cpu) == .Read {
					dma.dmc_state = .Transfer
				}
			}
		}
	}

	oam_state_update: {
		if dma.oam_state == .Schedule {
			if cpu_get_last_executed_cycle_type(c.cpu) == .Read {
				dma.oam_state = .Transfer
			}
		}

	}

	dmc_execute: if dma.dmc_state == .Transfer {
		halt_cpu = true
		if dma.halt_cycle {
			dma.halt_cycle = false
			break dmc_execute
		}

		dmc_active = true
		if dma.dmc_dummy_cycle {
			dma.dmc_dummy_cycle = false
			break dmc_execute
		}

		if dma.dmc_alignment_cycle {
			dma.dmc_alignment_cycle = false
			if is_apu_clk2(dma.cycle_count) {
				break dmc_execute
			}
		}

		dmc := &c.apu.dmc
		dmc.sample_buffer, _ = console_read_from_address(c, dmc.reader_current_addr)
		dmc.sample_buffer_empty = false

		dma.dmc_state = .Complete
	}

	oam_execute: if dma.oam_state == .Transfer {
		halt_cpu = true
		if dma.halt_cycle {
			dma.halt_cycle = false
			break oam_execute
		}

		if dmc_active {
			dma.oam_alignment_cycle = true
			break oam_execute
		}

		if dma.oam_alignment_cycle {
			dma.oam_alignment_cycle = false
			// DMA can only read in read get cycles (apu_clk1) so
			// clear dummy read flag if next cycle is apu_clk1
			if is_apu_clk2(dma.cycle_count) {
				break oam_execute
			}
		}

		if is_apu_clk1(dma.cycle_count) {
			// read on get cycle
			addr := u16(dma.oam_page) << 8 | u16(dma.oam_addr)
			dma.oam_data, _ = console_read_from_address(c, addr)
		}

		if is_apu_clk2(dma.cycle_count) {
			// write on put cycle
			ppu_oam_write_to_address(&c.ppu, dma.oam_data, dma.oam_addr)
			dma.oam_addr += 1

			if dma.oam_addr == 0x0 {
				dma.oam_state = .Complete
			}
		}
	}

	return
}

// @note clk1 is assumed to be even cpu clock cycles and clk2 uneven.
// This is not technically correct since the NES CPU and APU can
// power into either of 2 alginments relative to each other. However,
// this emulator have both start at 0.
@(require_results, private = "file")
is_apu_clk1 :: proc(#any_int cycle_count: u64) -> bool {
	return cycle_count & 0x1 == 0
}

@(require_results, private = "file")
is_apu_clk2 :: proc(#any_int cycle_count: u64) -> bool {
	return cycle_count & 0x1 == 1
}

