package emulator

import "base:runtime"
import "core:math"

@(private = "file")
apu_default_opts := APU_Options {
	mixing_stratergy = APU_Mixing_Linear_Approximation{1, 1, 1, 1, 1},
}

APU :: struct {
	frame_reg:                    bit_field u8 {
		_unused:          u8   | 6,
		irq_inhibit_flag: bool | 1,
		sequence_mode:    uint | 1,
	},
	frame_interrupt:              bool,
	frame_count:                  u64,
	cycle_count:                  u64,
	pulse1:                       Pulse_Channel,
	pulse2:                       Pulse_Channel,
	triangle:                     Triangle_Channel,
	noise:                        Noise_Channel,
	dmc:                          DMC,
	// internal
	audio_time_per_system_sample: f64,
	audio_time_per_apu_clk:       f64,
	audio_time:                   f64,
	sample_buf:                   [dynamic]f64,
	opts:                         APU_Options,
}

Pulse_Channel :: struct {
	enable:                bool,
	ctrl_reg:              bit_field u8 {
		value:           u8   | 4, // volume/envelope
		constant_volume: bool | 1,
		flag:            bool | 1, // envelope loop/length counter halt
		duty:            u8   | 2,
	},
	sweep_reg:             bit_field u8 {
		shift:  u8   | 3,
		negate: bool | 1,
		value:  u8   | 3,
		enable: bool | 1,
	},
	timer_period:          u16, // 11 bits
	// --- Internal state variables
	timer_value:           u16,
	sequence_index:        u8,
	sequence_output:       u8,
	length_counter_value:  u8,
	// envelope
	env_decay_level_count: u8,
	env_divider_reset:     bool,
	env_divider_value:     u8,
	env_output:            u8,
	// sweep 
	sweep_target_period:   u16,
	sweep_negate_two_comp: bool,
	sweep_divider_reset:   bool,
	sweep_divider_value:   u8,
}

Triangle_Channel :: struct {
	enable:               bool,
	ctrl_reg:             bit_field u8 {
		linear_counter_load: u8   | 7,
		flag:                bool | 1, // linear counter ctrl/length counter halt
	},
	timer_period:         u16,
	// --- Internal state variables
	timer_value:          u16,
	sequence_index:       u8,
	sequence_output:      u8,
	length_counter_value: u8,
	linear_counter_reset: bool,
	linear_counter_value: u8,
}

Noise_Channel :: struct {
	enable:                 bool,
	ctrl_reg:               bit_field u8 {
		value:           u8   | 4, // volume/envelope
		constant_volume: bool | 1,
		flag:            bool | 1, // envelope loop/length counter halt
		_unused:         u8   | 2,
	},
	noise_reg:              bit_field u8 {
		period:    u8   | 4,
		_unused:   u8   | 3,
		mode_flag: bool | 1,
	},
	// timer_period:          u16, // 11 bits
	// --- Internal state variables
	feedback_shifter_value: u16, // 15 bits
	timer_value:            u16,
	// sequence_index:        u8,
	// sequence_output:       u8,
	length_counter_value:   u8,
	// envelope
	env_decay_level_count:  u8,
	env_divider_reset:      bool,
	env_divider_value:      u8,
	env_output:             u8,
}

DMC :: struct {
	enable:                 bool,
	ctrl_reg:               bit_field u8 {
		rate_index: u8   | 4,
		_unused:    u8   | 2,
		loop:       bool | 1,
		irq_enable: bool | 1,
	},
	load_counter:           u8,
	sample_address:         u16,
	sample_length:          u16,
	// --- Internal state variables
	sample_buffer:          u8,
	sample_buffer_empty:    bool,
	timer_value:            u16,
	interrupt:              bool,
	dma_transfer:           bool,
	dma_transfer_mode:      enum {
		Load,
		Reload,
	},
	// memory reader unit
	reader_current_addr:    u16,
	reader_current_length:  u16,
	// output unit
	output_silence:         bool,
	output_shifter_value:   u8,
	ouput_shifter_bits_rem: u8,
	output_level:           u8,
}

APU_Options :: struct {
	mixing_stratergy: union #no_nil {
		APU_Mixing_Lookup_Table,
		APU_Mixing_Linear_Approximation,
	},
}

APU_Mixing_Lookup_Table :: struct {
}

APU_Mixing_Linear_Approximation :: struct {
	pulse1_vol:   f64,
	pulse2_vol:   f64,
	triangle_vol: f64,
	noise_vol:    f64,
	dmc_vol:      f64,
}

apu_make :: proc(
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	apu: APU,
	err: runtime.Allocator_Error,
) {
	apu.sample_buf = make_dynamic_array([dynamic]f64, allocator, loc) or_return
	return
}

apu_delete :: proc(
	apu: APU,
	allocator := context.allocator,
	loc := #caller_location,
) -> runtime.Allocator_Error {
	context.allocator = allocator
	delete_dynamic_array(apu.sample_buf, loc) or_return
	return nil
}

apu_set_options :: proc(apu: ^APU, opts: APU_Options) {
	switch &v in opts.mixing_stratergy {
	case APU_Mixing_Lookup_Table:
	case APU_Mixing_Linear_Approximation:
		assert_range(v.pulse1_vol)
		assert_range(v.pulse2_vol)
		assert_range(v.triangle_vol)
		assert_range(v.noise_vol)
		assert_range(v.dmc_vol)
	}

	apu.opts = opts

	assert_range :: proc(vol: f64) {
		assert(vol >= 0 && vol <= 1)
	}
}

apu_initialize :: proc(apu: ^APU, #any_int sample_rate: uint, opts := apu_default_opts) {
	a := APU{}

	a.opts = opts

	a.audio_time_per_system_sample = 1.0 / f64(sample_rate)
	a.audio_time_per_apu_clk = 1.0 / 5369318.0 // ppu/apu clk freq

	// The sweep unit of pulse channel 1 and 2 negate the period using
	// one's respectively two's complement.
	a.pulse1.sweep_negate_two_comp = false
	a.pulse2.sweep_negate_two_comp = true

	// @note Not setting irq inhibit flag on startup causes issues
	// in Super Mario Bros, and probably more games.
	a.frame_reg.irq_inhibit_flag = true

	a.noise.feedback_shifter_value = 1


	apu^ = a
}

apu_query_sample :: proc(apu: ^APU) -> (sample: f64) {
	sample = math.sum(apu.sample_buf[:]) / f64(len(apu.sample_buf))
	clear_dynamic_array(&apu.sample_buf)
	return
}

apu_execute_clk_cycle :: proc(apu: ^APU, dma: ^DMA) -> (sample_complete: bool, trigger_irq: bool) {
	apu.audio_time += apu.audio_time_per_apu_clk
	if apu.audio_time >= apu.audio_time_per_system_sample {
		apu.audio_time -= apu.audio_time_per_system_sample
		sample_complete = true
	}

	defer {
		apu.cycle_count += 1
		if apu.dmc.interrupt do trigger_irq = true
		if apu.frame_interrupt do trigger_irq = true
	}

	pulse_channel_console_clk(&apu.pulse1)
	pulse_channel_console_clk(&apu.pulse2)
	delta_modulation_channel_console_clk(&apu.dmc, dma)


	// update once per CPU clock cycle
	if apu.cycle_count % 3 == 0 {
		triangle_channel_cpu_clk(&apu.triangle)
	}

	// update once per apu cycle (cpu_cycle / 2 <=> ppu_cycle / 6)
	if apu.cycle_count % 6 == 0 {
		_, half_frame, quater_frame := execute_frame_sequence(apu)

		pulse_channel_apu_clk(&apu.pulse1, quater_frame, half_frame)
		pulse_channel_apu_clk(&apu.pulse2, quater_frame, half_frame)
		noise_channel_apu_clk(&apu.noise, quater_frame, half_frame)
		triangle_channel_apu_clk(&apu.triangle, quater_frame, half_frame)
		delta_modulation_channel_apu_clk(&apu.dmc, quater_frame, half_frame)

		pulse1_sample := get_pulse_channel_output(apu.pulse1)
		pulse2_sample := get_pulse_channel_output(apu.pulse2)
		triangle_sample := get_triangle_channel_output(apu.triangle)
		noise_sample := get_noise_channel_output(apu.noise)
		dmc_sample := get_delta_modulation_channel_output(apu.dmc)

		pulse_out, tnd_out: f64
		switch v in apu.opts.mixing_stratergy {
		case APU_Mixing_Lookup_Table:
			pulse_out = f64(apu_mixer_pulse_table[pulse1_sample + pulse2_sample])
			tnd_out = apu_mixer_tnd_table[3 * triangle_sample + 2 * noise_sample + dmc_sample]
		case APU_Mixing_Linear_Approximation:
			pulse_out =
				0.00752 * (f64(pulse1_sample) * v.pulse1_vol + f64(pulse2_sample) * v.pulse2_vol)
			tnd_out =
				0.00851 * f64(triangle_sample) * v.triangle_vol +
				0.00494 * f64(noise_sample) * v.noise_vol +
				0.00335 * f64(dmc_sample) * v.dmc_vol
		}

		sample_out := pulse_out + tnd_out

		append_elem(&apu.sample_buf, sample_out)
	}

	return

	execute_frame_sequence :: proc(apu: ^APU) -> (frame, half_frame, quater_frame: bool) {
		defer apu.frame_count += 1

		if apu.frame_reg.sequence_mode == 0 {
			// 4 step sequence
			if apu.frame_count == 3729 {
				quater_frame = true
			}

			if apu.frame_count == 7457 {
				quater_frame = true
				half_frame = true
			}

			if apu.frame_count == 11186 {
				quater_frame = true
			}

			if apu.frame_count == 14915 {
				if !apu.frame_reg.irq_inhibit_flag {
					apu.frame_interrupt = true
				}

				quater_frame = true
				half_frame = true
				frame = true
				apu.frame_count = 0
			}
		} else {
			// 5 step sequence
			if apu.frame_count == 3729 {
				quater_frame = true
			}

			if apu.frame_count == 7457 {
				quater_frame = true
				half_frame = true
			}

			if apu.frame_count == 11186 {
				quater_frame = true
			}

			if apu.frame_count == 14915 {
				// do nothing
			}

			if apu.frame_count == 18641 {
				quater_frame = true
				half_frame = true
				frame = true
				apu.frame_count = 0
			}
		}

		return
	}
}

apu_write_to_address :: proc(apu: ^APU, data: u8, address: u16) {
	switch address {
	case 0x4000:
		// pulse 1 control
		apu.pulse1.ctrl_reg = auto_cast data
	case 0x4001:
		// pulse 1 sweep
		apu.pulse1.sweep_reg = auto_cast data
		apu.pulse1.sweep_divider_reset = true // side effect
	case 0x4002:
		// pulse 1 timer low
		apu.pulse1.timer_period = (apu.pulse1.timer_period & 0xff00) | u16(data)
	case 0x4003:
		// pulse 1 length counter, timer high
		apu.pulse1.timer_period = (u16(data & 0x07) << 8) | (apu.pulse1.timer_period & 0x00ff)
		apu.pulse1.length_counter_value = apu_length_counter_table[data >> 3]
		apu.pulse1.env_divider_reset = true // side effect
		apu.pulse1.sequence_index = 0 // reset phase (side efffect)
	case 0x4004:
		// pulse 2 control
		apu.pulse2.ctrl_reg = auto_cast data
	case 0x4005:
		// pulse 2 sweep
		apu.pulse2.sweep_reg = auto_cast data
		apu.pulse2.sweep_divider_reset = true // side effect
	case 0x4006:
		// pulse 2 timer low
		apu.pulse2.timer_period = (apu.pulse2.timer_period & 0xff00) | u16(data)
	case 0x4007:
		// pulse 2 length counter, timer high
		apu.pulse2.timer_period = (u16(data & 0x07) << 8) | (apu.pulse2.timer_period & 0x00ff)
		apu.pulse2.length_counter_value = apu_length_counter_table[data >> 3]
		apu.pulse2.env_divider_reset = true // side effect
		apu.pulse2.sequence_index = 0 // reset phase (side efffect)
	case 0x4008:
		// triangle control
		apu.triangle.ctrl_reg = auto_cast data
	case 0x4009:
	// unused
	case 0x400a:
		// triangle timer low
		apu.triangle.timer_period = (apu.triangle.timer_period & 0xff00) | u16(data)
	case 0x400b:
		// triangle length counter, timer high
		apu.triangle.timer_period = (u16(data & 0x07) << 8) | (apu.triangle.timer_period & 0x00ff)
		apu.triangle.length_counter_value = apu_length_counter_table[data >> 3]
		apu.triangle.linear_counter_reset = true // side effect
	case 0x400c:
		// noise control
		apu.noise.ctrl_reg = auto_cast data
	case 0x400d:
	// unused
	case 0x400e:
		// noise mode, period
		apu.noise.noise_reg = auto_cast data
	case 0x400f:
		// noise length counter
		apu.noise.length_counter_value = apu_length_counter_table[data >> 3]
	case 0x4010:
		// DMC control
		apu.dmc.ctrl_reg = auto_cast data
		apu.dmc.timer_value = apu_dmc_rate_table[apu.dmc.ctrl_reg.rate_index]
	case 0x4011:
		// DMC load counter
		apu.dmc.output_level = data & 0x7f // output level is 7 bits
	case 0x4012:
		// DMC sample address
		// sample address = b11AAAAAA.AA000000
		apu.dmc.sample_address = 0xc000 | (u16(data) << 6)
		apu.dmc.reader_current_addr = apu.dmc.sample_address
	case 0x4013:
		// DMC sample length
		// sample length = b0000LLLL.LLLL0001
		apu.dmc.sample_length = (u16(data) << 4) | 1
		apu.dmc.reader_current_length = apu.dmc.sample_length
	case 0x4015:
		// status
		apu.pulse1.enable = data & 0x01 > 0
		apu.pulse2.enable = data & 0x02 > 0
		apu.triangle.enable = data & 0x04 > 0
		apu.noise.enable = data & 0x08 > 0
		apu.dmc.enable = data & 0x10 > 0

		// side effects
		apu.dmc.interrupt = false
	case 0x4017:
		// APU frame counter
		apu.frame_reg = auto_cast data
		// @todo writing has quite a few more side effects on the frame
		// counter seqeunce
		apu.frame_count = 0
		if apu.frame_reg.irq_inhibit_flag do apu.frame_interrupt = false
	case:
		panic("address not handled by APU")
	}
}

apu_read_from_address :: proc(apu: ^APU, address: u16) -> (data: u8, err: Maybe(Error)) {
	switch address {
	case 0x4000 ..< 0x4014:
		err = errorf(
			.Memory_Error,
			"cannot read from %$04X, APU channel registers ($4000-$4013) are write-only",
			address,
			severity = .Warning,
		)
	case 0x4015:
		data =
			(u8(apu.dmc.interrupt) << 7) +
			(u8(apu.frame_interrupt) << 6) +
			(u8(apu.dmc.reader_current_length > 0) << 4) +
			(u8(apu.noise.length_counter_value > 0) << 3) +
			(u8(apu.triangle.length_counter_value > 0) << 2) +
			(u8(apu.pulse1.length_counter_value > 0) << 1) +
			(u8(apu.pulse1.length_counter_value > 0))
		apu.frame_interrupt = false
	case:
		panic("address not handled by APU")
	}

	return
}

@(private = "file")
get_delta_modulation_channel_output :: proc(d: DMC) -> u8 {
	return d.output_level
}


@(private = "file")
delta_modulation_channel_console_clk :: proc(d: ^DMC, dma: ^DMA) {
	if !d.enable {
		d.sample_length = 0
	}

	if d.sample_buffer_empty && d.reader_current_length > 0 {
		// sample_buffer will be filled by dma transfer
		dma_schedule_dmc_transfer(dma)
	}

	if dma_query_dmc_state_complete(dma) {
		d.reader_current_addr += 1
		if d.reader_current_addr == 0 do d.reader_current_addr = 0x8000

		if d.reader_current_length > 0 {
			d.reader_current_length -= 1
		}

		if d.enable && d.reader_current_length == 0 {
			if d.ctrl_reg.loop {
				// restart
				// d.dma_transfer_mode = .Load
				d.reader_current_addr = d.sample_address
				d.reader_current_length = d.sample_length
			} else {
				if d.ctrl_reg.irq_enable {
					d.interrupt = true
				}
			}
		}
	}

	return
}

@(private = "file")
delta_modulation_channel_apu_clk :: proc(d: ^DMC, quater_frame, half_frame: bool) // dma_transfer: bool,
{
	if d.timer_value > 0 {
		d.timer_value -= 1
	} else {
		d.timer_value = apu_dmc_rate_table[d.ctrl_reg.rate_index]

		step_output: {
			if !d.output_silence {
				// increment or decrement output level
				if d.output_shifter_value & 0x01 == 1 {
					if d.output_level <= 125 do d.output_level += 2
				} else {
					if d.output_level >= 2 do d.output_level -= 2
				}
			}

			d.output_shifter_value >>= 1

			d.ouput_shifter_bits_rem -= 1
			if d.ouput_shifter_bits_rem == 0 {
				// start new output cycle
				d.ouput_shifter_bits_rem = 8
				if d.sample_buffer_empty {
					d.output_silence = true
				} else {
					d.output_silence = false
					// empty sample buffer info shifter
					d.output_shifter_value = d.sample_buffer
					d.sample_buffer_empty = true
					// if d.reader_current_length > 0 {
					// 	dma_transfer = true
					// }
				}
			}
		}
	}
}

@(private = "file")
get_noise_channel_output :: proc(n: Noise_Channel) -> u8 {
	if !should_mute(n) {
		return n.env_output
	} else {
		return 0
	}

	should_mute :: proc(n: Noise_Channel) -> bool {
		if !n.enable {
			return true
		}

		if n.length_counter_value <= 0 {
			return true
		}

		if n.feedback_shifter_value & 0x1 == 0x1 {
			return true
		}

		return false
	}
}

@(private = "file")
noise_channel_apu_clk :: proc(n: ^Noise_Channel, quater_frame, half_frame: bool) {
	if quater_frame {
		update_envelope: {
			// Both the envelope and sweep use an identical divider circuit to
			// allow for variable execution frequency.
			if !n.env_divider_reset {
				n.env_divider_value -= 1
				if n.env_divider_value == 0xff {
					n.env_divider_value = n.ctrl_reg.value
					// Decrement decay level counter when divider reaches
					// zero and reset if loop flag set.
					if n.env_decay_level_count > 0 {
						n.env_decay_level_count -= 1
					} else if n.ctrl_reg.flag {
						n.env_decay_level_count = 0x0f
					}
				}
			} else {
				n.env_divider_reset = false
				n.env_decay_level_count = 0x0f
				n.env_divider_value = n.ctrl_reg.value
			}

			if !n.ctrl_reg.constant_volume {
				n.env_output = n.env_decay_level_count
			} else {
				n.env_output = n.ctrl_reg.value
			}
		}
	}

	if half_frame {
		update_length_counter: if n.enable {
			if n.length_counter_value > 0 && !n.ctrl_reg.flag {
				n.length_counter_value -= 1
			}
		} else {
			n.length_counter_value = 0
		}
	}

	update_timer: if n.timer_value > 0 {
		n.timer_value -= 1
	} else {
		n.timer_value = apu_noise_period_table[n.noise_reg.period]
		feedback: u16
		if n.noise_reg.mode_flag {
			// xor bit 0 and 6
			feedback = (n.feedback_shifter_value & 0x1) ~ ((n.feedback_shifter_value >> 6) & 0x1)
		} else {
			// xor bit 0 and 1
			feedback = (n.feedback_shifter_value & 0x1) ~ ((n.feedback_shifter_value >> 1) & 0x1)
		}

		n.feedback_shifter_value >>= 1
		n.feedback_shifter_value = (n.feedback_shifter_value & 0x3fff) | feedback << 14
	}
}

@(private = "file")
get_triangle_channel_output :: proc(t: Triangle_Channel) -> u8 {
	return t.sequence_output
}

@(private = "file")
triangle_channel_cpu_clk :: proc(t: ^Triangle_Channel) {
	update_timer: if t.timer_value > 0 {
		t.timer_value -= 1
	} else {
		t.timer_value = t.timer_period
		t.sequence_index = (t.sequence_index + 1) % 32
		if should_update_sequence_output(t^) {
			t.sequence_output = apu_triangle_sequence_table[t.sequence_index]
		}
	}

	should_update_sequence_output :: proc(t: Triangle_Channel) -> bool {
		if !t.enable {
			return false
		}

		if t.length_counter_value <= 0 {
			return false
		}

		if t.linear_counter_value <= 0 {
			return false
		}

		return true
	}
}

@(private = "file")
triangle_channel_apu_clk :: proc(t: ^Triangle_Channel, quater_frame, half_frame: bool) {
	if quater_frame {
		// update linear counter
		if !t.linear_counter_reset {
			if t.linear_counter_value > 0 {
				t.linear_counter_value -= 1
			}

		} else {
			t.linear_counter_value = t.ctrl_reg.linear_counter_load
			if !t.ctrl_reg.flag {
				t.linear_counter_reset = false
			}
		}
	}

	if half_frame {
		// update length counter
		if t.enable {
			if t.length_counter_value > 0 && !t.ctrl_reg.flag {
				t.length_counter_value -= 1
			}
		} else {
			t.length_counter_value = 0
		}
	}
}

@(private = "file")
get_pulse_channel_output :: proc(p: Pulse_Channel) -> u8 {
	if !should_mute(p) {
		return p.sequence_output * p.env_output
	} else {
		return 0
	}

	should_mute :: proc(p: Pulse_Channel) -> bool {
		if !p.enable {
			return true
		}

		if p.timer_period < 8 {
			return true
		}

		if p.length_counter_value <= 0 {
			return true
		}

		if !sweep_target_period_in_range(p.sweep_target_period) {
			return true
		}

		return false
	}
}

@(private = "file")
pulse_channel_console_clk :: proc(p: ^Pulse_Channel) {
	update_sweep_target_period: {
		// The sweep target period is continuously updated (combinatorial
		// hardare circuit in NES) and will affect the wave amplitude. Only
		// mutates period when sweep divider reaches zero.
		current_period := p.timer_period >> p.sweep_reg.shift
		if p.sweep_reg.negate {
			p.sweep_target_period = p.timer_period - current_period
			if !p.sweep_negate_two_comp do p.sweep_target_period -= 1
		} else {
			p.sweep_target_period = p.timer_period + current_period
		}
	}
}


@(private = "file")
pulse_channel_apu_clk :: proc(p: ^Pulse_Channel, quater_frame, half_frame: bool) {
	if quater_frame {
		update_envelope: {
			// Both the envelope and sweep use an identical divider circuit to
			// allow for variable execution frequency.
			if !p.env_divider_reset {
				p.env_divider_value -= 1
				if p.env_divider_value == 0xff {
					p.env_divider_value = p.ctrl_reg.value
					// Decrement decay level counter when divider reaches
					// zero and reset if loop flag set.
					if p.env_decay_level_count > 0 {
						p.env_decay_level_count -= 1
					} else if p.ctrl_reg.flag {
						p.env_decay_level_count = 0x0f
					}
				}
			} else {
				p.env_divider_reset = false
				p.env_decay_level_count = 0x0f
				p.env_divider_value = p.ctrl_reg.value
			}

			if !p.ctrl_reg.constant_volume {
				p.env_output = p.env_decay_level_count
			} else {
				p.env_output = p.ctrl_reg.value
			}
		}
	}

	if half_frame {
		update_length_counter: if p.enable {
			if p.length_counter_value > 0 && !p.ctrl_reg.flag {
				p.length_counter_value -= 1
			}
		} else {
			p.length_counter_value = 0
		}

		update_sweep: if !p.sweep_divider_reset {
			p.sweep_divider_value -= 1

			if p.sweep_divider_value == 0xff {
				p.sweep_divider_value = p.sweep_reg.value
				if sweep_target_period_in_range(p.sweep_target_period) {
					if p.sweep_reg.enable && p.sweep_reg.shift > 0 {
						p.timer_period = p.sweep_target_period
					}
				}
			}
		} else {
			p.sweep_divider_reset = false
			p.sweep_divider_value = p.sweep_reg.value
		}
	}

	update_timer: if p.timer_value > 0 {
		p.timer_value -= 1
	} else {
		p.sequence_index = (p.sequence_index + 1) % 8
		p.sequence_output = apu_pulse_sequence_table[p.ctrl_reg.duty][p.sequence_index]
		p.timer_value = p.timer_period
	}

}

@(private = "file")
sweep_target_period_in_range :: proc(#any_int target_period: u16) -> bool {
	if target_period >= 0 && target_period <= 0x7ff {
		return true
	}

	return false
}

