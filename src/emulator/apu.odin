package emulator

import "core:log"
import "core:math"
import "core:os"
import "core:slice"

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
}

// @(private = "file")
// Square_Wave_Data :: struct {
// 	frequency:     f64,
// 	harmonics_num: int,
// 	duty_cycle:    f64,
// }

// @(private = "file")
// Triangle_Wave_Data :: struct {
// 	frequency:     f64,
// 	harmonics_num: int,
// }

// @(private = "file")
// Noise_Wave_Data :: struct {
// }

apu_initialize :: proc(apu: ^APU, sample_rate: f64) {
	// @note Not setting irq inhibit flag on startup causes issues
	// in Super Mario Bros, and probably more games.
	apu.frame_reg.irq_inhibit_flag = true
	apu.audio_time_per_system_sample = 1.0 / sample_rate
	apu.audio_time_per_apu_clk = 1.0 / 5369318.0 // ppu/apu clk freq


	// The sweep unit of pulse channel 1 and 2 negate the period using
	// one's respectively two's complement.
	apu.pulse1.sweep_negate_two_comp = false
	apu.pulse2.sweep_negate_two_comp = true

	apu.noise.feedback_shifter_value = 1
}


apu_get_sample :: proc(apu: ^APU) -> (sample: f64) {
	sample = math.sum(apu.sample_buf[:]) / f64(len(apu.sample_buf))
	clear_dynamic_array(&apu.sample_buf)
	return

}

apu_execute_clk_cycle :: proc(apu: ^APU) -> (sample_complete: bool, trigger_irq: bool) {
	apu.audio_time += apu.audio_time_per_apu_clk
	if apu.audio_time >= apu.audio_time_per_system_sample {
		apu.audio_time -= apu.audio_time_per_system_sample
		sample_complete = true
	}

	defer {
		apu.cycle_count += 1
		trigger_irq = apu.frame_interrupt
	}


	// update once per CPU clock cycle
	if apu.cycle_count % 3 == 0 {
		triangle_channel_clock(&apu.triangle)
	}

	// update once per frame (cpu_cycle / 2 <=> ppu_cycle / 6)
	if apu.cycle_count % 6 == 0 {
		frame, half_frame, quater_frame := execute_frame_sequence(apu)

		pulse_channel_frame_clock(&apu.pulse1, quater_frame, half_frame)
		pulse_channel_frame_clock(&apu.pulse2, quater_frame, half_frame)
		noise_channel_frame_clock(&apu.noise, quater_frame, half_frame)
		triangle_channel_frame_clock(&apu.triangle, quater_frame, half_frame)

		pulse1_sample := get_pulse_channel_output(apu.pulse1)
		pulse2_sample := get_pulse_channel_output(apu.pulse2)
		triangle_sample := get_triangle_channel_output(apu.triangle)
		noise_sample := get_noise_channel_output(apu.noise)

		pulse_out := f64(apu_pulse_mixer_table[pulse1_sample + pulse2_sample])
		tnd_out := 0.00851 * f64(triangle_sample) + 0.00494 * f64(noise_sample)

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
	case 0x4011:
	// DMC load counter
	case 0x4012:
	// DMC sample address
	case 0x4013:
	// DMC sample length
	case 0x4015:
		// status
		apu.pulse1.enable = data & 0x01 > 0
		apu.pulse2.enable = data & 0x02 > 0
		apu.triangle.enable = data & 0x04 > 0
		apu.noise.enable = data & 0x08 > 0
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
			(u8(apu.frame_interrupt) << 6) +
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
noise_channel_frame_clock :: proc(n: ^Noise_Channel, quater_frame, half_frame: bool) {
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
triangle_channel_clock :: proc(t: ^Triangle_Channel) {
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
triangle_channel_frame_clock :: proc(t: ^Triangle_Channel, quater_frame, half_frame: bool) {
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
pulse_channel_frame_clock :: proc(p: ^Pulse_Channel, quater_frame, half_frame: bool) {
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


// @(private = "file")
// sample_square_wave :: proc "contextless" (data: Square_Wave_Data, t: f64) -> f64 {
// 	sawtooth_wave1, sawtooth_wave2: f64
// 	p := data.duty_cycle * 2 * math.PI

// 	for i in 1 ..= f64(data.harmonics_num) {
// 		c := 2 * math.PI * i * data.frequency * t
// 		sawtooth_wave1 += -fast_approx_sin(c) / i
// 		sawtooth_wave2 += -fast_approx_sin(c - p * i) / i
// 	}

// 	return (sawtooth_wave1 - sawtooth_wave2) / math.PI
// }

// @(private = "file")
// fast_approx_sin :: proc "contextless" (x: f64) -> f64 {
// 	j := x * 0.15915
// 	j = j - f64(int(j))
// 	return 20.785 * j * (j - 0.5) * (j - 1.0)
// }

// @(private = "file")
// sample_triangle_wave :: proc "contextless" (data: Triangle_Wave_Data, t: f64) -> f64 {
// 	sum: f64
// 	for i in 0 ..< f64(data.harmonics_num) {
// 		n := 2 * i + 1
// 		c := 2 * math.PI * n * data.frequency * t
// 		sum += (math.pow(-1, i) / (n * n)) * fast_approx_sin(c)
// 	}

// 	return sum * 8 / (math.PI * math.PI)
// }

// @(private = "file")
// sample_noise_wave :: proc "contextless" (data: Noise_Wave_Data, t: f64) -> f64 {
// 	return 0
// }

// --- Auxiliary functions

@(private = "file")
sweep_target_period_in_range :: proc(#any_int target_period: u16) -> bool {
	if target_period >= 0 && target_period <= 0x7ff {
		return true
	}

	return false
}

// @(private = "file")
// get_frequency_from_channel_period :: proc(#any_int period: u16, cpu_cycles_per_tick: int) -> f64 {
// 	return CPU_CLK_FREQUENCY / ((32.0 / f64(cpu_cycles_per_tick)) * f64(period + 1))
// }

// @(private = "file")
// get_amplitude_from_channel_volume :: proc(#any_int volume: u8) -> f64 {
// 	return f64(volume) / 15
// }

// @(private = "file")
// get_duty_fraction_from_channel_duty :: proc(#any_int duty: u8) -> f64 {
// 	switch duty & 0x03 {
// 	case 0:
// 		return 0.125
// 	case 1:
// 		return 0.25
// 	case 2:
// 		return 0.5
// 	case 3:
// 		return 0.75
// 	}

// 	panic("unreachable")
// }

