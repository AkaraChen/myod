// Tests of the controlled text fields: typing, the caret, selections, undo and the input method's
// composition. They drive the widget through the same input phase a window does.
package ui

import "core:strings"
import "core:testing"

import "../platform"

Input_Test_State :: struct {
	name: string,
	notes: string,
}

Set_Name :: distinct string
Set_Notes :: distinct string

Input_Test_Msg :: union {
	Set_Name,
	Set_Notes,
}

input_test_update :: proc(s: ^Input_Test_State, msg: Input_Test_Msg, fx: ^Effects(Input_Test_Msg)) {
	switch m in msg {
	case Set_Name:
		delete(s.name)
		s.name = strings.clone(string(m))
	case Set_Notes:
		delete(s.notes)
		s.notes = strings.clone(string(m))
	}
}

input_test_view :: proc(s: Input_Test_State, d: Dispatch(Input_Test_Msg)) {
	if column({padding = 16, gap = 8, width = grow()}) {
		r, name := text_input("名字", s.name, width = grow())
		if r.changed {
			dispatch(d, Set_Name(name))
		}
		_, notes := text_area("备注", s.notes, width = grow())
		// Dispatched unconditionally: the test drives the field through edits and the state keeps
		// whatever the field returns.
		if notes != s.notes {
			dispatch(d, Set_Notes(notes))
		}
	}
}

input_test_new :: proc() -> ^Test_Harness(Input_Test_State, Input_Test_Msg) {
	return test_harness(Input_Test_State{}, input_test_update, input_test_view)
}

input_test_destroy :: proc(h: ^Test_Harness(Input_Test_State, Input_Test_Msg)) {
	delete(h.store.state.name)
	delete(h.store.state.notes)
	test_destroy(h)
}

// A key with a character, which the harness's `test_key` cannot send.
input_test_key :: proc(t: ^Test_Harness($S, $M), key: platform.Key, char: rune = 0, mods: platform.Modifiers = {}) {
	append(&t.window.events, platform.Event{kind = .Key_Down, key = key, char = char, mods = mods})
	test_frame(t)
}

@(test)
input_typing_is_controlled :: proc(t: ^testing.T) {
	h := input_test_new()
	defer input_test_destroy(h)
	test_type(h, .Textbox, "名字", "张三")
	testing.expect_value(t, h.store.state.name, "张三")
	testing.expect_value(t, test_find(h, .Textbox, "名字").value, "张三")
}

@(test)
input_typing_goes_in_at_the_caret :: proc(t: ^testing.T) {
	h := input_test_new()
	defer input_test_destroy(h)
	test_type(h, .Textbox, "名字", "abc")
	input_test_key(h, .Home)
	test_type(h, .Textbox, "名字", "X")
	testing.expect_value(t, h.store.state.name, "Xabc")
	input_test_key(h, .End)
	test_type(h, .Textbox, "名字", "!")
	testing.expect_value(t, h.store.state.name, "Xabc!")
}

@(test)
input_backspace_deletes_and_undo_restores :: proc(t: ^testing.T) {
	h := input_test_new()
	defer input_test_destroy(h)
	test_type(h, .Textbox, "名字", "abc")
	input_test_key(h, .Backspace)
	testing.expect_value(t, h.store.state.name, "ab")
	input_test_key(h, .Char, 'z', {.Super}) // Cmd+Z
	testing.expect_value(t, h.store.state.name, "abc")
	input_test_key(h, .Char, 'z', {.Super, .Shift}) // Cmd+Shift+Z
	testing.expect_value(t, h.store.state.name, "ab")
}

@(test)
input_shift_arrow_selects_and_backspace_removes :: proc(t: ^testing.T) {
	h := input_test_new()
	defer input_test_destroy(h)
	test_type(h, .Textbox, "名字", "hello")
	input_test_key(h, .Home)
	input_test_key(h, .Right, 0, {.Shift})
	input_test_key(h, .Right, 0, {.Shift})
	input_test_key(h, .Backspace)
	testing.expect_value(t, h.store.state.name, "llo")
	input_test_key(h, .Char, 'z', {.Super}) // Cmd+Z puts the selection back
	testing.expect_value(t, h.store.state.name, "hello")
}

@(test)
input_option_arrow_moves_by_word :: proc(t: ^testing.T) {
	h := input_test_new()
	defer input_test_destroy(h)
	test_type(h, .Textbox, "名字", "hello world")
	input_test_key(h, .Left, 0, {.Alt})
	test_type(h, .Textbox, "名字", "_")
	testing.expect_value(t, h.store.state.name, "hello _world")
	input_test_key(h, .Right, 0, {.Alt})
	input_test_key(h, .Right, 0, {.Alt})
	test_type(h, .Textbox, "名字", "!")
	testing.expect_value(t, h.store.state.name, "hello _world!")
}

@(test)
input_cmd_a_selects_everything :: proc(t: ^testing.T) {
	h := input_test_new()
	defer input_test_destroy(h)
	test_type(h, .Textbox, "名字", "abc")
	input_test_key(h, .Char, 'a', {.Super})
	test_type(h, .Textbox, "名字", "z")
	testing.expect_value(t, h.store.state.name, "z")
}

@(test)
input_value_change_keeps_the_caret_in_the_text :: proc(t: ^testing.T) {
	h := input_test_new()
	defer input_test_destroy(h)
	test_type(h, .Textbox, "名字", "abcdef")
	input_test_key(h, .Home)
	input_test_key(h, .Right)
	// The app rewrites the value under the field (a reset from outside).
	delete(h.store.state.name)
	h.store.state.name = strings.clone("xy")
	test_frame(h)
	test_type(h, .Textbox, "名字", "!")
	testing.expect_value(t, h.store.state.name, "x!y")
}

@(test)
input_ime_preedit_is_shown_and_committed :: proc(t: ^testing.T) {
	h := input_test_new()
	defer input_test_destroy(h)
	test_type(h, .Textbox, "名字", "abc")
	append(&h.window.events, platform.Event{kind = .Text_Editing, text = "nihao", cursor = {5, 0}})
	test_frame(h)
	testing.expect_value(t, test_find(h, .Textbox, "名字").value, "abcnihao")
	append(&h.window.events, platform.Event{kind = .Text_Input, text = "你好"})
	test_frame(h)
	testing.expect_value(t, h.store.state.name, "abc你好")
	testing.expect_value(t, test_find(h, .Textbox, "名字").value, "abc你好")
}

@(test)
input_area_takes_line_breaks :: proc(t: ^testing.T) {
	h := input_test_new()
	defer input_test_destroy(h)
	test_type(h, .Textbox, "备注", "one")
	input_test_key(h, .Enter)
	test_type(h, .Textbox, "备注", "two")
	testing.expect_value(t, h.store.state.notes, "one\ntwo")
}

@(test)
input_area_moves_between_lines :: proc(t: ^testing.T) {
	h := input_test_new()
	defer input_test_destroy(h)
	test_type(h, .Textbox, "备注", "one")
	input_test_key(h, .Enter)
	test_type(h, .Textbox, "备注", "two")
	input_test_key(h, .Enter)
	test_type(h, .Textbox, "备注", "three")
	input_test_key(h, .Home) // the start of "three"
	input_test_key(h, .Up)   // the start of "two"
	test_type(h, .Textbox, "备注", "X")
	testing.expect_value(t, h.store.state.notes, "one\nXtwo\nthree")
	input_test_key(h, .End) // the end of the "Xtwo" line
	test_type(h, .Textbox, "备注", "!")
	testing.expect_value(t, h.store.state.notes, "one\nXtwo!\nthree")
}

@(test)
input_exposes_a_text_run_to_screen_readers :: proc(t: ^testing.T) {
	h := input_test_new()
	defer input_test_destroy(h)
	test_type(h, .Textbox, "名字", "张三 hello")
	n := test_find(h, .Textbox, "名字")
	testing.expect(t, n != nil)
	if n == nil {
		return
	}
	// The run is what the field shows, one entry per character (Zhong and San are three bytes each).
	testing.expect_value(t, n.text, "张三 hello")
	testing.expect_value(t, len(n.char_lengths), 8)
	testing.expect_value(t, n.char_lengths[0], u8(3))
	testing.expect_value(t, n.char_lengths[2], u8(1))
	testing.expect_value(t, len(n.char_positions), 8)
	// The caret is a degenerate selection at the end of the text.
	testing.expect_value(t, n.sel_a, i32(len(n.text)))
	testing.expect_value(t, n.sel_b, i32(len(n.text)))
}

@(test)
input_reports_a_selection_to_screen_readers :: proc(t: ^testing.T) {
	h := input_test_new()
	defer input_test_destroy(h)
	test_type(h, .Textbox, "名字", "hello")
	input_test_key(h, .Home)
	input_test_key(h, .Right, 0, {.Shift})
	input_test_key(h, .Right, 0, {.Shift})
	n := test_find(h, .Textbox, "名字")
	testing.expect(t, n != nil)
	if n == nil {
		return
	}
	testing.expect_value(t, n.sel_a, i32(0))
	testing.expect_value(t, n.sel_b, i32(2))
}
