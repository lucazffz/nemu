package emulator

Buttons :: bit_set[Button]

Button :: enum {
	a,
	b,
	select,
	start,
	up,
	down,
	left,
	right,
}

Controller :: struct {
	buttons: Buttons, // button state
	strobe:  bool, // should update button state
	index:   u8, // current button to read
}

controller_write :: proc(controller: ^Controller, data: u8) {
	controller.strobe = data & 0x1 == 1
	if controller.strobe do controller.index = 0
}

controller_read :: proc(controller: ^Controller) -> u8 {
	controller.index &= 0xff
	data := (transmute(u8)controller.buttons >> controller.index) & 0x1
	controller.index += 1
	return data
}

controller_set_buttons :: proc(controller: ^Controller, buttons: Buttons) {
	if controller.strobe do controller.buttons = buttons
}

