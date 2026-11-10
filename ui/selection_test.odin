// Tests of cross-widget text selection (ARCHITECTURE.md, "API design → 16"): drags in document
// order, word and paragraph clicks, copying, and the widgets that opt out.
package ui

import "core:testing"
import "core:unicode/utf8"

import "../core"
import "../platform"
import txt "../text"

Sel_State :: struct {
	taps: int,
}

Sel_Noop :: struct {}
Sel_Tapped :: struct {}

Sel_Msg :: union {
	Sel_Noop,
	Sel_Tapped,
}

sel_update :: proc(s: ^Sel_State, msg: Sel_Msg, fx: ^Effects(Sel_Msg)) {
	#partial switch m in msg {
	case Sel_Tapped:
		s.taps += 1
	}
}

sel_view :: proc(s: Sel_State, d: Dispatch(Sel_Msg)) {
	if column({padding = 16, width = grow()}) {
		text("Hello world")
		text("Second paragraph")
		if r := text("Click me", interactive = true); r.double_clicked {
			dispatch(d, Sel_Tapped{})
		}
		text("中文段落测试")
	}
}

sel_harness :: proc() -> ^Test_Harness(Sel_State, Sel_Msg) {
	return test_harness(Sel_State{}, sel_update, sel_view)
}

// The x of byte `offset` in a body paragraph, in root coordinates (the tests know the text, so they
// can aim at characters instead of guessing at widths).
sel_x :: proc(h: ^Test_Harness($S, $M), r: Rect, s: string, offset: int) -> f32 {
	x_at := txt.caret_positions(&h.window.text, s, text_style(.Body), h.window.scale)
	return r.x + x_at[offset] + 0.5
}

sel_drag :: proc(h: ^Test_Harness($S, $M), from, to: [2]f32, clicks := 1) {
	append(&h.window.events, platform.Event{kind = .Mouse_Move, pos = from})
	append(&h.window.events, platform.Event{kind = .Mouse_Down, pos = from, button = .Left, clicks = clicks})
	append(&h.window.events, platform.Event{kind = .Mouse_Move, pos = to})
	append(&h.window.events, platform.Event{kind = .Mouse_Up, pos = to, button = .Left, clicks = clicks})
	test_frame(h)
}

sel_copy :: proc(h: ^Test_Harness($S, $M)) -> string {
	s, _ := core.selection_string(&h.window.ctx, context.allocator)
	return s
}

@(test)
selection_drags_across_widgets :: proc(t: ^testing.T) {
	h := sel_harness()
	defer test_destroy(h)
	first := test_find(h, .Static_Text, "Hello world")
	second := test_find(h, .Static_Text, "Second paragraph")
	testing.expect(t, first != nil && second != nil)
	if first == nil || second == nil {
		return
	}
	from := [2]f32{sel_x(h, first.rect, "Hello world", 0), first.rect.y + 8}
	to := [2]f32{sel_x(h, second.rect, "Second paragraph", 3), second.rect.y + 8}
	sel_drag(h, from, to)
	testing.expect(t, h.window.ctx.sel.active)
	got := sel_copy(h)
	defer delete(got)
	testing.expect_value(t, got, "Hello world\nSec")
}

@(test)
selection_double_click_takes_the_word :: proc(t: ^testing.T) {
	h := sel_harness()
	defer test_destroy(h)
	first := test_find(h, .Static_Text, "Hello world")
	testing.expect(t, first != nil)
	if first == nil {
		return
	}
	p := [2]f32{sel_x(h, first.rect, "Hello world", 6), first.rect.y + 8}
	sel_drag(h, p, p, clicks = 2)
	got := sel_copy(h)
	defer delete(got)
	testing.expect_value(t, got, "world")
	// A triple click takes the whole paragraph.
	sel_drag(h, p, p, clicks = 3)
	got2 := sel_copy(h)
	defer delete(got2)
	testing.expect_value(t, got2, "Hello world")
}

@(test)
selection_ends_on_a_character_boundary :: proc(t: ^testing.T) {
	h := sel_harness()
	defer test_destroy(h)
	// A drag aimed at the right edge of a multi-byte character: the bytes inside it share that edge's
	// x, and must not become the selection's end offset.
	n := test_find(h, .Static_Text, "中文段落测试")
	testing.expect(t, n != nil)
	if n == nil {
		return
	}
	s := "中文段落测试"
	from := [2]f32{sel_x(h, n.rect, s, 0), n.rect.y + 8}
	to := [2]f32{sel_x(h, n.rect, s, len("中文")), n.rect.y + 8}
	sel_drag(h, from, to)
	got := sel_copy(h)
	defer delete(got)
	testing.expectf(t, utf8.valid_string(got), "selection %q is not valid UTF-8", got)
	testing.expect_value(t, got, "中文")
}

@(test)
selection_interactive_text_reports_double_click :: proc(t: ^testing.T) {
	h := sel_harness()
	defer test_destroy(h)
	n := test_find(h, .Static_Text, "Click me")
	testing.expect(t, n != nil)
	if n == nil {
		return
	}
	p := [2]f32{n.rect.x + 2, n.rect.y + 8}
	sel_drag(h, p, p, clicks = 2)
	testing.expect_value(t, h.store.state.taps, 1)
	testing.expect(t, !h.window.ctx.sel.active)
}

@(test)
selection_exposes_a_text_run_to_screen_readers :: proc(t: ^testing.T) {
	h := sel_harness()
	defer test_destroy(h)
	n := test_find(h, .Static_Text, "Hello world")
	testing.expect(t, n != nil)
	if n == nil {
		return
	}
	// One entry per character, with the UTF-8 byte lengths and a position each.
	testing.expect_value(t, n.text, "Hello world")
	testing.expect_value(t, len(n.char_lengths), 11)
	testing.expect_value(t, len(n.char_positions), 11)
	testing.expect_value(t, len(n.char_widths), 11)
	testing.expect_value(t, n.char_lengths[0], u8(1))
	// "Hello" starts the text; "world" starts a word of its own (UAX #29 also breaks before the
	// space, which AccessKit counts as a segment).
	testing.expect(t, len(n.word_starts) >= 2)
	testing.expect_value(t, n.word_starts[0], u8(0))
	world := false
	for w in n.word_starts {
		world = world || w == 6
	}
	testing.expect(t, world)
	testing.expect_value(t, n.char_positions[0], f32(0))
	testing.expect(t, n.char_positions[1] > n.char_positions[0])
	testing.expect(t, n.char_widths[0] > 0)
	// No caret or selection until the text is clicked.
	testing.expect_value(t, n.sel_a, i32(-1))
	testing.expect_value(t, n.sel_b, i32(-1))
}

@(test)
selection_reports_the_selection_to_screen_readers :: proc(t: ^testing.T) {
	h := sel_harness()
	defer test_destroy(h)
	first := test_find(h, .Static_Text, "Hello world")
	testing.expect(t, first != nil)
	if first == nil {
		return
	}
	from := [2]f32{sel_x(h, first.rect, "Hello world", 0), first.rect.y + 8}
	to := [2]f32{sel_x(h, first.rect, "Hello world", 5), first.rect.y + 8}
	sel_drag(h, from, to)
	n := test_find(h, .Static_Text, "Hello world")
	testing.expect_value(t, n.sel_a, i32(0))
	testing.expect_value(t, n.sel_b, i32(5))
	testing.expect_value(t, n.text[int(n.sel_a):int(n.sel_b)], "Hello")
}

@(test)
selection_text_runs_count_characters_not_bytes :: proc(t: ^testing.T) {
	h := sel_harness()
	defer test_destroy(h)
	n := test_find(h, .Static_Text, "中文段落测试")
	testing.expect(t, n != nil)
	if n == nil {
		return
	}
	// Six three-byte characters, one entry each.
	testing.expect_value(t, len(n.char_lengths), 6)
	testing.expect_value(t, n.char_lengths[0], u8(3))
	testing.expect_value(t, len(n.char_positions), 6)
	for w in n.word_starts {
		testing.expect(t, int(w) < 6)
	}
}

@(test)
selection_leaves_interactive_text_alone :: proc(t: ^testing.T) {
	h := sel_harness()
	defer test_destroy(h)
	n := test_find(h, .Static_Text, "Click me")
	testing.expect(t, n != nil)
	if n == nil {
		return
	}
	p := [2]f32{n.rect.x + 2, n.rect.y + 8}
	sel_drag(h, p, p)
	testing.expect(t, !h.window.ctx.sel.active)
}
