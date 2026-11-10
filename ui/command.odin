// Command: the command palette of the shadcn/ui set. It is a modal layer with a search field, a
// fuzzy-ranked list of commands (virtualized, so a palette may hold thousands) and full keyboard
// operation: Up/Down move the highlight, Enter runs it, Esc closes.
package ui

import "core:sort"
import "core:strings"

import "../core"
import ph "../icons/phosphor"
import "../layout"

// One command: its value (what the app gets back), its label, and optional group and shortcut hints.
Command_Item :: struct {
	value: string,
	label: string,
	group: string,
	hint:  string,
}

@(private)
Command_State :: struct {
	query:     string,
	highlight: int,
}

@(private)
command_state_free :: proc(p: rawptr) {
	st := (^Command_State)(p)
	delete(st.query)
}

// A subsequence match with a small score: consecutive characters and matches at word starts count
// more, and shorter labels win ties. -1 when the pattern is not a subsequence of the text.
fuzzy_score :: proc(pattern, text: string) -> int {
	if len(pattern) == 0 {
		return 0
	}
	p, t := 0, 0
	score := 0
	last := -2
	for t < len(text) && p < len(pattern) {
		if ascii_lower(pattern[p]) == ascii_lower(text[t]) {
			score += 2
			if t == last + 1 {
				score += 4
			}
			if t == 0 || !is_word_char(text[t - 1]) {
				score += 3
			}
			last = t
			p += 1
		}
		t += 1
	}
	if p < len(pattern) {
		return -1
	}
	return score + max(0, 12 - len(text) / 6)
}

@(private)
is_word_char :: proc(c: u8) -> bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_'
}

@(private)
Scored :: struct {
	index: int,
	score: int,
}

@(private)
score_len :: proc(it: sort.Interface) -> int {
	return len((^[]Scored)(it.collection)^)
}

@(private)
score_less :: proc(it: sort.Interface, i, j: int) -> bool {
	items := (^[]Scored)(it.collection)^
	if items[i].score != items[j].score {
		return items[i].score > items[j].score
	}
	return items[i].index < items[j].index
}

@(private)
score_swap :: proc(it: sort.Interface, i, j: int) {
	items := (^[]Scored)(it.collection)^
	items[i], items[j] = items[j], items[i]
}

// A command palette. The app owns `open`; `close` is sent by Esc, a click outside, or picking a
// command. Returns the picked command's value ("" when none) and `res.changed` when one was picked.
command :: proc(d: Dispatch($M), close: M, open: bool, items: []Command_Item, key := "command") -> (Response, string) {
	ctx := core.current()
	id := layer_id(ctx, key)
	// The palette's state lives under its own ID: the layer's ID is used by `layer_session` for
	// the layer bookkeeping state, and a widget may only have one state type per ID.
	sid := core.key_id(ctx, strings.concatenate({key, "\x00command"}, context.temp_allocator))
	st, created := core.state(ctx, sid, Command_State)
	if created {
		core.set_state_free(ctx, sid, command_state_free)
	}
	if !open {
		delete(st.query)
		st.query = ""
		st.highlight = 0
		return {}, ""
	}
	res := Response{id = id}
	picked := ""
	o := core.Layer_Options{modal = true, center = true}
	style := layer_style({min_width = 520, padding = 8, gap = 6})
	if !core.open_layer(ctx, id, style, layer_paint(), o, label = "Command palette") {
		return res, picked
	}
	core.set_a11y_role(ctx, id, .Dialog)
	layer_session(ctx, id)
	layer_close_check(ctx, d, id, close)

	// The search field's arrows move the highlight; read them before the field takes the keys.
	search_id := input_id(ctx, "Search commands", "search")
	up, down := false, false
	for e in core.keys(ctx, search_id) {
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
	input_res, q2 := text_input("Search commands", q, width = percent(1), hide_label = true, key = "search")
	if q2 != q {
		delete(st.query)
		st.query = strings.clone(q2)
		st.highlight = 0
	}

	// Rank the commands.
	scored := make([dynamic]Scored, 0, len(items), context.temp_allocator)
	for item, i in items {
		s := fuzzy_score(st.query, item.label)
		if s >= 0 {
			append(&scored, Scored{index = i, score = s})
		}
	}
	if len(scored) > 1 {
		items_slice := scored[:]
		it := sort.Interface{len = score_len, less = score_less, swap = score_swap, collection = &items_slice}
		sort.sort(it)
	}
	if len(scored) > 0 {
		st.highlight = clamp(st.highlight, 0, len(scored) - 1)
	} else {
		st.highlight = 0
	}
	if up && len(scored) > 0 {
		st.highlight = (st.highlight - 1 + len(scored)) % len(scored)
	}
	if down && len(scored) > 0 {
		st.highlight = (st.highlight + 1) % len(scored)
	}

	list_id := core.key_id(ctx, "results")
	if len(scored) == 0 {
		if row({height = fixed(48), align_y = .Center, padding = {8, 0, 8, 0}}) {
			text("No commands found", .Compact, .Faint)
		}
	} else if l := virtual_list({
		id = "results",
		count = len(scored),
		row_height = 40,
		height = fixed(min(f32(len(scored)) * 40, 340)),
		label = "Commands",
	}); l.open {
		if up || down {
			core.request_scroll_to_index(ctx, list_id, st.highlight)
		}
		for i in l.first ..< l.last {
			item := items[scored[i].index]
			lid := list_row_id(ctx, l, i)
			it := core.interact(ctx, lid)
			fill: Fill
			if i == st.highlight {
				fill = .Overlay
			} else if it.hovered {
				fill = .Bg
			}
			if virtual_item(l, i, {padding = {8, 0, 8, 0}, fill = fill, label = item.label}) {
				if row({width = grow(), height = grow(), align_y = .Center, gap = 10}) {
					glyph := layout.Node{size = {{14, .Px}, {14, .Px}}}
					core.leaf(ctx, core.auto_id(ctx), glyph, core.Paint_Icon {
						icon = ph.MAGNIFYING_GLASS,
						weight = .Bold,
						color = .Muted,
					})
					lbl := layout.Node{flex_grow = 1, flex_shrink = 1, flex_basis = {0, .Px}}
					core.leaf(ctx, core.auto_id(ctx), lbl, core.Paint_Text {
						s     = item.label,
						style = text_style(.Compact),
						color = .Fg,
						wrap  = false,
					}, measured = true)
					if item.hint != "" {
						h := layout.Node{}
						core.leaf(ctx, core.auto_id(ctx), h, core.Paint_Text {
							s     = item.hint,
							style = text_style(.Metadata),
							color = .Faint,
							wrap  = false,
						}, measured = true)
					}
				}
			}
			if it.clicked {
				picked = item.value
				st.highlight = i
			}
		}
	}
	if input_res.submitted && len(scored) > 0 {
		picked = items[scored[st.highlight].index].value
	}
	if picked != "" {
		res.changed = true
		delete(st.query)
		st.query = ""
		dispatch(d, close)
		core.restore_layer_focus(ctx)
	}
	core.close(ctx)
	return res, picked
}
