package counter

import "core:testing"

import ui "myod:ui"

// The M4 acceptance test: click 加一 three times and 重置 once through the semantic tree, exactly
// as a user would, and check the state.
@(test)
counter_clicks :: proc(t: ^testing.T) {
	h := ui.test_harness(State{}, update, view)
	defer ui.test_destroy(h)

	testing.expect(t, ui.test_find(h, .Button, "加一") != nil, "the + button is not in the semantic tree")
	testing.expect(t, ui.test_find(h, .Button, "减一") != nil, "the − button is not in the semantic tree")
	testing.expect(t, ui.test_find(h, .Static_Text, "0") != nil, "the number is not in the semantic tree")

	for _ in 0 ..< 3 {
		testing.expect(t, ui.test_click(h, .Button, "加一"), "the + button could not be clicked")
	}
	testing.expect_value(t, h.store.state.count, 3)
	testing.expect(t, ui.test_find(h, .Static_Text, "3") != nil)

	testing.expect(t, ui.test_click(h, .Button, "重置"), "the reset button could not be clicked")
	testing.expect_value(t, h.store.state.count, 0)

	// Reset is disabled at 0: the click found it but nothing happened.
	testing.expect(t, ui.test_click(h, .Button, "重置"))
	testing.expect_value(t, h.store.state.count, 0)
}

// A click that changes state presents one frame: the pass that sent the message is never shown.
@(test)
counter_does_not_present_intermediate_frames :: proc(t: ^testing.T) {
	h := ui.test_harness(State{}, update, view)
	defer ui.test_destroy(h)
	before := h.window.presents
	testing.expect(t, ui.test_click(h, .Button, "加一"))
	testing.expect_value(t, h.window.presents, before + 1)
	testing.expect_value(t, h.store.state.count, 1)
}

// Tab moves the focus ring; Space activates the focused button.
@(test)
counter_keyboard :: proc(t: ^testing.T) {
	h := ui.test_harness(State{}, update, view)
	defer ui.test_destroy(h)

	ui.test_key(h, .Tab)
	ui.test_key(h, .Space) // − is first in Tab order, so this decrements
	testing.expect_value(t, h.store.state.count, -1)
	ui.test_key(h, .Tab)
	ui.test_key(h, .Space) // +
	testing.expect_value(t, h.store.state.count, 0)
}
