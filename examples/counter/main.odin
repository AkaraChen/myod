// Counter: the minimal structure — State, Msg, update, view, and the frame loop.
package counter

import "core:fmt"

import ph "myod:icons/phosphor"
import ui "myod:ui"

// ---- State ----

State :: struct {
	count: int,
}

// ---- Messages: every possible state transition is listed here ----

Increment :: struct {}
Decrement :: struct {}
Reset :: struct {}

Msg :: union {
	Increment,
	Decrement,
	Reset,
}

// ---- update: the only place that modifies state ----
// The switch must be exhaustive: adding a message without handling it is a compile error.

update :: proc(s: ^State, msg: Msg, fx: ^ui.Effects(Msg)) {
	switch _ in msg {
	case Increment: s.count += 1
	case Decrement: s.count -= 1
	case Reset:     s.count = 0
	}
}

// ---- view: receives state by value, read-only; interactions are sent as messages via dispatch ----

view :: proc(s: State, d: ui.Dispatch(Msg)) {
	// Containers return bool, open with `if`, and close automatically at the end of the scope.
	if ui.column({padding = 24, gap = 16, align_x = .Center, align_y = .Center}) {
		ui.text(fmt.tprint(s.count), .Display)

		if ui.row({gap = 8}) {
			// Widgets return a Response; read whichever fields you need.
			if ui.icon_button(ph.MINUS, "减一").clicked do ui.dispatch(d, Decrement{})
			if ui.icon_button(ph.PLUS, "加一").clicked do ui.dispatch(d, Increment{})

			if ui.button("重置", icon = ph.ARROW_COUNTER_CLOCKWISE, variant = .Ghost, disabled = s.count == 0).clicked {
				ui.dispatch(d, Reset{})
			}
		}
	}
}

main :: proc() {
	window := ui.open_window({title = "计数器", size = {320, 200}})
	defer ui.close_window(&window)

	store: ui.Store(State, Msg)
	ui.store_init(&store, &window, State{}, update)
	defer ui.store_destroy(&store)

	// next_frame first processes the messages sent by the previous view pass (calling update for each),
	// then decides whether view must run again:
	// - messages still pending: rerun immediately without presenting the intermediate frame
	// - all processed: present the frame, then block until the next event
	for ui.next_frame(&window) {
		view(store.state, ui.dispatcher(&store))
	}
}
