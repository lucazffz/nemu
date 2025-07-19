package emulator

import "core:log"
import "core:math"
import "core:os"

SINE_WAVE_HARMONIES_NUM :: 50

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
	audio_sample:                 f64,
	global_time:                  f64,
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
	period:                u16, // 11 bits, 
	length_counter:        u8,
	// --- Internal state variables,
	// not set by writing to addresses.
	volume:                u8,
	// envelope
	env_decay_level_count: u8,
	env_divider_reset:     bool,
	env_divider_count:     u8,
	// sweep 
	sweep_target_period:   u16,
	sweep_negate_two_comp: bool,
	sweep_divider_reset:   bool,
	sweep_divider_count:   u8,
}

Triangle_Channel :: struct {
}

Noise_Channel :: struct {
}

DMC :: struct {
}

@(private = "file")
Square_Wave_Data :: struct {
	frequency:     f64,
	harmonics_num: int,
	duty_cycle:    f64,
}

@(private = "file")
Triangle_Wave_Data :: struct {
	frequency:     f64,
	harmonics_num: int,
}

@(private = "file")
Noise_Wave_Data :: struct {
}

@(rodata)
length_counter_LUT := [?]u8 {
	10,
	254,
	20,
	2,
	40,
	4,
	80,
	6,
	160,
	8,
	60,
	10,
	14,
	12,
	26,
	14,
	12,
	16,
	24,
	18,
	48,
	20,
	96,
	22,
	192,
	24,
	72,
	26,
	16,
	28,
	32,
	30,
}

apu_initialize :: proc(apu: ^APU, sample_rate: f64) {
	apu.frame_reg.irq_inhibit_flag = true
	apu.audio_time_per_system_sample = 1.0 / sample_rate
	apu.audio_time_per_apu_clk = 1.0 / 5369318.0 // ppu/apu clk freq


	// The sweep unit of pulse channel 1 and 2 negate the period using
	// one's respectively two's complement.
	apu.pulse1.sweep_negate_two_comp = false
	apu.pulse2.sweep_negate_two_comp = true
}


apu_get_sample :: proc(apu: ^APU) -> f64 {
	return apu.audio_sample

}

apu_execute_clk_cycle :: proc(apu: ^APU) -> (sample_complete: bool, trigger_irq: bool) {
	apu.audio_time += apu.audio_time_per_apu_clk
	if apu.audio_time >= apu.audio_time_per_system_sample {
		apu.audio_time -= apu.audio_time_per_system_sample
		// apu.audio_sample = apu_get_sample(apu)
		sample_complete = true
	}

	apu.global_time += (0.3333333333 / CPU_CLK_FREQUENCY)


	quater_frame_clk: bool
	half_frame_clk: bool
	frame_clk: bool

	if apu.cycle_count % 6 == 0 {
		apu.frame_count += 1

		if apu.frame_reg.sequence_mode == 0 {
			// 4 step sequence
			if apu.frame_count == 3729 {
				quater_frame_clk = true
			}

			if apu.frame_count == 7457 {
				quater_frame_clk = true
				half_frame_clk = true
			}

			if apu.frame_count == 11186 {
				quater_frame_clk = true
			}

			if apu.frame_count == 14915 {
				if !apu.frame_reg.irq_inhibit_flag {
					apu.frame_interrupt = true
				}

				quater_frame_clk = true
				half_frame_clk = true
				frame_clk = true
				apu.frame_count = 0
			}
		} else {
			// 5 step sequence
			if apu.frame_count == 3729 {
				quater_frame_clk = true
			}

			if apu.frame_count == 7457 {
				quater_frame_clk = true
				half_frame_clk = true
			}

			if apu.frame_count == 11186 {
				quater_frame_clk = true
			}

			if apu.frame_count == 14915 {
				// do nothing
			}

			if apu.frame_count == 18641 {
				quater_frame_clk = true
				half_frame_clk = true
				frame_clk = true
				apu.frame_count = 0
			}
		}

		pulse_channel_clock(&apu.pulse1, quater_frame_clk, half_frame_clk)
		pulse_channel_clock(&apu.pulse2, quater_frame_clk, half_frame_clk)

		pulse1_sample: f64
		if !pulse_channel_should_mute(apu.pulse1) {
			frequency := get_frequency_from_channel_period(apu.pulse1.period)
			duty := get_duty_fraction_from_channel_duty(apu.pulse1.ctrl_reg.duty)
			data := Square_Wave_Data{frequency, SINE_WAVE_HARMONIES_NUM, duty}
			sample := sample_square_wave(data, apu.global_time)
			ampitude := get_amplitude_from_channel_volume(apu.pulse1.volume)
			pulse1_sample = sample * ampitude
		}

		pulse2_sample: f64
		if !pulse_channel_should_mute(apu.pulse2) {
			frequency := get_frequency_from_channel_period(apu.pulse2.period)
			duty := get_duty_fraction_from_channel_duty(apu.pulse2.ctrl_reg.duty)
			data := Square_Wave_Data{frequency, SINE_WAVE_HARMONIES_NUM, duty}
			sample := sample_square_wave(data, apu.global_time)
			ampitude := get_amplitude_from_channel_volume(apu.pulse2.volume)
			pulse2_sample = sample * ampitude
		}

		// Linear approximation mixing (see nesdev).
		// Since pulse channel output is [0,15] (sequencer) but our produced
		// sample (approx sine square wave) is [0,1], multiply by 15.
		// Same goes for noise and triangle channels. The DMC ranges
		// from [0,127].
		pulse_out := (pulse1_sample + pulse2_sample) * 15 * 0.00752
		tnd_out := 0.0
		apu.audio_sample = pulse_out + tnd_out
	}

	apu.cycle_count += 1

	trigger_irq = apu.frame_interrupt

	return
}


apu_write_to_address :: proc(apu: ^APU, data: u8, address: u16) {
	switch address {
	case 0x4000:
		// pulse 1 control
		apu.pulse1.ctrl_reg = auto_cast data
	case 0x4001:
		// pulse 1 sweep
		apu.pulse1.sweep_reg = auto_cast data
		apu.pulse1.sweep_divider_reset = true
	case 0x4002:
		// pulse 1 timer low
		apu.pulse1.period = (apu.pulse1.period & 0xff00) | u16(data)
	case 0x4003:
		// pulse 1 length counter, timer high
		apu.pulse1.period = (u16(data & 0x07) << 8) | (apu.pulse1.period & 0x00ff)
		apu.pulse1.length_counter = length_counter_LUT[data >> 3]

		// restart envelope
		apu.pulse1.env_divider_reset = true
	case 0x4004:
		// pulse 2 control
		apu.pulse2.ctrl_reg = auto_cast data
	case 0x4005:
		// pulse 2 sweep
		apu.pulse2.sweep_reg = auto_cast data
		apu.pulse2.sweep_divider_reset = true
	case 0x4006:
		// pulse 2 timer low
		apu.pulse2.period = (apu.pulse2.period & 0xff00) | u16(data)
	case 0x4007:
		// pulse 2 length counter, timer high
		apu.pulse2.period = (u16(data & 0x07) << 8) | (apu.pulse2.period & 0x00ff)
		apu.pulse2.length_counter = length_counter_LUT[data >> 3]

		apu.pulse2.env_divider_reset = true
	case 0x4008:
	// triangle control
	case 0x4009:
	// unused
	case 0x400a:
	// triangle timer low
	case 0x400b:
	// triangle length counter, timer high
	case 0x400c:
	// noise control
	case 0x400d:
	// unused
	case 0x400e:
	// noise mode, period
	case 0x400f:
	// noise length counter
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
		data = (u8(apu.frame_interrupt) << 6) + (u8(apu.pulse1.length_counter > 0))
		apu.frame_interrupt = false
	case:
		panic("address not handled by APU")
	}

	return
}

// Containes all core logic for updating the state of the pulse channels.
@(private = "file")
pulse_channel_clock :: proc(p: ^Pulse_Channel, quater_frame: bool, half_frame: bool) {
	update_sweep_target_period: {
		// The sweep target period is continuously updated (combinatorial
		// hardare circuit in NES) and will affect the wave amplitude. Only
		// mutates period when sweep divider reaches zero.
		current_period := p.period >> p.sweep_reg.shift
		if p.sweep_reg.negate {
			p.sweep_target_period = p.period - current_period
			if !p.sweep_negate_two_comp do p.sweep_target_period -= 1
		} else {
			p.sweep_target_period = p.period + current_period
		}
	}

	if quater_frame {
		// Update envelope
		// Both the envelope and sweep use an identical divider circuit to
		// allow for variable execution frequency.
		if !p.env_divider_reset {
			p.env_divider_count -= 1
			if p.env_divider_count == 0xff {
				p.env_divider_count = p.ctrl_reg.value
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
			p.env_divider_count = p.ctrl_reg.value
		}

		if !p.ctrl_reg.constant_volume {
			p.volume = p.env_decay_level_count
		} else {
			p.volume = p.ctrl_reg.value
		}
	}

	if half_frame {
		// update length counter
		if p.enable {
			if p.length_counter > 0 && !p.ctrl_reg.flag {
				p.length_counter -= 1
			}
		} else {
			p.length_counter = 0
		}

		// update sweep
		if !p.sweep_divider_reset {
			p.sweep_divider_count -= 1

			if p.sweep_divider_count == 0xff {
				p.sweep_divider_count = p.sweep_reg.value
				if sweep_target_period_in_range(p.sweep_target_period) {
					if p.sweep_reg.enable && p.sweep_reg.shift > 0 {
						p.period = p.sweep_target_period
					}
				}
			}
		} else {
			p.sweep_divider_reset = false
			p.sweep_divider_count = p.sweep_reg.value
		}
	}
}

// --- Wave generation functions
// The NES outputs a 1 bit sample, using a sequencer, that gets converted
// to a voltage signal through a DAC (digital to analog converter).
// The pulse and triangle channels therefore produces pure square
// and triangle waves which does not play well with modern audio systems.
// Therefore, the channel sequencer is replaced by a wave generation function
// (which depends on the channel) producing a sine wave approximation.

@(private = "file")
sample_square_wave :: proc "contextless" (data: Square_Wave_Data, t: f64) -> f64 {
	sawtooth_wave1, sawtooth_wave2: f64
	p := data.duty_cycle * 2 * math.PI

	for i in 1 ..= f64(data.harmonics_num) {
		c := 2 * math.PI * i * data.frequency * t
		sawtooth_wave1 += -fast_approx_sin(c) / i
		sawtooth_wave2 += -fast_approx_sin(c - p * i) / i
	}

	return (sawtooth_wave1 - sawtooth_wave2) / math.PI
}

@(private = "file")
fast_approx_sin :: proc "contextless" (x: f64) -> f64 {
	j := x * 0.15915
	j = j - f64(int(j))
	return 20.785 * j * (j - 0.5) * (j - 1.0)
}

@(private = "file")
sample_triangle_wave :: proc "contextless" (data: Triangle_Wave_Data, t: f64) -> f64 {
	sum: f64
	for i in 0 ..< f64(data.harmonics_num) {
		n := 2 * i + 1
		c := 2 * math.PI * n * data.frequency * t
		sum += (math.pow(-1, i) / (n * n)) * fast_approx_sin(c)
	}

	return sum * 8 / math.pow_f64(math.PI, 2)
}

@(private = "file")
sample_noise_wave :: proc "contextless" (data: Noise_Wave_Data, t: f64) -> f64 {
	return 0
}

// --- Auxiliary functions

@(private = "file")
sweep_target_period_in_range :: proc(#any_int target_period: u16) -> bool {
	if target_period >= 0 && target_period <= 0x7ff {
		return true
	}

	return false
}

@(private = "file")
get_frequency_from_channel_period :: proc(#any_int period: u16) -> f64 {
	return CPU_CLK_FREQUENCY / (16.0 * f64(period + 1))
}

@(private = "file")
get_amplitude_from_channel_volume :: proc(#any_int volume: u8) -> f64 {
	return f64(volume) / 15
}

@(private = "file")
get_duty_fraction_from_channel_duty :: proc(#any_int duty: u8) -> f64 {
	switch duty & 0x03 {
	case 0:
		return 0.125
	case 1:
		return 0.25
	case 2:
		return 0.5
	case 3:
		return 0.75
	}

	panic("unreachable")
}

@(private = "file")
pulse_channel_should_mute :: proc(p: Pulse_Channel) -> bool {
	if p.period < 8 {
		return true
	}

	if p.length_counter <= 0 {
		return true
	}

	if !sweep_target_period_in_range(p.sweep_target_period) {
		return true
	}

	return false
}

