package nemu

import "core:testing"

@(test)
test :: proc(t: ^testing.T) {
	testing.fail(t)
	testing.fail(t)
}

