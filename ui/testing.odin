// The test harness (ARCHITECTURE.md, "Testing"): drives a real app through the same input phase,
// message phase, `view`, layout and semantic tree the windowed loop uses, but with no platform
// window and no GPU. Tests find widgets the way a user does, by role and name, and the simulated
// input is hit-tested, so covered or disabled widgets cannot be clicked.
//
//	t := ui.test_harness(State{}, update, view)
//	defer ui.test_destroy(t)
//	ui.test_click(t, role = .Button, name = "加一")
//	testing.expect(t, t.store.state.count == 1)
//
// All layouts use the FreeType + HarfBuzz backend on every platform: build tests with
// `-define:MYOD_TEXT_BACKEND=freetype` (see the justfile).
package ui

import "core:fmt"
import "core:os"

import "../core"
import "../platform"
import "../text"

// Re-exports for tests: the semantic tree is what tests look widgets up in.
Role :: core.Role
A11y_Node :: core.A11y_Node
A11y_Flag :: core.A11y_Flag
A11y_Action :: core.A11y_Action

Test_Harness :: struct($S, $M: typeid) {
	store:  Store(S, M),
	window: Window,
	view:   proc(s: S, d: Dispatch(M)),
}

// Creates a headless app: the store is initialized with `state`, `update` and `view`, and one frame
// is run so the first semantic tree exists.
test_harness :: proc(
	state: $S,
	update: proc(s: ^S, msg: $M, fx: ^Effects(M)),
	view: proc(s: S, d: Dispatch(M)),
	size := [2]f32{800, 600},
	scale: f32 = 2,
) -> ^Test_Harness(S, M) {
	t := new(Test_Harness(S, M))
	t.window.size = size
	t.window.scale = scale
	t.window.mode = .Light
	t.window.first = true
	t.view = view
	if !text.init(&t.window.text) {
		fmt.eprintln("myod: test harness could not load the test fonts")
		os.exit(1)
	}
	if !core.init(&t.window.ctx, &t.window.text) {
		os.exit(1)
	}
	t.window.ctx.text = &t.window.text
	store_init(&t.store, &t.window, state, update)
	test_frame(t)
	return t
}

test_destroy :: proc(t: ^Test_Harness($S, $M)) {
	store_destroy(&t.store)
	delete(t.window.events)
	core.destroy(&t.window.ctx)
	text.destroy(&t.window.text)
	delete(window_stack)
	window_stack = nil
	free(t)
}

// Runs frames until the app is idle again: every pass the layout needs, every message `update` has
// to process, and the final present. Intermediate frames are not presented.
test_frame :: proc(t: ^Test_Harness($S, $M)) {
	w := &t.window
	for {
		if w.declared {
			if finish_pass(w) {
				t.view(t.store.state, dispatcher(&t.store))
				continue
			}
			break
		}
		if w.started {
			break
		}
		handle_events(w)
		process_messages(w)
		start_frame(w)
		begin_pass(w)
		t.view(t.store.state, dispatcher(&t.store))
	}
}

// The first widget with this role and name in the semantic tree, or nil.
test_find :: proc(t: ^Test_Harness($S, $M), role: Role, name: string) -> ^A11y_Node {
	for &n in t.window.ctx.a11y {
		if n.role == role && n.name == name {
			return &n
		}
	}
	return nil
}

// Clicks a widget through the real input phase: hit testing, press, release. Returns whether the
// widget was found; it may still not have been clicked if something covers it or it is disabled.
test_click :: proc(t: ^Test_Harness($S, $M), role: Role, name: string) -> bool {
	n := test_find(t, role, name)
	if n == nil {
		return false
	}
	p := [2]f32{n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2}
	append(&t.window.events, platform.Event{kind = .Mouse_Move, pos = p})
	append(&t.window.events, platform.Event{kind = .Mouse_Down, pos = p, button = .Left})
	append(&t.window.events, platform.Event{kind = .Mouse_Up, pos = p, button = .Left, clicks = 1})
	test_frame(t)
	return true
}

// Moves the pointer over a widget (hover) without clicking.
test_hover :: proc(t: ^Test_Harness($S, $M), role: Role, name: string) -> bool {
	n := test_find(t, role, name)
	if n == nil {
		return false
	}
	p := [2]f32{n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2}
	append(&t.window.events, platform.Event{kind = .Mouse_Move, pos = p})
	test_frame(t)
	return true
}

// Focuses a widget by clicking it, then types text into it.
test_type :: proc(t: ^Test_Harness($S, $M), role: Role, name: string, s: string) {
	if !test_click(t, role, name) {
		return
	}
	append(&t.window.events, platform.Event{kind = .Text_Input, text = s})
	test_frame(t)
}

// Sends a key press to the focused widget.
test_key :: proc(t: ^Test_Harness($S, $M), key: platform.Key, mods: platform.Modifiers = {}) {
	append(&t.window.events, platform.Event{kind = .Key_Down, key = key, mods = mods})
	test_frame(t)
}
