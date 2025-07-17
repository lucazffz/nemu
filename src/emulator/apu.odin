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
	enable:         bool,
	ctrl_reg:       bit_field u8 {
		value:           u8   | 4,
		constant_volume: bool | 1,
		flag:            bool | 1,
		duty:            u8   | 2,
	},
	sweep_reg:      bit_field u8 {
		shift:  u8   | 3,
		negate: bool | 1,
		value:  u8   | 3,
		enable: bool | 1,
	},
	period:         u16, // 11 bits, 
	length_counter: u8, // 5 bits, 
	// seq:            Sequencer,
	envelope:       Envelope,
	sweep:          Sweep,
}

Triangle_Channel :: struct {
}

Noise_Channel :: struct {
}

DMC :: struct {
}

Envelope :: struct {
	reset:               bool,
	loop:                bool,
	constant_volume:     bool,
	decay_level_counter: u8,
	param:               u8,
	divider:             u8,
	output:              u8,
}

Sweep :: struct {
	enable:   bool,
	reset:    bool,
	negate:   bool,
	carry_in: bool,
	shift:    u8,
	param:    u8,
	divider:  u8,
	output:   u16,
}

Sequencer :: struct {
	sequence: u32,
	timer:    u16,
	reload:   u16,
	output:   u8,
	// func:           proc(sequence: ^u32),
}

Square_Wave_Data :: struct {
	frequency:     f64,
	harmonics_num: int,
	duty_cycle:    f64,
}

Triangle_Wave_Data :: struct {
	frequency:     f64,
	harmonics_num: int,
}

Noise_Wave_Data :: struct {
}

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
}

Sequencer_Proc :: proc(sequence: ^u32)

update_envelope_from_pulse_channel :: proc(e: ^Envelope, p: Pulse_Channel) {
	e.loop = p.ctrl_reg.flag
	e.constant_volume = p.ctrl_reg.constant_volume
	e.param = p.ctrl_reg.value
}

get_envelope_from_pulse_channel :: proc(p: Pulse_Channel) -> Envelope {
	return {
		true,
		p.ctrl_reg.flag,
		p.ctrl_reg.constant_volume,
		0x0f,
		p.ctrl_reg.value,
		p.ctrl_reg.value,
		0,
	}
}

get_sweep_from_pulse_channel :: proc(p: Pulse_Channel, carry_in: bool) -> Sweep {
	return {
		p.sweep_reg.enable,
		true,
		p.sweep_reg.negate,
		carry_in,
		p.sweep_reg.shift,
		p.sweep_reg.value,
		p.sweep_reg.value,
		0,
	}
}

sweep_execute :: proc(s: ^Sweep, period: u16) -> u16 {
	if s.enable {
		if !s.reset {
			s.divider -= 1

			if s.divider == 0xff {
				current_period := period >> s.shift
				target_period: u16
				if s.negate {
					target_period = period - current_period
					if !s.carry_in do target_period -= 1
				} else {
					target_period = period + current_period
				}

				if target_period < 0 || target_period > 0x7ff {
					s.output = period
				} else {
					s.output = target_period
				}

				s.divider = s.param
			}
		} else {
			s.reset = false
			s.divider = s.param
		}
	} else {
		s.output = period
	}

	return s.output
}

envelope_execute :: proc(e: ^Envelope) -> u8 {
	if !e.reset {
		e.divider -= 1
		if e.divider == 0xff {
			e.divider = e.param
			e.decay_level_counter -= 1
			if e.decay_level_counter <= 0 && e.loop {
				e.decay_level_counter = 0x0f
			}
		}
	} else {
		e.reset = false
		e.decay_level_counter = 0x0f
		e.divider = e.param
	}

	if e.constant_volume {
		e.output = e.param
	} else {
		e.output = e.decay_level_counter
	}

	return e.output
}


sequencer_execute :: proc(s: ^Sequencer, enable: bool, func: Sequencer_Proc) -> u8 {
	if enable {
		s.timer -= 1
		if s.timer == 0xffff {
			s.timer = s.reload + 1
			func(&s.sequence)
			s.output = u8(s.sequence & 0x1)
		}
	}

	return s.output
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


		if quater_frame_clk {
			envelope_execute(&apu.pulse1.envelope)
		}

		if half_frame_clk {
			if apu.pulse1.enable {
				if apu.pulse1.length_counter > 0 && !apu.pulse1.ctrl_reg.flag {
					apu.pulse1.length_counter -= 1
				}
			} else {
				apu.pulse1.length_counter = 0
			}

			sweep_execute(&apu.pulse1.sweep, apu.pulse1.period)
		}

		// sequencer_execute(&apu.pulse1.seq, true, proc(sequence: ^u32) {
		// 	sequence^ = ((sequence^ & 0x1) << 7) | ((sequence^ & 0xfe) >> 1)
		// })

		pulse1_sample: f64
		if !pulse_channel_should_mute(apu.pulse1) {
			period := pulse_channel_get_period(apu.pulse1)
			pulse1_frequency := get_frequency_from_channel_period(period)
			pulse1_duty := get_duty_from_mode(apu.pulse1.ctrl_reg.duty)
			wave_data := Square_Wave_Data{pulse1_frequency, SINE_WAVE_HARMONIES_NUM, pulse1_duty}
			sample := sample_square_wave(wave_data, apu.global_time)
			amplitude := envelope_output_to_percentage(apu.pulse1.envelope)

			pulse1_sample = sample * amplitude

		}

		apu.audio_sample = pulse1_sample
	}

	apu.cycle_count += 1

	trigger_irq = apu.frame_interrupt

	return
}

envelope_output_to_percentage :: proc(e: Envelope) -> f64 {
	// output will range from 0 to 15 (4 bits)
	return f64(e.output) / 15
}

get_frequency_from_channel_period :: proc(#any_int period: u16) -> f64 {
	return CPU_CLK_FREQUENCY / (16.0 * f64(period + 1))

}

pulse_channel_should_mute :: proc(p: Pulse_Channel) -> bool {
	if p.period < 8 || p.period > 0x7ff {
		return true
	}

	if p.length_counter <= 0 {
		return true
	}

	return false
}

pulse_channel_get_period :: proc(p: Pulse_Channel) -> u16 {
	if p.sweep.enable {
		return p.sweep.output
	} else {
		return p.period
	}
}

get_duty_from_mode :: proc(#any_int duty_mode: uint) -> (duty: f64) {
	switch duty_mode {
	case 0:
		duty = 0.125
	case 1:
		duty = 0.25
	case 2:
		duty = 0.5
	case 3:
		duty = 0.75
	}

	return
}


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

fast_approx_sin :: proc "contextless" (x: f64) -> f64 {
	j := x * 0.15915
	j = j - f64(int(j))
	return 20.785 * j * (j - 0.5) * (j - 1.0)
}

sample_triangle_wave :: proc "contextless" (data: Triangle_Wave_Data, t: f64) -> f64 {
	sum: f64
	for i in 0 ..< f64(data.harmonics_num) {
		n := 2 * i + 1
		c := 2 * math.PI * n * data.frequency * t
		sum += (math.pow(-1, i) / (n * n)) * fast_approx_sin(c)
	}

	return sum * 8 / math.pow_f64(math.PI, 2)
}

sample_noise_wave :: proc "contextless" (data: Noise_Wave_Data, t: f64) -> f64 {
	return 0
}

apu_write_to_address :: proc(apu: ^APU, data: u8, address: u16) {
	switch address {
	case 0x4000:
		// pulse 1 control
		apu.pulse1.ctrl_reg = auto_cast data
		update_envelope_from_pulse_channel(&apu.pulse1.envelope, apu.pulse1)

	// switch apu.pulse1.ctrl.duty {
	// case 0:
	// 	apu.pulse1.seq.sequence = 0b00000001
	// case 1:
	// 	apu.pulse1.seq.sequence = 0b00000011
	// case 2:
	// 	apu.pulse1.seq.sequence = 0b00001111
	// case 3:
	// 	apu.pulse1.seq.sequence = 0b11111100
	// }
	case 0x4001:
		// pulse 1 sweep
		apu.pulse1.sweep_reg = auto_cast data
		apu.pulse1.sweep = get_sweep_from_pulse_channel(apu.pulse1, false)
	case 0x4002:
		// pulse 1 timer low
		// apu.pulse1.seq.reload = (apu.pulse1.seq.reload & 0xff00) | u16(data)
		apu.pulse1.period = (apu.pulse1.period & 0xff00) | u16(data)
	case 0x4003:
		// pulse 1 length counter, timer high
		// apu.pulse1.seq.reload = (u16(data & 0x07) << 8) | (apu.pulse1.seq.reload & 0x00ff)
		apu.pulse1.period = (u16(data & 0x07) << 8) | (apu.pulse1.period & 0x00ff)
		// apu.pulse1.seq.timer = apu.pulse1.seq.reload
		apu.pulse1.length_counter = length_counter_LUT[data >> 3]
		apu.pulse1.envelope = get_envelope_from_pulse_channel(apu.pulse1)
	case 0x4004:
	// pulse 2 control
	case 0x4005:
	// pulse 2 sweep
	case 0x4006:
	// pulse 2 timer low
	case 0x4007:
	// pulse 2 length counter, timer high
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

