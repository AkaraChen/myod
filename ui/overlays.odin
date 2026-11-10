// Overlay components of the shadcn/ui set: Hover Card, Context Menu, Menubar, Navigation Menu,
// Select, Combobox, Alert Dialog, Sheet and Drawer. Popover, Dropdown Menu, Dialog and Tooltip live
// in layers.odin; these build on the same layer machinery, so every one of them traps focus where it
// is modal, closes on Esc and on a click outside, and returns focus to its trigger.
package ui

import "core:strings"
import "core:time"

import "../core"
import ph "../icons/phosphor"
import "../layout"
import "../platform"

// ---- Shared pieces ----

@(private)
TRIGGER_HEIGHT :: f32(28)

// The button-shaped trigger of a Select, Combobox or Date Picker: 28px tall, a 1px border, the value
// on the left and a caret on the right. `width` is applied through the layout item.
@(private)
trigger_node :: proc(ctx: ^core.Context, width: Size) -> layout.Node {
	ln := layout.Node {
		flex_direction = .Row,
		align_items    = .Center,
		gap            = {6, 6},
		size           = {{0, .Auto}, {TRIGGER_HEIGHT, .Px}},
		padding        = {8, 8, 0, 0},
		flex_shrink    = 0,
	}
	item(ctx, &ln, width, {})
	return ln
}

@(private)
trigger_box :: proc(hovered, open, disabled: bool) -> core.Paint {
	if disabled {
		return core.Paint_Box{border = .Border, border_width = 1}
	}
	if open || hovered {
		return core.Paint_Box{border = .Border_Strong, border_width = 1, fill = .Overlay}
	}
	return core.Paint_Box{border = .Border, border_width = 1}
}

// The option rows inside a Select or Combobox popup: 28px, 8px padding, a check on the left when
// chosen, and the highlighted row filled. Returns the response and whether it was picked.
@(private)
option_row :: proc(
	id: Id,
	label: string,
	chosen, disabled: bool,
	highlight: bool,
	label_style: Text_Style = .Compact,
) -> (Response, bool) {
	ctx := core.current()
	it := core.interact(ctx, id)
	ln := layout.Node {
		flex_direction = .Row,
		align_items    = .Center,
		gap            = {8, 8},
		size           = {{0, .Auto}, {28, .Px}},
		padding        = {8, 8, 0, 0},
		flex_shrink    = 0,
	}
	flags := core.Node_Flags{.Hit, .Focusable, .Activate}
	if disabled {
		flags += {.Disabled}
	}
	paint: core.Paint
	if highlight || it.focused {
		paint = core.Paint_Box{fill = .Overlay_Hover}
	} else if it.hovered {
		paint = core.Paint_Box{fill = .Overlay}
	}
	opened := core.open(ctx, id, ln, paint, label = label, flags = flags)
	if opened {
		core.set_a11y_role(ctx, id, .Option)
		if chosen {
			core.set_a11y_state(ctx, id, {.Selected})
		}
		check := layout.Node{size = {{14, .Px}, {14, .Px}}}
		if chosen {
			core.leaf(ctx, core.auto_id(ctx), check, core.Paint_Icon {
				icon = ph.CHECK,
				weight = .Bold,
				color = .Fg,
			})
		} else {
			core.leaf(ctx, core.auto_id(ctx), check, nil)
		}
		lbl := layout.Node{flex_grow = 1, flex_shrink = 1, flex_basis = {0, .Px}}
		core.leaf(ctx, core.auto_id(ctx), lbl, core.Paint_Text {
			s = label,
			style = text_style(label_style),
			color = .Fg,
			wrap = false,
		}, measured = true)
	}
	core.close(ctx)
	res := response_interactive(ctx, id, disabled)
	return res, res.clicked
}

// Restores focus to the trigger a popup was opened from.
@(private)
close_popup :: proc(ctx: ^core.Context, opener: Id) {
	if opener != 0 {
		core.set_focus(ctx, opener, true)
	}
}

// ---- Hover Card ----

@(private)
HOVER_CARD_DELAY_MS :: u64(300)

@(private)
Hover_Card_State :: struct {
	since: u64, // when this hover began; 0: not hovering
}

// A card with a title and a paragraph, shown below the widget it describes after the pointer (or
// keyboard focus) has rested on it for a moment. Like a tooltip it takes no input and closes
// itself, so it works from the keyboard too: focus the trigger, and the card appears.
hover_card :: proc(anchor: Response, title, body: string, key := "") {
	if title == "" && body == "" {
		return
	}
	ctx := core.current()
	k := key
	if k == "" {
		k = title
	}
	st, _ := core.state(ctx, core.key_id(ctx, k), Hover_Card_State)
	now := platform.ticks_ms()
	if !anchor.hovered && !anchor.focused {
		st.since = 0
		return
	}
	if st.since == 0 {
		st.since = now
	}
	waited := now - st.since
	if waited < HOVER_CARD_DELAY_MS {
		request_redraw(time.Duration(HOVER_CARD_DELAY_MS - waited) * time.Millisecond)
		return
	}
	id := core.key_id(ctx, k)
	o := core.Layer_Options{anchor = anchor.rect, gap = 6, align = 0, no_input = true}
	style := layer_style({min_width = 280, padding = 12, gap = 6})
	if core.open_layer(ctx, id, style, layer_paint(), o, label = title) {
		if title != "" {
			text(title, .Label)
		}
		if body != "" {
			text(body, .Compact, .Muted, width = fixed(280))
		}
	}
	core.close(ctx)
}

// ---- Context Menu ----

// A menu opened by a right click at `at`, in root coordinates. The app owns `open` and clears it
// through `close`; contents are `menu_item`s declared inside the `if`.
@(deferred_out = layer_close)
context_menu :: proc(d: Dispatch($M), close: M, open: bool, at: Rect, key := "context-menu") -> bool {
	ctx := core.current()
	id := layer_id(ctx, key)
	if !open {
		core.open(ctx, id, layout.Node{position = 1}, nil, cull = false)
		return false
	}
	o := core.Layer_Options{anchor = at, gap = 0, align = 0, menu = true}
	if !core.open_layer(ctx, id, layer_style({min_width = 200, padding = 4, gap = 0}), layer_paint(), o) {
		return false
	}
	layer_session(ctx, id)
	layer_close_check(ctx, d, id, close)
	return true
}

// The trigger the pointer is over on the previous pass (index + 1; 0: none). A menu switches to a
// trigger when the pointer enters it, not on every pass: a ghost pass or a message rerun must not
// pull the menu back to the trigger the pointer happens to rest on.
@(private)
Bar_State :: struct {
	hover: int,
}

// The trigger bar shared by Menubar and Navigation Menu: returns the menu that should be open now,
// and each trigger's rect (in root coordinates, valid this frame) so the app can anchor the panels.
@(private)
bar_triggers :: proc(
	open: int,
	labels: []string,
	key: string,
	bar_role: core.Role,
	caret: bool,
) -> (int, []Rect) {
	ctx := core.current()
	rects := make([]Rect, len(labels), context.temp_allocator)
	chosen := open
	hovered := 0
	ln := layout.Node {
		flex_direction = .Row,
		align_items    = .Center,
		gap            = {2, 2},
		size           = {{0, .Auto}, {32, .Px}},
		padding        = {4, 4, 0, 0},
	}
	bar_id := core.key_id(ctx, key)
	if !core.open(ctx, bar_id, ln, nil, label = key) {
		core.close(ctx)
		return chosen, rects
	}
	core.set_a11y_role(ctx, bar_id, bar_role)
	for label, i in labels {
		id := core.key_id_int(ctx, i)
		it := core.interact(ctx, id)
		active := i == open
		paint: core.Paint
		if it.hovered || it.focused || active {
			paint = core.Paint_Box{fill = .Overlay}
		}
		t := layout.Node {
			flex_direction = .Row,
			align_items    = .Center,
			gap            = {4, 4},
			size           = {{0, .Auto}, {32, .Px}},
			padding        = {10, 10, 0, 0},
		}
		if core.open(ctx, id, t, paint, label = label, flags = {.Hit, .Focusable, .Activate}) {
			lbl := layout.Node{}
			core.leaf(ctx, core.auto_id(ctx), lbl, core.Paint_Text {
				s     = label,
				style = text_style(.Compact),
				color = .Fg,
				wrap  = false,
			}, measured = true)
			if caret {
				c := layout.Node{size = {{10, .Px}, {10, .Px}}}
				core.leaf(ctx, core.auto_id(ctx), c, core.Paint_Icon {
					icon = ph.CARET_DOWN,
					weight = .Bold,
					color = .Muted,
				})
			}
			if active {
				core.set_a11y_state(ctx, id, {.Expanded, .Selected})
			}
		}
		core.close(ctx)
		if r, ok := core.last_rect(ctx, id); ok {
			rects[i] = r
		}
		if it.clicked {
			chosen = -1 if active else i
		}
		if it.hovered {
			hovered = i + 1
		}
		// Left/Right move between triggers and keep a menu open on the new one.
		if it.focused {
			moved := -1
			for e in core.take_keys(ctx, id) {
				if e.kind != .Key_Down {
					continue
				}
				#partial switch e.key {
				case .Left:
					moved = (i - 1 + len(labels)) % len(labels)
				case .Right:
					moved = (i + 1) % len(labels)
				}
			}
			if moved >= 0 {
				core.set_focus(ctx, core.key_id_int(ctx, moved), true)
				if open >= 0 {
					chosen = moved
				}
			}
		}
	}
	// Left/Right inside the open menu: show the menu of the trigger next to it. Only when the menu is
	// anchored at one of this bar's triggers, so a menu opened elsewhere leaves the bar alone.
	if step := core.menu_step(ctx); step != 0 && open >= 0 && open < len(labels) {
		// The menu on screen was declared by the previous pass, before this bar ran.
		for l in ctx.layers_prev {
			if l.menu && l.anchor == rects[open] {
				chosen = (open + step + len(labels)) % len(labels)
				break
			}
		}
	}
	core.close(ctx)
	// While a menu is open, moving the pointer onto another trigger switches to it, as menus do.
	st, _ := core.state(ctx, bar_id, Bar_State)
	if hovered != st.hover {
		if open >= 0 && hovered != 0 && chosen == open {
			chosen = hovered - 1
		}
		st.hover = hovered
	}
	return chosen, rects
}

// ---- Menubar ----

// A horizontal bar of menu triggers (File, Edit, …). The app owns which menu is open (`open`, -1 for
// none) and anchors each menu's `popover` at the returned rect. Clicking a trigger, Left/Right and
// hovering another trigger while a menu is open all work; the bar returns the menu that should be
// open now.
menubar :: proc(open: int, labels: []string, key := "menubar") -> (int, []Rect) {
	return bar_triggers(open, labels, key, .Menu_Bar, false)
}

// ---- Navigation Menu ----

// A navigation bar whose items open a panel below them. Same contract as `menubar`, with carets to
// show the panels, and the role a screen reader announces as navigation.
navigation_menu :: proc(open: int, labels: []string, key := "navigation") -> (int, []Rect) {
	return bar_triggers(open, labels, key, .Navigation, true)
}

// ---- Select ----

Select_Option :: struct {
	value:    string,
	label:    string,
	disabled: bool,
}

@(private)
Select_State :: struct {
	open:      bool,
	opener:    Id,
	highlight: int, // the option the arrows are on; -1: none
	frame:     u64, // the frame its click was applied in: a ghost pass must not toggle it twice
}

// The next enabled option from `from` in direction `dir`; `from` itself when there is none.
@(private)
next_option :: proc(options: []Select_Option, from, dir: int) -> int {
	if len(options) == 0 {
		return -1
	}
	for i := from + dir; i >= 0 && i < len(options); i += dir {
		if !options[i].disabled {
			return i
		}
	}
	return clamp(from, 0, len(options) - 1)
}

// A single-choice select: a trigger showing the current value, and a listbox below it. Controlled:
// returns the value that should now be selected (the old one when nothing was chosen). Open state,
// Esc, clicks outside and the return of focus to the trigger are handled here.
select :: proc(
	value: string,
	options: []Select_Option,
	key := "",
	width: Size = {},
	disabled := false,
) -> (Response, string) {
	ctx := core.current()
	id := layer_id(ctx, key)
	st, _ := core.state(ctx, id, Select_State)
	it := core.interact(ctx, id)

	shown := "Select…"
	chosen_label := ""
	for o in options {
		if o.value == value {
			shown = o.label
			chosen_label = o.label
			break
		}
	}
	if chosen_label == "" {
		chosen_label = shown
	}

	ln := trigger_node(ctx, width)
	flags := core.Node_Flags{.Hit, .Focusable, .Activate}
	if disabled {
		flags += {.Disabled}
	}
	if core.open(ctx, id, ln, trigger_box(it.hovered, st.open, disabled), label = chosen_label, flags = flags) {
		lbl := layout.Node{flex_grow = 1, flex_shrink = 1, flex_basis = {0, .Px}}
		core.leaf(ctx, core.auto_id(ctx), lbl, core.Paint_Text {
			s     = shown,
			style = text_style(.Compact),
			color = .Fg if value != "" else .Faint,
			wrap  = false,
		}, measured = true)
		caret := layout.Node{size = {{14, .Px}, {14, .Px}}}
		core.leaf(ctx, core.auto_id(ctx), caret, core.Paint_Icon {
			icon = ph.CARET_DOWN,
			weight = .Bold,
			color = .Muted,
		})
		if st.open {
			core.set_a11y_state(ctx, id, {.Expanded})
		}
	}
	core.close(ctx)
	res := response_interactive(ctx, id, disabled)
	next_value := value
	// The trigger keeps the keyboard focus while the list is open, so it also reads the arrows and
	// Enter: Down/Up move the highlight, Home/End go to the ends and Enter picks. (Items that took
	// the focus themselves are handled by the menu layer's own arrow movement.)
	key_pick := false
	if st.open && !disabled && it.focused {
		for e in core.take_keys(ctx, id) {
			if e.kind != .Key_Down || e.repeat {
				continue
			}
			#partial switch e.key {
			case .Down:
				st.highlight = next_option(options, st.highlight, 1)
			case .Up:
				st.highlight = next_option(options, st.highlight, -1)
			case .Home:
				st.highlight = next_option(options, -1, 1)
			case .End:
				st.highlight = next_option(options, len(options), -1)
			case .Enter, .Space:
				key_pick = true
			}
		}
	}
	if !disabled && it.clicked && !key_pick && st.frame != ctx.frame {
		st.frame = ctx.frame
		st.open = !st.open
		if st.open {
			st.opener = id
			st.highlight = -1
			for o, i in options {
				if o.value == value && !o.disabled {
					st.highlight = i
					break
				}
			}
			if st.highlight < 0 {
				st.highlight = next_option(options, -1, 1)
			}
		}
	}
	if key_pick {
		if st.highlight >= 0 && st.highlight < len(options) && !options[st.highlight].disabled {
			next_value = options[st.highlight].value
			res.changed = true
		} else {
			res.cancelled = true
		}
		st.open = false
		st.opener = 0
	}

	if st.open && !disabled {
		trig, _ := core.last_rect(ctx, id)
		lid := core.key_id(ctx, "\x00listbox")
		o := core.Layer_Options{anchor = trig, gap = 4, align = 0, menu = true}
		style := layer_style({min_width = max(trig.w, 180), padding = 4, gap = 0})
		if core.open_layer(ctx, lid, style, layer_paint(), o, label = shown) {
			core.set_a11y_role(ctx, lid, .List_Box)
			layer_session(ctx, lid, st.highlight)
			picked := ""
			for opt, i in options {
				_, clicked := option_row(core.key_id_int(ctx, i), opt.label, opt.value == value, opt.disabled, i == st.highlight)
				if clicked && !opt.disabled {
					picked = opt.value
				}
			}
			if picked != "" {
				st.open = false
				next_value = picked
				res.changed = true
			} else if core.take_escape(ctx, lid) || core.take_click_outside(ctx, lid) {
				st.open = false
				res.cancelled = true
				// The pass already declared the popup: rerun it so the tree and the screen drop it
				// now, not on whatever redraw comes next.
				core.unsettle(ctx)
			}
			if !st.open {
				close_popup(ctx, st.opener)
				st.opener = 0
			}
		}
		core.close(ctx)
	}
	return res, next_value
}

// ---- Combobox ----

@(private)
Combobox_State :: struct {
	open:      bool,
	opener:    Id,
	query:     string,
	highlight: int,
	frame:     u64, // the frame its click was applied in: a ghost pass must not toggle it twice
}

@(private)
combobox_state_free :: proc(p: rawptr) {
	st := (^Combobox_State)(p)
	delete(st.query)
}

@(private)
ascii_lower :: proc(c: u8) -> u8 {
	if c >= 'A' && c <= 'Z' {
		return c + ('a' - 'A')
	}
	return c
}

// Case-insensitive substring match, for filtering a combobox's options.
@(private)
contains_fold :: proc(haystack, needle: string) -> bool {
	if len(needle) == 0 {
		return true
	}
	if len(needle) > len(haystack) {
		return false
	}
	for i in 0 ..= len(haystack) - len(needle) {
		ok := true
		for j in 0 ..< len(needle) {
			if ascii_lower(haystack[i + j]) != ascii_lower(needle[j]) {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}

// A searchable select: a trigger, and a popup with a search field over a scrolling option list.
// Controlled like `select`. Typing filters the options, Up/Down move the highlight, Enter picks it,
// Esc or a click outside closes and returns focus to the trigger.
combobox :: proc(
	value: string,
	options: []Select_Option,
	key := "",
	width: Size = {},
	disabled := false,
) -> (Response, string) {
	ctx := core.current()
	id := layer_id(ctx, key)
	st, created := core.state(ctx, id, Combobox_State)
	if created {
		core.set_state_free(ctx, id, combobox_state_free)
	}
	it := core.interact(ctx, id)
	shown := "Select…"
	chosen_label := ""
	for o in options {
		if o.value == value {
			shown = o.label
			chosen_label = o.label
			break
		}
	}
	if chosen_label == "" {
		chosen_label = shown
	}

	ln := trigger_node(ctx, width)
	flags := core.Node_Flags{.Hit, .Focusable, .Activate}
	if disabled {
		flags += {.Disabled}
	}
	if core.open(ctx, id, ln, trigger_box(it.hovered, st.open, disabled), label = chosen_label, flags = flags) {
		lbl := layout.Node{flex_grow = 1, flex_shrink = 1, flex_basis = {0, .Px}}
		core.leaf(ctx, core.auto_id(ctx), lbl, core.Paint_Text {
			s     = shown,
			style = text_style(.Compact),
			color = .Fg if value != "" else .Faint,
			wrap  = false,
		}, measured = true)
		chev := layout.Node{size = {{14, .Px}, {14, .Px}}}
		core.leaf(ctx, core.auto_id(ctx), chev, core.Paint_Icon {
			icon = ph.CARET_UP if st.open else ph.CARET_DOWN,
			weight = .Bold,
			color = .Muted,
		})
		if st.open {
			core.set_a11y_state(ctx, id, {.Expanded})
		}
	}
	core.close(ctx)
	res := response_interactive(ctx, id, disabled)
	next_value := value
	if !disabled && it.clicked && st.frame != ctx.frame {
		st.frame = ctx.frame
		st.open = !st.open
		if st.open {
			st.opener = id
			delete(st.query)
			st.query = ""
			st.highlight = 0
		}
	}

	if st.open && !disabled {
		trig, _ := core.last_rect(ctx, id)
		lid := core.key_id(ctx, "\x00popup")
		o := core.Layer_Options{anchor = trig, gap = 4, align = 0}
		style := layer_style({min_width = max(trig.w, 240), padding = 8, gap = 6})
		if core.open_layer(ctx, lid, style, layer_paint(), o, label = shown) {
			layer_session(ctx, lid)
			// The search field's arrows move the highlight; read them before the field takes the keys.
			sid := input_id(ctx, "Search", "search")
			up, down := false, false
			for e in core.keys(ctx, sid) {
				if e.kind != .Key_Down || e.repeat {
					continue
				}
				#partial switch e.key {
				case .Up:
					up = true
				case .Down:
					down = true
				}
			}
			q := st.query
			input_res, q2 := text_input("Search", q, width = percent(1), hide_label = true, key = "search")
			if q2 != q {
				delete(st.query)
				st.query = strings.clone(q2)
				st.highlight = 0
			}
			// The options that match the query.
			shown_options := make([dynamic]int, 0, len(options), context.temp_allocator)
			for opt, i in options {
				if contains_fold(opt.label, st.query) {
					append(&shown_options, i)
				}
			}
			if len(shown_options) > 0 {
				st.highlight = clamp(st.highlight, 0, len(shown_options) - 1)
			} else {
				st.highlight = 0
			}
			if up && len(shown_options) > 0 {
				st.highlight = (st.highlight - 1 + len(shown_options)) % len(shown_options)
			}
			if down && len(shown_options) > 0 {
				st.highlight = (st.highlight + 1) % len(shown_options)
			}
			h := min(f32(len(shown_options)) * 28 + 4, 220)
			picked := ""
			if scroll({height = fixed(max(h, 28)), width = percent(1), gap = 0}) {
				if len(shown_options) == 0 {
					text("No matches", .Metadata, .Faint)
				}
				for oi, k in shown_options {
					opt := options[oi]
					_, clicked := option_row(core.key_id_int(ctx, oi), opt.label, opt.value == value, opt.disabled, k == st.highlight)
					if clicked && !opt.disabled {
						picked = opt.value
					}
				}
			}
			if input_res.submitted && len(shown_options) > 0 {
				opt := options[shown_options[st.highlight]]
				if !opt.disabled {
					picked = opt.value
				}
			}
			if picked != "" {
				st.open = false
				next_value = picked
				res.changed = true
			} else if core.take_escape(ctx, lid) || core.take_click_outside(ctx, lid) {
				st.open = false
				res.cancelled = true
				// The pass already declared the popup: rerun it so the tree and the screen drop it
				// now, not on whatever redraw comes next.
				core.unsettle(ctx)
			}
			if !st.open {
				close_popup(ctx, st.opener)
				st.opener = 0
			}
		}
		core.close(ctx)
	}
	return res, next_value
}

// ---- Alert Dialog ----

// A modal confirmation: title, description, a cancel button (focused first) and a confirm button.
// The app owns `open` and gets back which button was used. Esc and a click outside cancel.
alert_dialog :: proc(
	d: Dispatch($M),
	close: M,
	open: bool,
	title: string,
	description := "",
	confirm_label := "Continue",
	cancel_label := "Cancel",
	danger := false,
) -> (confirmed, cancelled: bool) {
	if !open {
		return
	}
	ctx := core.current()
	id := layer_id(ctx, "alert-dialog")
	o := core.Layer_Options{modal = true, center = true}
	style := layer_style({min_width = 400, padding = 20, gap = 12})
	if !core.open_layer(ctx, id, style, layer_paint(), o, label = title) {
		return
	}
	core.set_a11y_role(ctx, id, .Alert_Dialog)
	layer_session(ctx, id)
	layer_close_check(ctx, d, id, close)
	if title != "" {
		text(title, .Subsection)
	}
	if description != "" {
		text(description, .Compact, .Muted)
	}
	if row({gap = 8, align_y = .Center, width = grow()}) {
		spacer()
		if b := button(cancel_label, variant = .Outline); b.clicked {
			cancelled = true
			dispatch(d, close)
			core.restore_layer_focus(ctx)
		}
		if b := button(confirm_label, variant = .Danger if danger else .Primary); b.clicked {
			confirmed = true
			dispatch(d, close)
			core.restore_layer_focus(ctx)
		}
	}
	core.close(ctx)
	return
}

// ---- Sheet and Drawer ----

Sheet_Side :: enum {
	Left,
	Right,
	Top,
	Bottom,
}

@(private)
sheet_edge :: proc(side: Sheet_Side) -> core.Layer_Edge {
	switch side {
	case .Left:
		return .Left
	case .Right:
		return .Right
	case .Top:
		return .Top
	case .Bottom:
		return .Bottom
	}
	return .Right
}

// A modal panel attached to a window edge. It appears instantly (no slide-in). The app owns `open`
// and declares the contents inside the `if`; Esc and a click outside close it through `close`.
@(deferred_out = layer_close)
sheet :: proc(
	d: Dispatch($M),
	close: M,
	open: bool,
	side: Sheet_Side,
	title := "",
	extent: f32 = 360,
	key := "sheet",
) -> bool {
	ctx := core.current()
	id := layer_id(ctx, key)
	if !open {
		core.open(ctx, id, layout.Node{position = 1}, nil, cull = false)
		return false
	}
	style := layer_style({padding = 20, gap = 12})
	switch side {
	case .Left, .Right:
		style.size[0] = {extent, .Px}
	case .Top, .Bottom:
		style.size[1] = {extent, .Px}
	}
	o := core.Layer_Options{modal = true, edge = sheet_edge(side)}
	if !core.open_layer(ctx, id, style, layer_paint(), o, label = title) {
		return false
	}
	layer_session(ctx, id)
	layer_close_check(ctx, d, id, close)
	if title != "" {
		text(title, .Subsection)
	}
	return true
}

// A Drawer: a sheet that comes up from the bottom of the window with a grab handle, as shadcn's
// Drawer does. It appears instantly, like every other overlay here.
@(deferred_out = layer_close)
drawer :: proc(d: Dispatch($M), close: M, open: bool, title := "", extent: f32 = 320, key := "drawer") -> bool {
	ctx := core.current()
	id := layer_id(ctx, key)
	if !open {
		core.open(ctx, id, layout.Node{position = 1}, nil, cull = false)
		return false
	}
	style := layer_style({padding = 20, gap = 12})
	style.size[1] = {extent, .Px}
	style.align_items = .Center
	o := core.Layer_Options{modal = true, edge = .Bottom}
	if !core.open_layer(ctx, id, style, layer_paint(), o, label = title) {
		return false
	}
	layer_session(ctx, id)
	layer_close_check(ctx, d, id, close)
	// The 32×4 grab handle, then the content.
	handle := layout.Node{size = {{32, .Px}, {4, .Px}}}
	core.leaf(ctx, core.auto_id(ctx), handle, core.Paint_Box{fill = .Border_Strong})
	if title != "" {
		text(title, .Subsection)
	}
	return true
}
