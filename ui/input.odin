// Text input (DESIGN.md, "Input"; ARCHITECTURE.md, "API design → 16"): controlled single- and
// multi-line fields.
//
// The value is the app's: every edit is returned, and the app stores it in State. What belongs to the
// library is the presentation state — cursor, selection, the scrolling of the value and the input
// method's preedit text — kept per widget ID in an `Input_State`. Text events are applied once per
// frame even when `view` reruns as a ghost pass (`core.take_keys`).
package ui

import "core:strings"
import "core:unicode/utf8"

import "../core"
import "../layout"
import "../platform"
import txt "../text"

// The shortcut modifier: Command on macOS, Control elsewhere. Word-wise movement is Option on macOS
// (as the system's text views do) and Control elsewhere.
when ODIN_OS == .Darwin {
	CMD_MOD :: platform.Modifiers{.Super}
	WORD_MOD :: platform.Modifiers{.Alt}
	REDO_MOD :: platform.Modifiers{.Shift}
} else {
	CMD_MOD :: platform.Modifiers{.Ctrl}
	WORD_MOD :: platform.Modifiers{.Ctrl}
	REDO_MOD :: platform.Modifiers{.Shift}
}

// Pasting more than this into a single-line input keeps the first line only (as a browser does).
@(private) INPUT_MAX_UNDO :: 100
@(private) NATURAL_LINE_HEIGHT :: 20.0

// The library state of a text field. Owned strings are released through `input_state_free`.
@(private)
Input_State :: struct {
	text:   [dynamic]u8, // the value being edited (owned)
	ready:  bool, // `text` was seeded from the app's value
	frame:  u64, // the frame the value was last reconciled with the app's in
	cursor: int,
	anchor: int,
	scroll: f32, // horizontal (single-line) or vertical (multi-line) offset in logical pixels
	wrap_width: f32, // the multi-line field's inner width at the last draw
	// The input method's composition: shown inline at the cursor, underlined.
	preedit:     [dynamic]u8,
	preedit_sel: [2]int, // [start, end) in the preedit; equal when there is no selection
	display:     [dynamic]u8, // the value with the preedit inserted, what is drawn and read
	dragging:    bool,
	undo:        [dynamic]Input_Snapshot,
	redo:        [dynamic]Input_Snapshot,
}

@(private)
Input_Snapshot :: struct {
	text:   string, // owned
	cursor: int,
	anchor: int,
}

@(private)
input_state_free :: proc(p: rawptr) {
	st := (^Input_State)(p)
	for s in st.undo {
		delete(s.text)
	}
	for s in st.redo {
		delete(s.text)
	}
	delete(st.undo)
	delete(st.redo)
	delete(st.text)
	delete(st.preedit)
	delete(st.display)
}

// A text field. `label` sits above it (never a placeholder) and names it for assistive technology;
// `hide_label` drops the visible label but keeps the name. `error` turns the field red and writes
// the reason below it. Returns the pass's interaction and the current value — the value is only
// valid until `update` returns, so clone it if State keeps it.
text_input :: proc(
	label: string,
	value: string,
	width: Size = {},
	hide_label := false,
	autofocus := false,
	key := "",
	error := "",
	disabled := false,
) -> (Response, string) {
	return input_field(label, value, width, hide_label, autofocus, key, error, disabled, lines = 1)
}

// A multi-line text field: `rows` lines tall, Enter inserts a line break, and the text wraps at the
// field's width.
text_area :: proc(
	label: string,
	value: string,
	rows := 3,
	width: Size = {},
	hide_label := false,
	autofocus := false,
	key := "",
	error := "",
	disabled := false,
) -> (Response, string) {
	return input_field(label, value, width, hide_label, autofocus, key, error, disabled, lines = rows)
}

@(private)
input_field :: proc(
	label, value: string,
	width: Size,
	hide_label, autofocus: bool,
	key, error: string,
	disabled: bool,
	lines: int,
) -> (Response, string) {
	ctx := core.current()
	multiline := lines > 1
	id := input_id(ctx, label, key)
	display_name := label
	if i := strings.index(label, "##"); i >= 0 {
		display_name = label[:i]
	}
	core.register_name(ctx, label, id)

	st, created := core.state(ctx, id, Input_State)
	if created {
		core.set_state_free(ctx, id, input_state_free)
		resize(&st.text, len(value))
		copy(st.text[:], value)
		st.ready = true
	} else {
		input_sync(ctx, st, value)
	}
	if created && autofocus {
		core.set_focus(ctx, id, true)
	}

	it := core.interact(ctx, id)

	// Mouse first: where the press landed sets the caret. The rect comes from the last pass, which
	// is what the press was hit-tested against.
	r, has_rect := core.last_rect(ctx, id)
	if has_rect {
		if w := current_window(); w.p != nil {
			// The text cursor over the field, the arrow everywhere else.
			platform.set_cursor(.Text if it.hovered else .Default)
		}
	}
	edited := false
	submitted := false
	cancelled := false
	if has_rect && !disabled {
		edited = input_mouse(ctx, st, it, r, multiline) || edited
	}
	if it.focused {
		keys_edited, keys_submitted, keys_cancelled := input_keys(ctx, id, st, multiline)
		edited = edited || keys_edited
		submitted = keys_submitted
		cancelled = keys_cancelled
	} else {
		core.take_keys(ctx, id)
	}

	// The text shown: the value with the composition inline at the cursor.
	input_build_display(st)
	shown := string(st.display[:])
	style := text_style(.Compact)
	scale := ctx.scale
	x_at := txt.caret_positions(ctx.text, shown, style, scale)
	preedit_len := len(st.preedit)
	caret := clamp(st.cursor + preedit_len, 0, len(shown))

	label_color: core.Token = .Muted
	border: core.Token = .Border_Strong
	text_color: core.Token = .Fg
	if error != "" {
		label_color = .Error
		border = .Error
		text_color = .Error
	} else if it.focused {
		label_color = .Fg
		border = .Fg
	}
	if disabled {
		border = .Border
	}

	w := width
	if w.kind == .Fit {
		w = fixed(240)
	}
	outer := layout.Node {
		flex_direction = .Column,
		gap            = {4, 4},
		align_items    = .Stretch,
	}
	item(ctx, &outer, w, {})
	opened_outer := core.open(ctx, core.auto_id(ctx), outer, nil, cull = false)
	_ = opened_outer
	if !hide_label && display_name != "" {
		lbl := layout.Node{}
		core.leaf(ctx, core.auto_id(ctx), lbl, core.Paint_Text{s = display_name, style = text_style(.Label), color = label_color, wrap = false}, measured = true)
	}

	box := layout.Node{flex_direction = .Row, align_items = .Center}
	if multiline {
		box.size[1] = {f32(lines) * NATURAL_LINE_HEIGHT + 8, .Px}
		box.min_size[1] = {28, .Px}
	} else {
		box.size[1] = {28, .Px}
	}
	flags := core.Node_Flags{.Hit, .Focusable, .Text_Edit}
	if disabled {
		flags += {.Disabled}
	}
	box_rect, _ := core.last_rect(ctx, id)
	opened := core.open(ctx, id, box, core.Paint_Box{border = border, border_width = 1}, clip = true, label = display_name, flags = flags)
	if opened {
		want_w := box_rect.w
		if want_w <= 0 {
			want_w = core.measured(ctx, id).x
		}
		if want_w <= 0 {
			want_w = 240
		}
		box_h := f32(lines) * NATURAL_LINE_HEIGHT + 8 if multiline else 28
		input_draw(ctx, st, it, shown, style, scale, x_at, caret, preedit_len, want_w, box_h, text_color, disabled, multiline)
	}
	core.close(ctx)
	core.set_a11y_role(ctx, id, .Textbox)
	core.set_a11y_value(ctx, id, shown)
	// The same text as a run, with the caret and selection, so screen readers can read it by
	// character, word and line and follow the caret.
	anchor := st.anchor
	if anchor > st.cursor {
		anchor += preedit_len
	}
	anchor = clamp(anchor, 0, len(shown))
	inner_w := max(box_rect.w - 16, 1)
	core.set_a11y_text(ctx, id, shown, anchor, caret, style, inner_w if multiline else 0, 0 if multiline else st.scroll, 8)
	if error != "" {
		err_ln := layout.Node{}
		core.leaf(ctx, core.auto_id(ctx), err_ln, core.Paint_Text{s = error, style = text_style(.Metadata), color = .Error, wrap = true}, measured = true)
	}
	core.close(ctx) // the outer column

	res := response_interactive(ctx, id, disabled)
	res.changed = edited
	res.submitted = submitted
	res.cancelled = cancelled

	if it.focused {
		input_announce(ctx, box_rect, x_at, caret, st.scroll)
	}

	return res, string(st.text[:])
}

@(private)
input_id :: proc(ctx: ^core.Context, label, key: string) -> Id {
	if key != "" {
		return core.key_id(ctx, key)
	}
	id, _ := core.label_id(ctx, label)
	return id
}

// ---- Reconciling with the app's value ----

// Takes the app's value when it changed under us (a reset, a programmatic edit) and keeps the caret
// inside the new text. Runs once per frame: ghost passes see the text this pass edited, not the
// app's not-yet-updated State.
@(private)
input_sync :: proc(ctx: ^core.Context, st: ^Input_State, value: string) {
	if st.frame == ctx.frame {
		return
	}
	st.frame = ctx.frame
	if !st.ready {
		st.ready = true
		resize(&st.text, len(value))
		copy(st.text[:], value)
		return
	}
	if string(st.text[:]) == value {
		return
	}
	resize(&st.text, len(value))
	copy(st.text[:], value)
	st.cursor = snap_back(string(st.text[:]), clamp(st.cursor, 0, len(st.text)))
	st.anchor = snap_back(string(st.text[:]), clamp(st.anchor, 0, len(st.text)))
	clear(&st.preedit)
	st.preedit_sel = {}
}

// The byte offset at or before `i` that starts a rune.
@(private)
snap_back :: proc(s: string, i: int) -> int {
	j := clamp(i, 0, len(s))
	for j > 0 && j < len(s) && (s[j] & 0xc0) == 0x80 {
		j -= 1
	}
	return j
}

// ---- Editing ----

@(private)
input_build_display :: proc(st: ^Input_State) {
	clear(&st.display)
	append(&st.display, ..st.text[:st.cursor])
	append(&st.display, ..st.preedit[:])
	append(&st.display, ..st.text[st.cursor:])
}

@(private)
input_bounds :: proc(st: ^Input_State) -> (a, b: int) {
	return min(st.cursor, st.anchor), max(st.cursor, st.anchor)
}

@(private)
input_remove :: proc(st: ^Input_State, a, b: int) {
	if a >= b {
		return
	}
	n := len(st.text)
	shift := b - a
	for i := a; i < n - shift; i += 1 {
		st.text[i] = st.text[i + shift]
	}
	resize(&st.text, n - shift)
}

@(private)
input_push_undo :: proc(st: ^Input_State) {
	append(&st.undo, Input_Snapshot{text = strings.clone(string(st.text[:])), cursor = st.cursor, anchor = st.anchor})
	if len(st.undo) > INPUT_MAX_UNDO {
		delete(st.undo[0].text)
		ordered_remove(&st.undo, 0)
	}
	for s in st.redo {
		delete(s.text)
	}
	clear(&st.redo)
}

// Replaces the selected text (or inserts at the caret).
@(private)
input_insert :: proc(st: ^Input_State, bytes: []u8) {
	if len(bytes) == 0 {
		return
	}
	input_push_undo(st)
	a, b := input_bounds(st)
	input_remove(st, a, b)
	n := len(st.text)
	resize(&st.text, n + len(bytes))
	for i := n - 1; i >= a; i -= 1 {
		st.text[i + len(bytes)] = st.text[i]
	}
	copy(st.text[a:], bytes)
	st.cursor = a + len(bytes)
	st.anchor = st.cursor
	clear(&st.preedit)
	st.preedit_sel = {}
}

@(private)
input_delete :: proc(st: ^Input_State, direction: int) {
	a, b := input_bounds(st)
	if a != b {
		input_push_undo(st)
		input_remove(st, a, b)
		st.cursor = a
		st.anchor = a
		return
	}
	s := string(st.text[:])
	i := st.cursor
	target := i
	if direction < 0 {
		target = prev_rune(s, i)
	} else {
		target = next_rune(s, i)
	}
	if target == i {
		return
	}
	input_push_undo(st)
	input_remove(st, min(i, target), max(i, target))
	st.cursor = min(i, target)
	st.anchor = st.cursor
}

@(private)
input_undo :: proc(st: ^Input_State) -> bool {
	if len(st.undo) == 0 {
		return false
	}
	snap := pop(&st.undo)
	append(&st.redo, Input_Snapshot{text = strings.clone(string(st.text[:])), cursor = st.cursor, anchor = st.anchor})
	resize(&st.text, len(snap.text))
	copy(st.text[:], snap.text)
	st.cursor = snap.cursor
	st.anchor = snap.anchor
	delete(snap.text)
	clear(&st.preedit)
	st.preedit_sel = {}
	return true
}

@(private)
input_redo :: proc(st: ^Input_State) -> bool {
	if len(st.redo) == 0 {
		return false
	}
	snap := pop(&st.redo)
	append(&st.undo, Input_Snapshot{text = strings.clone(string(st.text[:])), cursor = st.cursor, anchor = st.anchor})
	resize(&st.text, len(snap.text))
	copy(st.text[:], snap.text)
	st.cursor = snap.cursor
	st.anchor = snap.anchor
	delete(snap.text)
	return true
}

@(private)
input_copy :: proc(st: ^Input_State) -> bool {
	a, b := input_bounds(st)
	if a == b {
		return false
	}
	platform.set_clipboard_text(string(st.text[a:b]))
	return true
}

@(private)
input_cut :: proc(st: ^Input_State) -> bool {
	if !input_copy(st) {
		return false
	}
	input_delete(st, 0)
	return true
}

@(private)
input_paste :: proc(st: ^Input_State, multiline: bool) {
	text := platform.clipboard_text(context.temp_allocator)
	if text == "" {
		return
	}
	bytes := make([dynamic]u8, 0, len(text), context.temp_allocator)
	for b in transmute([]u8)text {
		if !multiline && (b == '\n' || b == '\r') {
			append(&bytes, ' ')
			continue
		}
		if b < 0x20 && b != '\n' && b != '\t' {
			continue
		}
		append(&bytes, b)
	}
	input_insert(st, bytes[:])
}

// ---- Keys ----

// Applies the keys and text typed into the focused field. Returns whether the value changed, and
// whether Enter submitted or Esc cancelled the field.
@(private)
input_keys :: proc(ctx: ^core.Context, id: Id, st: ^Input_State, multiline: bool) -> (edited, submitted, cancelled: bool) {
	events := core.take_keys(ctx, id)
	for e in events {
		#partial switch e.kind {
		case .Text_Input:
			bytes := make([dynamic]u8, 0, len(e.text), context.temp_allocator)
			for b in transmute([]u8)e.text {
				if !multiline && (b == '\n' || b == '\r') {
					continue
				}
				if b < 0x20 && b != '\t' {
					continue
				}
				append(&bytes, b)
			}
			if len(bytes) > 0 {
				input_insert(st, bytes[:])
				edited = true
			}
		case .Text_Editing:
			clear(&st.preedit)
			append(&st.preedit, ..transmute([]u8)e.text)
			if e.cursor[1] >= 0 {
				st.preedit_sel = {clamp(int(e.cursor[0]), 0, len(st.preedit)), clamp(int(e.cursor[0] + e.cursor[1]), 0, len(st.preedit))}
			} else {
				st.preedit_sel = {}
			}
		case .Key_Down:
			key_edited, key_submitted, key_cancelled := input_key(ctx, st, e, multiline)
			edited = edited || key_edited
			submitted = submitted || key_submitted
			cancelled = cancelled || key_cancelled
		}
	}
	return
}

@(private)
input_key :: proc(ctx: ^core.Context, st: ^Input_State, e: platform.Event, multiline: bool) -> (edited, submitted, cancelled: bool) {
	s := string(st.text[:])
	style := text_style(.Compact)
	cmd := e.mods & CMD_MOD != {}
	if cmd && !e.repeat {
		switch e.char {
		case 'a':
			st.anchor = 0
			st.cursor = len(s)
			return
		case 'c':
			input_copy(st)
			return
		case 'x':
			return input_cut(st), false, false
		case 'v':
			input_paste(st, multiline)
			return true, false, false
		case 'z':
			if e.mods & REDO_MOD != {} {
				return input_redo(st), false, false
			}
			return input_undo(st), false, false
		}
	}
	word := e.mods & WORD_MOD != {}
	shift := .Shift in e.mods
	#partial switch e.key {
	case .Backspace:
		input_delete(st, -1)
		return true, false, false
	case .Delete:
		input_delete(st, 1)
		return true, false, false
	case .Left:
		moved := prev_rune(s, st.cursor)
		if word {
			moved = txt.prev_word(s, st.cursor)
		}
		return input_move(st, moved, shift), false, false
	case .Right:
		moved := next_rune(s, st.cursor)
		if word {
			moved = txt.next_word(s, st.cursor)
		}
		return input_move(st, moved, shift), false, false
	case .Home:
		if multiline {
			start, _ := input_line_edges(ctx, st, s, style, st.cursor)
			return input_move(st, start, shift), false, false
		}
		return input_move(st, 0, shift), false, false
	case .End:
		if multiline {
			_, end := input_line_edges(ctx, st, s, style, st.cursor)
			return input_move(st, end, shift), false, false
		}
		return input_move(st, len(s), shift), false, false
	case .Up, .Down:
		if multiline {
			return input_vertical(ctx, st, style, e.key == .Up, shift), false, false
		}
		return
	case .Enter:
		if multiline {
			input_insert(st, []u8{'\n'})
			return true, false, false
		}
		return false, true, false
	case .Escape:
		return false, false, true
	}
	_ = ctx
	return
}

@(private)
input_move :: proc(st: ^Input_State, to: int, extend: bool) -> bool {
	target := clamp(to, 0, len(st.text))
	if target == st.cursor {
		return false
	}
	st.cursor = target
	if !extend {
		st.anchor = target
	}
	return false
}

// ---- Mouse ----

@(private)
input_mouse :: proc(ctx: ^core.Context, st: ^Input_State, it: core.Interaction, r: Rect, multiline: bool) -> bool {
	style := text_style(.Compact)
	if it.held {
		p := core.pointer(ctx)
		if !st.dragging {
			st.dragging = true
			i := input_index_at(ctx, st, r, style, it.press + {ctx.viewport.x, ctx.viewport.y}, multiline)
			st.anchor, st.cursor = i, i
		}
		// Dragging extends the selection; the anchor stays where the press landed.
		st.cursor = input_index_at(ctx, st, r, style, p, multiline)
	} else {
		st.dragging = false
		if it.clicks >= 2 {
			// The release of a double click selects the word under it; a triple click, everything.
			a, b := 0, len(st.text)
			if it.clicks == 2 {
				a, b = txt.word_at(string(st.text[:]), st.cursor)
			}
			st.anchor, st.cursor = a, b
		}
	}
	return false
}

// The byte offset in the field nearest `p` (root coordinates).
@(private)
input_index_at :: proc(ctx: ^core.Context, st: ^Input_State, r: Rect, style: txt.Style, p: [2]f32, multiline: bool) -> int {
	s := string(st.text[:])
	scale := ctx.scale
	x_at := txt.caret_positions(ctx.text, s, style, scale)
	if multiline {
		lines := input_lines(ctx, st, s, style, x_at)
		local_y := p.y - (r.y + 4) + st.scroll
		index := clamp(int(local_y / style.line_height), 0, len(lines) - 1)
		l := lines[index]
		local_x := p.x - (r.x + 8)
		x0 := l.x0 / scale
		best, best_d := l.start, abs(x_at[l.start] - x0 - local_x)
		for i in l.start + 1 ..= l.end {
			d := abs(x_at[i] - x0 - local_x)
			if d < best_d {
				best, best_d = i, d
			}
		}
		return snap_back(s, best)
	}
	local := p.x - (r.x + 8) + st.scroll
	best, best_d := 0, abs(x_at[0] - local)
	for i in 1 ..= len(s) {
		d := abs(x_at[i] - local)
		if d < best_d {
			best, best_d = i, d
		}
	}
	return snap_back(s, best)
}

// ---- Runes ----

@(private)
rune_at :: proc(s: string, i: int) -> rune {
	if i < 0 || i >= len(s) {
		return 0
	}
	r, _ := utf8.decode_rune_in_string(s[i:])
	return r
}

@(private)
prev_rune :: proc(s: string, i: int) -> int {
	j := clamp(i, 0, len(s))
	if j == 0 {
		return 0
	}
	j -= 1
	for j > 0 && (s[j] & 0xc0) == 0x80 {
		j -= 1
	}
	return j
}

@(private)
next_rune :: proc(s: string, i: int) -> int {
	j := clamp(i, 0, len(s))
	if j >= len(s) {
		return len(s)
	}
	_, size := utf8.decode_rune_in_string(s[j:])
	return j + max(size, 1)
}

// ---- Multi-line ----

// The field's text broken into the lines it is drawn on, with a final empty line after a trailing
// line break (the caret can sit there; `text.wrap` drops it).
@(private)
input_lines :: proc(ctx: ^core.Context, st: ^Input_State, s: string, style: txt.Style, x_at: []f32) -> []txt.Line {
	width := st.wrap_width
	if width <= 0 {
		width = 240
	}
	found := txt.wrap(ctx.text, s, style, width, ctx.scale)
	out := make([dynamic]txt.Line, 0, len(found) + 1, context.temp_allocator)
	append(&out, ..found)
	if len(s) == 0 || s[len(s) - 1] == '\n' {
		x: f32 = 0
		if len(x_at) > len(s) {
			x = x_at[len(s)]
		}
		append(&out, txt.Line{start = len(s), end = len(s), x0 = x})
	}
	return out[:]
}

// The line the caret is drawn on and its x within that line, in logical pixels.
@(private)
input_caret_place :: proc(lines: []txt.Line, x_at: []f32, caret: int, scale: f32) -> (index: int, x: f32) {
	if len(lines) == 0 {
		return 0, 0
	}
	index = len(lines) - 1
	for l, i in lines {
		if caret <= l.end || (i + 1 < len(lines) && caret < lines[i + 1].start) {
			index = i
			break
		}
	}
	x = x_at[clamp(caret, 0, len(x_at) - 1)] - lines[index].x0 / scale
	return index, max(x, 0)
}

// Home and End on a multi-line field move to the edges of the visual line.
@(private)
input_line_edges :: proc(ctx: ^core.Context, st: ^Input_State, s: string, style: txt.Style, at: int) -> (start, end: int) {
	x_at := txt.caret_positions(ctx.text, s, style, ctx.scale)
	lines := input_lines(ctx, st, s, style, x_at)
	i, _ := input_caret_place(lines, x_at, at, ctx.scale)
	return lines[i].start, lines[i].end
}

// Up and Down move the caret one visual line, keeping the column where possible.
@(private)
input_vertical :: proc(ctx: ^core.Context, st: ^Input_State, style: txt.Style, up, extend: bool) -> bool {
	s := string(st.text[:])
	if len(s) == 0 {
		return false
	}
	x_at := txt.caret_positions(ctx.text, s, style, ctx.scale)
	lines := input_lines(ctx, st, s, style, x_at)
	index, x := input_caret_place(lines, x_at, st.cursor, ctx.scale)
	target := index - 1 if up else index + 1
	if target < 0 || target >= len(lines) {
		return false
	}
	l := lines[target]
	best, best_d := l.start, abs(x_at[l.start] - l.x0 / ctx.scale - x)
	for i in l.start + 1 ..= l.end {
		d := abs(x_at[i] - l.x0 / ctx.scale - x)
		if d < best_d {
			best, best_d = i, d
		}
	}
	st.cursor = snap_back(s, clamp(best, 0, len(s)))
	if !extend {
		st.anchor = st.cursor
	}
	return false
}

// ---- Drawing ----

// The byte range drawn inverted: the value's own selection, or the input method's while composing.
@(private)
input_selection :: proc(st: ^Input_State, preedit_len: int) -> (start, end: int) {
	if preedit_len > 0 {
		if st.preedit_sel[1] > st.preedit_sel[0] {
			return st.cursor + st.preedit_sel[0], st.cursor + st.preedit_sel[1]
		}
		return 0, 0
	}
	return input_bounds(st)
}

@(private)
input_draw :: proc(
	ctx: ^core.Context,
	st: ^Input_State,
	it: core.Interaction,
	shown: string,
	style: txt.Style,
	scale: f32,
	x_at: []f32,
	caret, preedit_len: int,
	box_w, box_h: f32,
	color: core.Token,
	disabled, multiline: bool,
) {
	sel_start, sel_end := input_selection(st, preedit_len)
	if multiline {
		input_draw_lines(ctx, st, it, shown, style, scale, caret, preedit_len, box_w, box_h, color, disabled, sel_start, sel_end)
		return
	}

	inner_w := max(box_w - 16, 0)
	text_w := x_at[len(shown)]
	// Keep the caret in view.
	if it.focused && inner_w > 0 {
		cx := x_at[caret]
		if cx - st.scroll > inner_w {
			st.scroll = cx - inner_w
		}
		if cx - st.scroll < 0 {
			st.scroll = cx
		}
	}
	st.scroll = clamp(st.scroll, 0, max(text_w - inner_w, 0))

	top: f32 = 4
	text_node := layout.Node {
		position = 1,
		size     = {{text_w, .Px}, {style.line_height, .Px}},
	}
	text_node.inset[0] = {8 - st.scroll, .Px}
	text_node.inset[1] = {top, .Px}
	core.leaf(ctx, core.auto_id(ctx), text_node, core.Paint_Text {
		s = shown,
		style = style,
		color = color,
		wrap = false,
		sel_start = sel_start,
		sel_end = sel_end,
	})

	// The preedit's underline, so the composition reads as not yet committed.
	if preedit_len > 0 {
		ux := x_at[st.cursor]
		uw := x_at[st.cursor + preedit_len] - ux
		ul := layout.Node {
			position = 1,
			size     = {{uw, .Px}, {1, .Px}},
		}
		ul.inset[0] = {8 + ux - st.scroll, .Px}
		ul.inset[1] = {top + style.line_height - 2, .Px}
		core.leaf(ctx, core.auto_id(ctx), ul, core.Paint_Box{fill = .Fg})
	}

	// The caret: steady, never blinking (DESIGN.md, "Performance": the frame loop is event-driven).
	if it.focused && !disabled {
		cx := x_at[caret]
		caret_node := layout.Node {
			position = 1,
			size     = {{1, .Px}, {style.line_height, .Px}},
		}
		caret_node.inset[0] = {8 + cx - st.scroll, .Px}
		caret_node.inset[1] = {top, .Px}
		core.leaf(ctx, core.auto_id(ctx), caret_node, core.Paint_Box{fill = .Fg})
	}
}

// The multi-line field: the text wrapped to the field's width, scrolled down to the caret.
@(private)
input_draw_lines :: proc(
	ctx: ^core.Context,
	st: ^Input_State,
	it: core.Interaction,
	shown: string,
	style: txt.Style,
	scale: f32,
	caret, preedit_len: int,
	box_w, box_h: f32,
	color: core.Token,
	disabled: bool,
	sel_start, sel_end: int,
) {
	inner_w := max(box_w - 16, 1)
	inner_h := max(box_h - 8, style.line_height)
	st.wrap_width = inner_w
	x_at := txt.caret_positions(ctx.text, shown, style, scale)
	lines := input_lines(ctx, st, shown, style, x_at)
	content_h := f32(len(lines)) * style.line_height
	caret_line, caret_x := input_caret_place(lines, x_at, caret, scale)
	// Keep the caret's line in view.
	if it.focused {
		line_top := f32(caret_line) * style.line_height
		if line_top - st.scroll + style.line_height > inner_h {
			st.scroll = line_top + style.line_height - inner_h
		}
		if line_top - st.scroll < 0 {
			st.scroll = line_top
		}
	}
	st.scroll = clamp(st.scroll, 0, max(content_h - inner_h, 0))

	// One wrapped node for the whole value: wrapping and the inverted selection are drawn together,
	// so a selection that crosses a line break stays continuous.
	text_node := layout.Node {
		position = 1,
		size     = {{inner_w, .Px}, {content_h, .Px}},
	}
	text_node.inset[0] = {8, .Px}
	text_node.inset[1] = {4 - st.scroll, .Px}
	core.leaf(ctx, core.auto_id(ctx), text_node, core.Paint_Text {
		s = shown,
		style = style,
		color = color,
		wrap = true,
		sel_start = sel_start,
		sel_end = sel_end,
	})

	if preedit_len > 0 {
		start_line, start_x := input_caret_place(lines, x_at, st.cursor, scale)
		end_line, end_x := input_caret_place(lines, x_at, st.cursor + preedit_len, scale)
		if end_line != start_line {
			l := lines[start_line]
			end_x = x_at[l.end] - l.x0 / scale
		}
		ul := layout.Node {
			position = 1,
			size     = {{max(end_x - start_x, 1), .Px}, {1, .Px}},
		}
		ul.inset[0] = {8 + start_x, .Px}
		ul.inset[1] = {4 + f32(start_line) * style.line_height + style.line_height - 2 - st.scroll, .Px}
		core.leaf(ctx, core.auto_id(ctx), ul, core.Paint_Box{fill = .Fg})
	}

	if it.focused && !disabled {
		caret_node := layout.Node {
			position = 1,
			size     = {{1, .Px}, {style.line_height, .Px}},
		}
		caret_node.inset[0] = {8 + caret_x, .Px}
		caret_node.inset[1] = {4 + f32(caret_line) * style.line_height - st.scroll, .Px}
		core.leaf(ctx, core.auto_id(ctx), caret_node, core.Paint_Box{fill = .Fg})
	}
}

// Tells the platform where the text being edited is, so the input method's candidate window follows
// the caret.
@(private)
input_announce :: proc(ctx: ^core.Context, r: Rect, x_at: []f32, caret: int, scroll: f32) {
	w := current_window()
	if w.p == nil {
		return
	}
	platform.set_text_input_area(w.p, {r.x, r.y, r.w, r.h}, x_at[caret] - scroll + 8)
}
