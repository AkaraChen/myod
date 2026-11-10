// Form components of the shadcn/ui set: Field, Input OTP, Calendar and Date Picker. The date types
// are the library's own (a year, a month and a day), so apps need no time library to use them.
package ui

import "core:fmt"
import "core:time"

import "../core"
import ph "../icons/phosphor"
import "../layout"

// ---- Field ----

Field :: struct {
	open:        bool,
	description: string,
	error:       string,
}

@(private)
field_close :: proc(f: Field) {
	if f.open {
		// The description or the error goes below the control, as shadcn does; the error replaces
		// the description and is announced as the field's error color.
		if f.error != "" {
			text(f.error, .Metadata, .Error)
		} else if f.description != "" {
			text(f.description, .Metadata, .Muted)
		}
	}
	core.close(core.current())
}

// A form field: its label above the control, and its description (or error) below it. Declare the
// control inside the `if`; name the control with the same label so screen readers associate them.
@(deferred_out = field_close)
field :: proc(label: string, description := "", error := "", key := "") -> Field {
	ctx := core.current()
	id, display := named_id(ctx, key, label)
	ln := layout.Node {
		flex_direction = .Column,
		gap            = {6, 6},
		align_self     = .Stretch,
	}
	open := core.open(ctx, id, ln, nil, label = display)
	if open {
		lbl := layout.Node{}
		core.leaf(ctx, core.auto_id(ctx), lbl, core.Paint_Text {
			s     = display,
			style = text_style(.Label),
			color = .Fg if error == "" else .Error,
			wrap  = false,
		}, measured = true)
	}
	return {open = open, description = description, error = error}
}

// ---- Input OTP ----

// One digit per cell. Typing fills the cell under the caret and moves to the next; Backspace on an
// empty cell moves back; Left/Right move between cells. Controlled: returns the code, which always
// holds one character per filled cell.
input_otp :: proc(value: string, length := 6, key := "otp", disabled := false) -> (Response, string) {
	ctx := core.current()
	group := core.key_id(ctx, key)
	res := Response{id = group}
	cells := make([]u8, length, context.temp_allocator)
	copy(cells, value[:min(len(value), length)])
	next := make([]u8, length, context.temp_allocator)
	copy(next, cells)
	changed := false

	ln := layout.Node {
		flex_direction = .Row,
		align_items    = .Center,
		gap            = {8, 8},
		size           = {{0, .Auto}, {28, .Px}},
	}
	if core.open(ctx, group, ln, nil, label = "Verification code") {
		for i in 0 ..< length {
			cell_key := fmt.tprintf("%s/%d", key, i)
			cid := core.key_id(ctx, cell_key)
			// Read the cell's navigation keys before the field consumes them.
			back, left, right := false, false, false
			for e in core.keys(ctx, cid) {
				if e.kind != .Key_Down || e.repeat {
					continue
				}
				#partial switch e.key {
				case .Backspace:
					if cells[i] == 0 {
						back = true
					}
				case .Left:
					left = true
				case .Right:
					right = true
				}
			}
			s := ""
			if cells[i] != 0 {
				s = string(cells[i:i + 1])
			}
			qr, q := text_input(
				fmt.tprintf("Digit %d of %d", i + 1, length),
				s,
				width = fixed(36),
				hide_label = true,
				key = cell_key,
				disabled = disabled,
			)
			// Only a real edit counts: on a ghost pass the cell's own text still holds what the
			// application is about to replace, and trusting it would undo a Backspace.
			if qr.changed {
				if len(q) > 0 {
					// The cell holds one character: the last one typed (typing into a filled cell
					// replaces it on the next pass).
					c := q[len(q) - 1]
					if c != next[i] {
						next[i] = c
						changed = true
						if i + 1 < length {
							core.set_focus(ctx, core.key_id(ctx, fmt.tprintf("%s/%d", key, i + 1)), true)
						}
					}
				} else if next[i] != 0 {
					next[i] = 0
					changed = true
				}
			}
			if left && i > 0 && !changed {
				core.set_focus(ctx, core.key_id(ctx, fmt.tprintf("%s/%d", key, i - 1)), true)
			}
			if right && i + 1 < length && !changed {
				core.set_focus(ctx, core.key_id(ctx, fmt.tprintf("%s/%d", key, i + 1)), true)
			}
			if back && i > 0 {
				next[i - 1] = 0
				changed = true
				core.set_focus(ctx, core.key_id(ctx, fmt.tprintf("%s/%d", key, i - 1)), true)
			}
		}
	}
	core.close(ctx)
	res.changed = changed
	if changed {
		out := make([dynamic]u8, 0, length, context.temp_allocator)
		for c in next {
			if c != 0 {
				append(&out, c)
			}
		}
		return res, string(out[:])
	}
	return res, value
}

// ---- Dates ----

// A calendar date. `month` is 1..12. The zero value is not a date.
Date :: struct {
	year, month, day: int,
}

@(private)
MONTH_NAMES := [12]string{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}

@(private)
MONTH_ABBREV := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

// "Nov 10, 2026", or "" for the zero date.
date_format :: proc(d: Date) -> string {
	if d.year == 0 || d.month < 1 || d.month > 12 {
		return ""
	}
	return fmt.tprintf("%s %d, %d", MONTH_ABBREV[d.month - 1], d.day, d.year)
}

@(private)
is_leap :: proc(y: int) -> bool {
	return y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
}

@(private)
days_in_month :: proc(y, m: int) -> int {
	switch m {
	case 2:
		return 29 if is_leap(y) else 28
	case 4, 6, 9, 11:
		return 30
	}
	return 31
}

// Day of the week, 0 = Sunday (Sakamoto's method).
@(private)
day_of_week :: proc(y, m, d: int) -> int {
	t := [12]int{0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4}
	yy := y
	if m < 3 {
		yy -= 1
	}
	return (yy + yy / 4 - yy / 100 + yy / 400 + t[m - 1] + d) % 7
}

// The date `days` after `d` (negative goes back), normalizing the month and year.
date_add_days :: proc(d: Date, days: int) -> Date {
	out := d
	out.day += days
	for out.day > days_in_month(out.year, out.month) {
		out.day -= days_in_month(out.year, out.month)
		out.month += 1
		if out.month > 12 {
			out.month = 1
			out.year += 1
		}
	}
	for out.day < 1 {
		out.month -= 1
		if out.month < 1 {
			out.month = 12
			out.year -= 1
		}
		out.day += days_in_month(out.year, out.month)
	}
	return out
}

// The first of the month `delta` months from `d`'s month.
date_add_months :: proc(d: Date, delta: int) -> Date {
	total := d.year * 12 + (d.month - 1) + delta
	return {year = total / 12, month = total % 12 + 1, day = 1}
}

// The date cells' IDs are derived from the date and the calendar's own ID, so focus survives month
// changes and does not depend on which week row the day happens to fall in.
@(private)
date_id :: proc(base: core.Id, d: Date) -> Id {
	key := 2000000 + d.year * 10000 + d.month * 100 + d.day
	return core.Id(core.mix(core.mix(u64(base), 0x646179), u64(key)))
}

// The result of a calendar interaction: the month to show, the date to select, and whether the user
// picked one this frame.
Calendar_Result :: struct {
	month:  Date,
	date:   Date,
	picked: bool,
}

// A month grid: previous/next month, the month's name, the weekday header, and six weeks of days
// (the days outside the month faint). Controlled: `month` is what to show, `selected` what is
// chosen; the result carries the month and date that should hold now. Arrow keys move the focused
// day by a day or a week, and across month boundaries.
calendar :: proc(month, selected: Date, key := "calendar") -> Calendar_Result {
	ctx := core.current()
	m := month
	if m.year == 0 || m.month < 1 || m.month > 12 {
		if selected.year != 0 {
			m = selected
		} else {
			m = {2026, 11, 1}
		}
	}
	m.day = 1
	out := Calendar_Result{month = m, date = selected}
	base := core.key_id(ctx, key)

	ln := layout.Node {
		flex_direction = .Column,
		gap            = {6, 6},
		size           = {{232, .Px}, {0, .Auto}},
	}
	if core.open(ctx, base, ln, nil, label = "Calendar") {
		core.set_a11y_role(ctx, base, .Group)
		if row({align_y = .Center, width = grow(), gap = 4}) {
			if b := icon_button(ph.CARET_LEFT, "Previous month", .Ghost, .Small); b.clicked {
				out.month = date_add_months(m, -1)
			}
			spacer()
			text(fmt.tprintf("%s %d", MONTH_NAMES[m.month - 1], m.year), .Compact, .Fg, wrap = false)
			spacer()
			if b := icon_button(ph.CARET_RIGHT, "Next month", .Ghost, .Small); b.clicked {
				out.month = date_add_months(m, 1)
			}
		}
		// The weekday header, Monday first.
		if row({width = grow(), gap = 2, align_y = .Center}) {
			for wd in 0 ..< 7 {
				names := [7]string{"Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"}
				cell := layout.Node{size = {{32, .Px}, {20, .Px}}, justify_content = .Center, align_items = .Center}
				core.leaf(ctx, core.key_id_int(ctx, 100 + wd), cell, core.Paint_Text {
					s     = names[wd],
					style = text_style(.Metadata),
					color = .Faint,
					wrap  = false,
				}, measured = true)
			}
		}
		// Six weeks of days, Monday first.
		first := Date{year = m.year, month = m.month, day = 1}
		lead := (day_of_week(first.year, first.month, 1) + 6) % 7
		start := date_add_days(first, -lead)
		for week in 0 ..< 6 {
			if row({width = grow(), gap = 2, align_y = .Center}) {
				for wd in 0 ..< 7 {
					d := date_add_days(start, week * 7 + wd)
					id := date_id(base, d)
					it := core.interact(ctx, id)
					inside := d.month == m.month && d.year == m.year
					active := selected.year == d.year && selected.month == d.month && selected.day == d.day
					paint: core.Paint
					if active {
						paint = core.Paint_Box{fill = .Fg}
					} else if it.hovered {
						paint = core.Paint_Box{fill = .Overlay}
					}
					cell := layout.Node {
						flex_direction  = .Row,
						align_items     = .Center,
						justify_content = .Center,
						size            = {{32, .Px}, {32, .Px}},
					}
					// `.Arrows`: the calendar moves between days itself; inside a scroll container the
					// arrows must not be taken by scrolling or by focus movement between cells.
					if core.open(ctx, id, cell, paint, label = fmt.tprintf("%s %d, %d", MONTH_ABBREV[d.month - 1], d.day, d.year), flags = {.Hit, .Focusable, .Activate, .Arrows}) {
						color: core.Token = .Fg
						if active {
							color = .Bg
						} else if !inside {
							color = .Faint
						}
						lbl := layout.Node{}
						core.leaf(ctx, core.auto_id(ctx), lbl, core.Paint_Text {
							s     = fmt.tprintf("%d", d.day),
							style = text_style(.Compact),
							color = color,
							wrap  = false,
						}, measured = true)
						if active {
							core.set_a11y_state(ctx, id, {.Selected})
						}
					}
					core.close(ctx)
					if it.clicked {
						out.date = d
						out.picked = true
					}
					if it.focused && !out.picked {
						delta := 0
						for e in core.take_keys(ctx, id) {
							if e.kind != .Key_Down || e.repeat {
								continue
							}
							#partial switch e.key {
							case .Left:
								delta = -1
							case .Right:
								delta = 1
							case .Up:
								delta = -7
							case .Down:
								delta = 7
							}
						}
						if delta != 0 {
							target := date_add_days(d, delta)
							out.date = target
							out.month = target
							out.month.day = 1
							core.set_focus(ctx, date_id(base, target), true)
						}
					}
				}
			}
		}
	}
	core.close(ctx)
	return out
}

// ---- Date Picker ----

@(private)
Date_Picker_State :: struct {
	open:   bool,
	opener: Id,
	month:  Date,
	frame:  u64, // the frame its click was applied in: a ghost pass must not toggle it twice
}

// A date picker: a trigger showing the date, and a calendar in a popover. Controlled: returns the
// date that should be selected. Esc, a click outside and picking a day all close it; focus returns
// to the trigger.
date_picker :: proc(value: Date, key := "date-picker", width: Size = {}) -> (Response, Date) {
	ctx := core.current()
	id := core.key_id(ctx, key)
	st, _ := core.state(ctx, id, Date_Picker_State)
	it := core.interact(ctx, id)
	shown := date_format(value)
	if shown == "" {
		shown = "Pick a date"
	}
	ln := trigger_node(ctx, width)
	if core.open(ctx, id, ln, trigger_box(it.hovered, st.open, false), label = shown, flags = {.Hit, .Focusable, .Activate}) {
		lbl := layout.Node{flex_grow = 1, flex_shrink = 1, flex_basis = {0, .Px}}
		core.leaf(ctx, core.auto_id(ctx), lbl, core.Paint_Text {
			s     = shown,
			style = text_style(.Compact),
			color = .Fg if value.year != 0 else .Faint,
			wrap  = false,
		}, measured = true)
		glyph := layout.Node{size = {{14, .Px}, {14, .Px}}}
		core.leaf(ctx, core.auto_id(ctx), glyph, core.Paint_Icon {
			icon = ph.CALENDAR,
			weight = .Bold,
			color = .Muted,
		})
		if st.open {
			core.set_a11y_state(ctx, id, {.Expanded})
		}
	}
	core.close(ctx)
	res := response_interactive(ctx, id, false)
	next := value
	if it.clicked && st.frame != ctx.frame {
		st.frame = ctx.frame
		st.open = !st.open
		if st.open {
			st.opener = id
			st.month = value if value.year != 0 else Date{2026, 11, 1}
		}
	}
	if st.open {
		trig, _ := core.last_rect(ctx, id)
		lid := core.key_id(ctx, "\x00calendar")
		o := core.Layer_Options{anchor = trig, gap = 4, align = 0}
		if core.open_layer(ctx, lid, layer_style({padding = 10, gap = 0}), layer_paint(), o, label = "Calendar") {
			layer_session(ctx, lid)
			cr := calendar(st.month, value, key = "\x00month")
			st.month = cr.month
			if cr.picked {
				next = cr.date
				st.open = false
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
	return res, next
}

// The current date, from the system clock in UTC (the library has no time-zone database).
today :: proc() -> Date {
	days := int(time.time_to_unix(time.now()) / 86400)
	if days < 0 {
		return {}
	}
	y := 1970
	for {
		n := 366 if is_leap(y) else 365
		if days < n {
			break
		}
		days -= n
		y += 1
	}
	mo := 1
	for {
		n := days_in_month(y, mo)
		if days < n {
			break
		}
		days -= n
		mo += 1
	}
	return {year = y, month = mo, day = days + 1}
}
