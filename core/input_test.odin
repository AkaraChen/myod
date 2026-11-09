package core

import "core:testing"

import "../layout"

// Declares two 100×50 buttons side by side at the top-left, plus a disabled one below them.
@(private = "file")
Buttons :: struct {
	ids:      [2]Id,
	disabled: Id,
}

@(private = "file")
buttons_view :: proc(data: rawptr) {
	b := (^Buttons)(data)
	ctx := current()
	open(ctx, key_id(ctx, "row"), {flex_direction = .Row})
	for i in 0 ..< 2 {
		id := key_id_int(ctx, i)
		b.ids[i] = id
		leaf(ctx, id, layout.Node{size = {{100, .Px}, {50, .Px}}}, flags = {.Hit, .Focusable, .Activate})
	}
	close(ctx)
	b.disabled = key_id(ctx, "off")
	leaf(ctx, b.disabled, layout.Node{size = {{100, .Px}, {50, .Px}}}, flags = {.Hit, .Focusable, .Activate, .Disabled})
}

@(private = "file")
screen :: proc(f: ^Fixture) -> ^Buttons {
	b := new(Buttons)
	run_frame(f, buttons_view, b)
	return b
}

@test
hit_testing_finds_the_topmost_widget :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	b := screen(f)
	defer free(b)
	ctx := &f.ctx

	testing.expect(t, ctx.input.hot == 0, "something is hovered with the mouse outside the window")
	testing.expect(t, handle_event(ctx, {kind = .Mouse_Move, pos = {10, 10}}))
	testing.expect_value(t, ctx.input.hot, b.ids[0])
	testing.expect(t, interact(ctx, b.ids[0]).hovered)
	testing.expect(t, !interact(ctx, b.ids[1]).hovered)

	// Moving within the same widget changes nothing that is drawn.
	testing.expect(t, !handle_event(ctx, {kind = .Mouse_Move, pos = {20, 20}}))
	handle_event(ctx, {kind = .Mouse_Move, pos = {120, 10}})
	testing.expect_value(t, ctx.input.hot, b.ids[1])

	// Leaving the window clears the hover.
	handle_event(ctx, {kind = .Mouse_Leave})
	testing.expect_value(t, ctx.input.hot, 0)
}

@test
clicking_records_a_result_once :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	b := screen(f)
	defer free(b)
	ctx := &f.ctx

	handle_event(ctx, {kind = .Mouse_Move, pos = {50, 25}})
	handle_event(ctx, {kind = .Mouse_Down, pos = {50, 25}, button = .Left})
	it := interact(ctx, b.ids[0])
	testing.expect(t, it.pressed && it.held, "pressing did not make the widget pressed")
	testing.expect(t, !it.clicked)
	testing.expect(t, it.focused, "pressing a focusable widget did not focus it")

	handle_event(ctx, {kind = .Mouse_Up, pos = {50, 25}, button = .Left, clicks = 1})
	it = interact(ctx, b.ids[0])
	testing.expect(t, it.clicked, "the click was not recorded")
	testing.expect(t, !it.pressed && !it.held, "the widget still holds the pointer after release")
	consume(ctx)

	// A press that ends somewhere else is not a click.
	handle_event(ctx, {kind = .Mouse_Down, pos = {50, 25}, button = .Left})
	handle_event(ctx, {kind = .Mouse_Up, pos = {150, 25}, button = .Left, clicks = 1})
	testing.expect(t, !interact(ctx, b.ids[0]).clicked)
}

@test
keyboard_focus_and_activation :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	b := screen(f)
	defer free(b)
	ctx := &f.ctx

	handle_event(ctx, {kind = .Key_Down, key = .Tab})
	testing.expect_value(t, ctx.input.focus, b.ids[0])
	testing.expect(t, ctx.input.focus_visible, "keyboard focus did not ask for a focus ring")
	handle_event(ctx, {kind = .Key_Down, key = .Tab})
	testing.expect_value(t, ctx.input.focus, b.ids[1])
	// The disabled button is skipped.
	handle_event(ctx, {kind = .Key_Down, key = .Tab})
	testing.expect_value(t, ctx.input.focus, b.ids[0])
	handle_event(ctx, {kind = .Key_Down, key = .Tab, mods = {.Shift}})
	testing.expect_value(t, ctx.input.focus, b.ids[1])

	handle_event(ctx, {kind = .Key_Down, key = .Space})
	testing.expect(t, interact(ctx, b.ids[1]).clicked, "Space did not activate the focused widget")
	testing.expect(t, ctx.input.keys[len(ctx.input.keys) - 1].key == .Space)

	// A click focuses without asking for the ring.
	handle_event(ctx, {kind = .Mouse_Move, pos = {50, 25}})
	handle_event(ctx, {kind = .Mouse_Down, pos = {50, 25}, button = .Left})
	testing.expect_value(t, ctx.input.focus, b.ids[0])
	testing.expect(t, !ctx.input.focus_visible)
}

@test
disabled_widgets_take_no_input :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	b := screen(f)
	defer free(b)
	ctx := &f.ctx

	handle_event(ctx, {kind = .Mouse_Move, pos = {50, 75}})
	testing.expect_value(t, ctx.input.hot, 0)
	handle_event(ctx, {kind = .Mouse_Down, pos = {50, 75}, button = .Left})
	testing.expect_value(t, ctx.input.focus, 0)
	handle_event(ctx, {kind = .Mouse_Up, pos = {50, 75}, button = .Left, clicks = 1})
	testing.expect(t, !interact(ctx, b.disabled).clicked)
}

@test
results_are_consumed_after_a_pass :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	b := screen(f)
	defer free(b)
	ctx := &f.ctx

	handle_event(ctx, {kind = .Mouse_Move, pos = {50, 25}})
	handle_event(ctx, {kind = .Mouse_Down, pos = {50, 25}, button = .Left})
	handle_event(ctx, {kind = .Mouse_Up, pos = {50, 25}, button = .Left, clicks = 1})
	testing.expect(t, has_results(ctx))
	consume(ctx)
	testing.expect(t, !has_results(ctx), "results survived the pass that read them")
	testing.expect(t, !interact(ctx, b.ids[0]).clicked)
}

@test
text_goes_to_the_focused_widget_only :: proc(t: ^testing.T) {
	f := setup(t)
	defer teardown(f)
	b := screen(f)
	defer free(b)
	ctx := &f.ctx

	handle_event(ctx, {kind = .Key_Down, key = .Tab})
	handle_event(ctx, {kind = .Text_Input, text = "你好"})
	testing.expect_value(t, len(keys(ctx, b.ids[0])), 1)
	testing.expect(t, keys(ctx, b.ids[1]) == nil)
	set_focus(ctx, 0, false)
	testing.expect(t, !handle_event(ctx, {kind = .Key_Down, key = .Char, char = 'a'}))
	testing.expect(t, !handle_event(ctx, {kind = .Text_Input, text = "x"}))
}
