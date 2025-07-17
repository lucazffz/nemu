package emulator
import "core:log"
import "core:math"
import "core:os"

SINE_WAVE_HARMONIES_NUM :: 50


APU :: struct {
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

Envelope :: struct {
	reset:               bool,
	loop:                bool,
	constant_volume:     bool,
	decay_level_counter: u8,
	param:               u8,
	divider:             u8,
	output:              u8,
}

update_envelope_from_pulse_channel :: proc(e: ^Envelope, p: Pulse_Channel) {
	e.loop = p.ctrl.evelope_loop
	e.constant_volume = p.ctrl.constant_volume
	e.param = p.ctrl.value
}

// get_envelope_from_pulse_channel :: proc(pulse: Pulse_Channel) -> Envelope {
// 	return {
// 		true,
// 		pulse.ctrl.evelope_loop,
// 		pulse.ctrl.constant_volume,
// 		0x0f,
// 		pulse.ctrl.value,
// 		pulse.ctrl.value,
// 		0,
// 	}

// }

envelope_execute :: proc(e: ^Envelope) -> (output: u8) {
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

	output = e.output

	return
}

Sequencer :: struct {
	sequence:       u32,
	timer:          u16,
	length_counter: u16,
	output:         u8,
	// func:           proc(sequence: ^u32),
}

Sequencer_Proc :: proc(sequence: ^u32)

sequencer_execute :: proc(s: ^Sequencer, enable: bool, func: Sequencer_Proc) -> u8 {
	if enable {
		s.timer -= 1
		if s.timer == 0xffff {
			s.timer = s.length_counter + 1
			func(&s.sequence)
			s.output = u8(s.sequence & 0x1)
		}
	}

	return s.output
}


Pulse_Channel :: struct {
	enable:   bool,
	ctrl:     bit_field u8 {
		value:           u8   | 4,
		constant_volume: bool | 1,
		evelope_loop:    bool | 1,
		duty:            u8   | 2,
	},
	sweep:    bit_field u8 {
		shift:  uint | 3,
		negate: bool | 1,
		period: uint | 3,
		enable: bool | 1,
	},
	// timer:          uint, // 11 bits, 
	// length_counter: uint, // 5 bits, 
	seq:      Sequencer,
	envelope: Envelope,
	// envelope: uint,
}

Triangle_Channel :: struct {
}

Noise_Channel :: struct {
}

DMC :: struct {
}

apu_set_sample_frequency :: proc(apu: ^APU, sample_rate: f64) {
	apu.audio_time_per_system_sample = 1.0 / sample_rate
	apu.audio_time_per_apu_clk = 1.0 / 5369318.0 // ppu/apu clk freq
}

apu_get_sample :: proc(apu: ^APU) -> f64 {
	return apu.audio_sample

}

apu_execute_clk_cycle :: proc(apu: ^APU) -> (sample_complete: bool) {
	apu.audio_time += apu.audio_time_per_apu_clk
	if apu.audio_time >= apu.audio_time_per_system_sample {
		apu.audio_time -= apu.audio_time_per_system_sample
		// apu.audio_sample = apu_get_sample(apu)
		sample_complete = true
	}

	apu.global_time += (0.3333333333 / CPU_CLK_FREQUENCY)


	quater_frame_clk: bool
	half_frame_clk: bool

	if apu.cycle_count % 6 == 0 {
		apu.frame_count += 1

		if apu.frame_count == 3729 do quater_frame_clk = true
		if apu.frame_count == 7457 {
			quater_frame_clk = true
			half_frame_clk = true
		}
		if apu.frame_count == 11186 do quater_frame_clk = true
		if apu.frame_count == 14916 {
			quater_frame_clk = true
			half_frame_clk = true
			apu.frame_count = 0
		}

		if quater_frame_clk {
			envelope_execute(&apu.pulse1.envelope)
		}

		// sequencer_execute(&apu.pulse1.seq, true, proc(sequence: ^u32) {
		// 	sequence^ = ((sequence^ & 0x1) << 7) | ((sequence^ & 0xfe) >> 1)
		// })

		pulse1_sample: f64

		if apu.pulse1.enable {
			pulse1_frequency := get_frequency_from_length_counter(apu.pulse1.seq.length_counter)
			pulse1_duty := get_duty_from_mode(apu.pulse1.ctrl.duty)
			wave_data := Square_Wave_Data{pulse1_frequency, SINE_WAVE_HARMONIES_NUM, pulse1_duty}
			sample := sample_square_wave(wave_data, apu.global_time)
			amplitude := envelope_output_to_percentage(apu.pulse1.envelope)

			pulse1_sample = sample * amplitude
		}

		apu.audio_sample = pulse1_sample
	}

	apu.cycle_count += 1

	return
}

envelope_output_to_percentage :: proc(e: Envelope) -> f64 {
	// output will range from 0 to 15 (4 bits)
	return f64(e.output) / 15
}

get_frequency_from_length_counter :: proc(#any_int length_counter: u16) -> f64 {
	return CPU_CLK_FREQUENCY / (16.0 * f64(length_counter + 1))

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
	// PI :: math.PI
	// return (16 * x * (PI - x)) / (5 * PI * PI - 4 * x * (PI - x))
	j := x * 0.15915
	j = j - f64(int(j))
	return 20.785 * j * (j - 0.5) * (j - 1.0)
}

sample_triangle_wave :: proc "contextless" (data: Triangle_Wave_Data, t: f64) -> f64 {
	sum: f64
	for i in 0 ..< f64(data.harmonics_num) {
		n := 2 * i + 1
		c := 2 * math.PI * n * data.frequency * t
		sum += (math.pow(-1, i) / math.pow(n, 2)) * fast_approx_sin(c)
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
		apu.pulse1.ctrl = auto_cast data
		update_envelope_from_pulse_channel(&apu.pulse1.envelope, apu.pulse1)

		switch apu.pulse1.ctrl.duty {
		case 0:
			apu.pulse1.seq.sequence = 0b00000001
		case 1:
			apu.pulse1.seq.sequence = 0b00000011
		case 2:
			apu.pulse1.seq.sequence = 0b00001111
		case 3:
			apu.pulse1.seq.sequence = 0b11111100
		}
	case 0x4001:
		apu.pulse1.sweep = auto_cast data
	// pulse 1 sweep
	case 0x4002:
		// pulse 1 timer low
		apu.pulse1.seq.length_counter = (apu.pulse1.seq.length_counter & 0xff00) | u16(data)
	case 0x4003:
		// pulse 1 length counter, timer high
		apu.pulse1.seq.length_counter =
			(u16(data & 0x07) << 8) | (apu.pulse1.seq.length_counter & 0x00ff)
		apu.pulse1.seq.timer = apu.pulse1.seq.length_counter
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
	case:
		panic("address not handled by APU")
	}

	return
}

