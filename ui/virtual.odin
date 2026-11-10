// Virtual lists (ARCHITECTURE.md, "API design → 12"): only the rows in view are declared, and each
// one is positioned absolutely inside a scroll container, so Taffy lays out a screenful of rows no
// matter how long the list is. Row heights are measured once and cached by row key; rows that have
// not been seen yet are estimated.
//
//	if l := ui.virtual_list({id = "rows", count = len(rows), estimate = 40}); l.open {
//	    for i in l.first ..< l.last {
//	        if ui.virtual_item(l, i) {
//	            // ...row content...
//	        }
//	    }
//	}
//
// Wheel, keyboard and focus scrolling come from core's scroll containers; the list only has to
// report its full content height so the scrollbar range is right, and keep measured heights.
//
// Both `virtual_list` and `virtual_grid` close themselves at the end of the scope their result is
// declared in (`@(deferred_out)`), so anything declared after the call in that same scope is a child
// of the container, inside its clip and scroll content. When something follows the list, declare it
// in a proc that returns the `Virtual_List`/`Virtual_Grid` (as examples/06_columns does), or use the
// `if l := ui.virtual_list(...); l.open { ... }` form.
//
// `virtual_grid` is the two-axis sibling for tables: fixed-size rows and columns, with only the
// visible rectangle of cells declared, so a table with a million rows and a hundred thousand columns
// costs the same as a small one.
package ui

import "core:math"

import "../core"
import "../layout"

// A row's height when the list has not measured it yet.
VIRTUAL_ESTIMATE :: 28

// Rows declared beyond each edge of the viewport, so a fast flick does not show a gap.
VIRTUAL_OVERSCAN :: 3

Virtual_List_Options :: struct {
	id:            Key,
	count:         int,
	// Fixed rows: every row is `row_height` tall and nothing is measured.
	row_height:    f32,
	// Variable rows: the height to assume until the row has been laid out once.
	estimate:      f32,
	width, height: Size,
	fill:          Fill,
	border:        Border,
	// The identity of a row for the height cache: return the same value for the same data when the
	// list is reordered (`user` is passed through). nil: the row's position.
	key:           proc(user: rawptr, index: int) -> u64,
	user:          rawptr,
	// Rows declared beyond each edge of the viewport, so a fast flick does not show a gap.
	// 0 means VIRTUAL_OVERSCAN.
	overscan:      int,
	// Keep the view at the bottom when content is appended (logs, event streams).
	stick_bottom:  bool,
	// Change this when the row data changes (a sort or filter), so cached heights are dropped.
	version:       u64,
	label:         string,
}

Virtual_Item_Options :: struct {
	padding:   Edges,
	gap:       f32,
	fill:      Fill,
	border:    Border,
	// Rows take keyboard focus and part in the accessibility tree unless this is set.
	not_focusable: bool,
	label:     string,
}

// A virtual list's declaration: the rows to declare, and the scroll state they are drawn at.
Virtual_List :: struct {
	open:      bool,
	first:     int, // declare rows in [first, last)
	last:      int,
	// The rows the viewport covers, without overscan: [visible_first, visible_last).
	visible_first: int,
	visible_last:  int,
	offset:    f32, // scroll offset, logical pixels
	viewport:  f32,
	content:   f32, // the whole list's height
	id:        Id,
	count:     int,
	st:        ^Virtual_State,
	ctx:       ^core.Context,
}

@(private)
Virtual_State :: struct {
	heights:      map[u64]f32, // measured row heights by row key
	cum:          [dynamic]f32, // cum[i] is the top of row i; valid for [0, valid]
	valid:        int,
	total:        f32, // the whole list's height, from the heights known so far
	keys:         [dynamic]u64, // the row keys of [keys_first, keys_first + len(keys))
	keys_first:   int,
	version:      u64,
	count:        int,
	// Scroll anchoring: the row at the top of the viewport last pass and where it sat. When a row
	// above it changes height, the offset moves with it instead of the content jumping.
	anchor_index: int,
	anchor_top:   f32,
	anchor_valid: bool,
	prev_total:   f32,
	prev_view:    f32,
}

@(private)
virtual_state_free :: proc(p: rawptr) {
	st := (^Virtual_State)(p)
	delete(st.heights)
	delete(st.cum)
	delete(st.keys)
}

@(deferred_out = virtual_list_close)
virtual_list :: proc(o: Virtual_List_Options) -> Virtual_List {
	ctx := core.current()
	id := key_id(ctx, o.id)
	if name, ok := o.id.(string); ok {
		core.register_name(ctx, name, id)
	}
	st, created := core.state(ctx, id, Virtual_State)
	if created {
		core.set_state_free(ctx, id, virtual_state_free)
	}
	opts := o
	if opts.estimate <= 0 {
		opts.estimate = VIRTUAL_ESTIMATE
	}
	if opts.overscan <= 0 {
		opts.overscan = VIRTUAL_OVERSCAN
	}
	base := opts.row_height if opts.row_height > 0 else opts.estimate
	fresh := st.version != opts.version
	if fresh {
		// Another data set: the cached heights and positions describe rows that are gone.
		clear(&st.heights)
		clear(&st.cum)
		append(&st.cum, 0)
		st.valid = 0
		st.count = opts.count
		st.total = f32(opts.count) * base
		st.anchor_valid = false
		st.version = opts.version
	} else if st.count != opts.count {
		// Rows appended or removed at the end: assume the base height until they are measured.
		st.total += f32(opts.count - st.count) * base
		st.count = opts.count
		st.valid = min(st.valid, opts.count)
		st.anchor_valid = false
	}
	if len(st.cum) == 0 {
		append(&st.cum, 0)
	}

	ln := layout.Node{flex_direction = .Column}
	item(ctx, &ln, opts.width, opts.height)
	open := core.open(ctx, id, ln, box_paint(opts.fill, opts.border), clip = true, cull = false, label = opts.label, flags = {.Scroll})
	if !open {
		return {id = id, ctx = ctx, st = st}
	}
	core.set_a11y_role(ctx, id, .List)
	core.set_rows(ctx, id, opts.count, -1)

	// Rows measured in the last pass. Their rects are in the last laid-out tree; the node IDs follow
	// the row keys, in this container's ID scope. A fresh data set, and a list of fixed-height rows,
	// have nothing to measure.
	if !fresh && opts.row_height <= 0 {
		changed := false
		for j in 0 ..< len(st.keys) {
			i := st.keys_first + j
			r, ok := core.last_rect(ctx, core.key_id_int(ctx, int(st.keys[j])))
			if !ok || r.h <= 0 {
				continue
			}
			old, seen := st.heights[st.keys[j]]
			if seen && math.abs(old - r.h) <= 0.01 {
				continue
			}
			prev := old if seen else base
			st.heights[st.keys[j]] = r.h
			st.total += r.h - prev
			// Positions from this row down change; keep the ones above.
			st.valid = min(st.valid, i)
			changed = true
		}
		// The rows just declared sit at estimated positions; run the pass again so they are placed
		// from the heights that were measured, instead of presenting a frame that overlaps.
		if changed {
			core.unsettle(ctx)
		}
	}

	// The scroll controller's offset, and how much of the list is visible.
	offset := core.scroll_offset(ctx, id).y
	view := st.prev_view
	if r, ok := core.last_rect(ctx, id); ok && r.h > 0 {
		view = r.h
	} else if view <= 0 {
		view = ctx.size.y
	}
	if view <= 0 {
		view = 1
	}

	total := st.total
	bottom := max(total - view, 0)

	skip_anchor := false
	// `ui.scroll_to_index`: minimal movement that brings the row on screen.
	if index, ok := core.take_scroll_to_index(ctx, id); ok && opts.count > 0 {
		i := clamp(index, 0, opts.count - 1)
		ensure_cum(st, opts, i + 1)
		top := st.cum[i]
		row_bottom := st.cum[i + 1] if i + 1 <= st.valid else top + height_of(st, opts, i)
		switch {
		case top < offset:
			offset = top
		case row_bottom > offset + view:
			offset = row_bottom - view
		}
		offset = clamp(offset, 0, bottom)
		core.set_scroll(ctx, id, {0, offset})
		offset = core.scroll_offset(ctx, id).y
		skip_anchor = true
	}

	// Stick to the bottom while the view was already there.
	if opts.stick_bottom && st.prev_total > 0 && offset >= st.prev_total - st.prev_view - 1 {
		offset = bottom
		core.set_scroll(ctx, id, {0, offset})
		offset = core.scroll_offset(ctx, id).y
		skip_anchor = true
	}

	// Positions are computed only as far as this pass looks: a million rows never become a million
	// layout nodes, and a height change near the top does not recompute the rows below the screen.
	// The offset may have moved above, so this follows it.
	ensure_to_y(st, opts, offset + view)

	// Scroll anchoring: a height change above the viewport moves the offset with the content, so the
	// rows on screen stay put.
	if !skip_anchor && offset > 0 && st.anchor_valid && st.anchor_index < opts.count && st.anchor_index <= st.valid {
		top := st.cum[st.anchor_index]
		if top != st.anchor_top {
			offset = clamp(offset + (top - st.anchor_top), 0, bottom)
			core.set_scroll(ctx, id, {0, offset})
			offset = core.scroll_offset(ctx, id).y
			ensure_to_y(st, opts, offset + view)
		}
	}

	first := row_at(st, opts.count, offset)
	last := row_at(st, opts.count, offset + view) + 1
	visible_first, visible_last := first, last
	first = max(first - opts.overscan, 0)
	last = min(last + opts.overscan, opts.count)
	if opts.count > 0 && last <= first {
		last = first + 1
	}
	// The declared rows are positioned from cum; make sure it covers them.
	ensure_cum(st, opts, last)

	// Rows in this range that have never been laid out sit at estimated positions. They are measured
	// by this pass's layout, so ask for one more pass rather than presenting a frame that overlaps.
	if opts.row_height <= 0 {
		for i in first ..< last {
			if row_key(opts, i) not_in st.heights {
				core.unsettle(ctx)
				break
			}
		}
	}

	// What the next pass must report: the full extent, not just the declared rows.
	core.set_scroll_content(ctx, id, {0, total})

	// Remember the keys of the declared range for measuring them next pass.
	clear(&st.keys)
	st.keys_first = first
	for i in first ..< last {
		append(&st.keys, row_key(opts, i))
	}
	if visible_first < opts.count && offset > 0 && visible_first <= st.valid {
		st.anchor_index = visible_first
		st.anchor_top = st.cum[visible_first]
		st.anchor_valid = true
	} else {
		st.anchor_valid = false
	}
	st.prev_total = total
	st.prev_view = view

	return {
		open = true,
		first = first,
		last = last,
		visible_first = visible_first,
		visible_last = min(visible_last, opts.count),
		offset = offset,
		viewport = view,
		content = total,
		id = id,
		count = opts.count,
		st = st,
		ctx = ctx,
	}
}

@(private)
virtual_list_close :: proc(l: Virtual_List) {
	core.close(l.ctx)
}

// Declares one row of a virtual list. Like every container, returns false when culled (never here:
// rows are only declared when they are in range).
@(deferred_out = virtual_item_close)
virtual_item :: proc(list: Virtual_List, index: int, o: Virtual_Item_Options = {}) -> bool {
	ctx := list.ctx
	y := f32(0)
	if index >= 0 && index <= list.st.valid {
		y = list.st.cum[index]
	}
	ln := layout.Node {
		position       = 1,
		flex_direction = .Column,
		padding        = edges(o.padding),
		gap            = {o.gap, o.gap},
	}
	// Absolute inside the list's content box, full width. The y is in content coordinates: core
	// subtracts the container's scroll offset when it resolves the pass.
	ln.inset[0] = {0, .Px}
	ln.inset[1] = {0, .Px}
	ln.inset[2] = {y, .Px}
	flags := core.Node_Flags{}
	if !o.not_focusable {
		flags += {.Focusable}
	}
	id := list_row_id(ctx, list, index)
	open := core.open(ctx, id, ln, box_paint(o.fill, o.border), clip = false, cull = false, label = o.label, flags = flags)
	if open {
		core.set_a11y_role(ctx, id, .List_Item)
		core.set_rows(ctx, id, list.count, index)
	}
	return open
}

@(private)
virtual_item_close :: proc(ok: bool) {
	core.close(core.current())
}

// The node ID of a row: its key within the list's ID scope, so state and the height cache follow the
// row when the list is reordered.
@(private)
list_row_id :: proc(ctx: ^core.Context, list: Virtual_List, index: int) -> Id {
	if index >= list.first && index < list.first + len(list.st.keys) {
		return core.key_id_int(ctx, int(list.st.keys[index - list.first]))
	}
	return core.key_id_int(ctx, index)
}

@(private)
row_key :: proc(o: Virtual_List_Options, index: int) -> u64 {
	if o.key != nil {
		return o.key(o.user, index)
	}
	return u64(index)
}

@(private)
height_of :: proc(st: ^Virtual_State, o: Virtual_List_Options, index: int) -> f32 {
	if o.row_height > 0 {
		return o.row_height
	}
	if h, ok := st.heights[row_key(o, index)]; ok {
		return h
	}
	return o.estimate
}

// Makes cum[] valid up to `upto` (cum[upto] is the total height of the first `upto` rows).
@(private)
ensure_cum :: proc(st: ^Virtual_State, o: Virtual_List_Options, upto: int) {
	if len(st.cum) == 0 {
		append(&st.cum, 0)
		st.valid = 0
	}
	if st.valid >= upto {
		return
	}
	resize(&st.cum, upto + 1)
	for i in st.valid ..< upto {
		st.cum[i + 1] = st.cum[i] + height_of(st, o, i)
	}
	st.valid = upto
}

// Extends cum[] far enough that the row at `y` is known, without walking rows that will never be
// looked at. The guess is the average height; measured rows taller than it are followed in chunks.
@(private)
ensure_to_y :: proc(st: ^Virtual_State, o: Virtual_List_Options, y: f32) {
	if len(st.cum) == 0 {
		append(&st.cum, 0)
		st.valid = 0
	}
	if o.count <= 0 || y <= st.cum[st.valid] {
		return
	}
	base := o.row_height if o.row_height > 0 else o.estimate
	guess := st.valid + int((y - st.cum[st.valid]) / max(base, 0.001))
	upto := clamp(guess + 32, st.valid + 1, o.count)
	ensure_cum(st, o, upto)
	for st.valid < o.count && st.cum[st.valid] <= y {
		ensure_cum(st, o, min(st.valid + 256, o.count))
	}
}

// The index of the row under `y` (clamped into [0, count)). cum[] must cover `y`; call `ensure_to_y`.
@(private)
row_at :: proc(st: ^Virtual_State, count: int, y: f32) -> int {
	if count <= 0 {
		return 0
	}
	if y <= 0 {
		return 0
	}
	hi := min(st.valid, count)
	if hi <= 0 {
		return 0
	}
	if y >= st.cum[hi] {
		return hi - 1
	}
	lo := 0 // cum[lo] <= y < cum[hi]
	for lo + 1 < hi {
		mid := (lo + hi) / 2
		if st.cum[mid] <= y {
			lo = mid
		} else {
			hi = mid
		}
	}
	return lo
}

// ---- Tables: rows and columns virtualized on both axes ----

Virtual_Grid_Options :: struct {
	id:            Key,
	rows:          int,
	columns:       int,
	row_height:    f32,
	column_width:  f32,
	// Per-column widths, overriding `column_width` (a table with resizable columns). When its length
	// is `columns`, the grid's columns have these widths and `column_width` is ignored.
	column_widths: []f32,
	width, height: Size,
	fill:          Fill,
	border:        Border,
	// Rows and columns declared beyond each edge of the viewport; 0 means VIRTUAL_OVERSCAN.
	overscan:      int,
	label:         string,
}

Virtual_Cell_Options :: struct {
	padding:       Edges,
	gap:           f32,
	fill:          Fill,
	border:        Border,
	// Cells take keyboard focus and part in the accessibility tree unless this is set.
	not_focusable: bool,
	// Cells take the pointer and activation, and read the arrow keys themselves (a data table's
	// cells: a click selects, Space/Enter selects, arrows move to another cell).
	interactive:   bool,
	label:         string,
}

// A grid's declaration: the cell rectangle to declare, and the scroll state it is drawn at.
Virtual_Grid :: struct {
	open:         bool,
	row_first:    int,
	row_last:     int, // declare cells in rows [row_first, row_last) and columns [column_first, column_last)
	column_first: int,
	column_last:  int,
	// The cells the viewport covers, without overscan.
	visible_row_first, visible_row_last:       int,
	visible_column_first, visible_column_last: int,
	offset:       [2]f32,
	row_count:    int,
	column_count: int,
	row_height:   f32,
	column_width: f32,
	// Where each column starts (length column_count + 1) when the columns have different widths.
	column_offsets: []f32,
	id:           Id,
	ctx:          ^core.Context,
}

@(deferred_out = virtual_grid_close)
virtual_grid :: proc(o: Virtual_Grid_Options) -> Virtual_Grid {
	ctx := core.current()
	id := key_id(ctx, o.id)
	if name, ok := o.id.(string); ok {
		core.register_name(ctx, name, id)
	}
	overscan := o.overscan if o.overscan > 0 else VIRTUAL_OVERSCAN
	rh := max(o.row_height, 1)
	cw := max(o.column_width, 1)

	ln := layout.Node{}
	item(ctx, &ln, o.width, o.height)
	open := core.open(ctx, id, ln, box_paint(o.fill, o.border), clip = true, cull = false, label = o.label, flags = {.Scroll})
	if !open {
		return {id = id, ctx = ctx}
	}
	core.set_a11y_role(ctx, id, .Table)
	core.set_rows(ctx, id, o.rows, -1)
	core.set_cell(ctx, id, o.columns, -1)

	offset := core.scroll_offset(ctx, id)
	view := ctx.size
	if r, ok := core.last_rect(ctx, id); ok && r.w > 0 && r.h > 0 {
		view = {r.w, r.h}
	}
	if view.x <= 0 {
		view.x = 1
	}
	if view.y <= 0 {
		view.y = 1
	}

	// The grid knows its full extent exactly: every cell has the same size, or the widths given.
	widths_used := len(o.column_widths) >= o.columns && o.columns > 0
	offsets: []f32 = nil
	total_w := f32(o.columns) * cw
	if widths_used {
		offsets = make([]f32, o.columns + 1, context.temp_allocator)
		total: f32 = 0
		for w, i in o.column_widths[:o.columns] {
			offsets[i] = total
			total += max(w, 1)
		}
		offsets[o.columns] = total
		total_w = total
	}
	core.set_scroll_content(ctx, id, {total_w, f32(o.rows) * rh})

	row_first, row_last, vis_row_first, vis_row_last := span(offset.y, view.y, rh, o.rows, overscan)
	column_first, column_last, vis_col_first, vis_col_last: int
	if widths_used {
		column_first, column_last, vis_col_first, vis_col_last = span_offsets(offset.x, view.x, offsets, o.columns, overscan)
	} else {
		column_first, column_last, vis_col_first, vis_col_last = span(offset.x, view.x, cw, o.columns, overscan)
	}

	return {
		open = true,
		row_first = row_first,
		row_last = row_last,
		column_first = column_first,
		column_last = column_last,
		visible_row_first = vis_row_first,
		visible_row_last = vis_row_last,
		visible_column_first = vis_col_first,
		visible_column_last = vis_col_last,
		offset = offset,
		row_count = o.rows,
		column_count = o.columns,
		row_height = rh,
		column_width = cw,
		column_offsets = offsets,
		id = id,
		ctx = ctx,
	}
}

@(private)
virtual_grid_close :: proc(g: Virtual_Grid) {
	core.close(g.ctx)
}

// The first and last cell of an axis: [first, last) to declare, and [visible_first, visible_last).
@(private)
span :: proc(offset, view, cell: f32, count, overscan: int) -> (first, last, visible_first, visible_last: int) {
	if count <= 0 {
		return 0, 0, 0, 0
	}
	visible_first = clamp(int(max(offset, 0) / cell), 0, count - 1)
	visible_last = clamp(int((max(offset, 0) + view) / cell) + 1, visible_first + 1, count)
	first = max(visible_first - overscan, 0)
	last = min(visible_last + overscan, count)
	return
}

// The first and last column of an axis with per-column offsets: [first, last) to declare, and
// [visible_first, visible_last).
@(private)
span_offsets :: proc(offset, view: f32, offs: []f32, count, overscan: int) -> (first, last, visible_first, visible_last: int) {
	if count <= 0 {
		return 0, 0, 0, 0
	}
	visible_first = clamp(index_at(offs, max(offset, 0)), 0, count - 1)
	visible_last = clamp(index_at(offs, max(offset, 0) + view) + 1, visible_first + 1, count)
	first = max(visible_first - overscan, 0)
	last = min(visible_last + overscan, count)
	return
}

// The index of the last offset at or before `y`.
@(private)
index_at :: proc(offs: []f32, y: f32) -> int {
	lo, hi := 0, len(offs) - 1
	for lo + 1 < hi {
		mid := (lo + hi) / 2
		if offs[mid] <= y {
			lo = mid
		} else {
			hi = mid
		}
	}
	return lo
}

// Where a column starts and how wide it is, for a grid with or without per-column widths.
@(private)
cell_x :: proc(g: Virtual_Grid, column: int) -> f32 {
	if g.column_offsets != nil {
		return g.column_offsets[column]
	}
	return f32(column) * g.column_width
}

@(private)
cell_w :: proc(g: Virtual_Grid, column: int) -> f32 {
	if g.column_offsets != nil {
		return max(g.column_offsets[column + 1] - g.column_offsets[column], 1)
	}
	return g.column_width
}

// Declares one cell of a virtual grid: absolutely positioned at its row and column, filled by the
// caller's widgets. Cells carry their position in the table for screen readers.
@(deferred_out = virtual_cell_close)
virtual_cell :: proc(g: Virtual_Grid, row, column: int, o: Virtual_Cell_Options = {}) -> bool {
	ctx := g.ctx
	ln := layout.Node {
		position       = 1,
		flex_direction = .Column,
		padding        = edges(o.padding),
		gap            = {o.gap, o.gap},
		size           = {{cell_w(g, column), .Px}, {g.row_height, .Px}},
	}
	ln.inset[0] = {cell_x(g, column), .Px}
	ln.inset[2] = {f32(row) * g.row_height, .Px}
	flags := core.Node_Flags{}
	if !o.not_focusable {
		flags += {.Focusable}
	}
	if o.interactive {
		flags += {.Hit, .Activate, .Arrows}
	}
	id := core.key_id_int(ctx, row * max(g.column_count, 1) + column)
	open := core.open(ctx, id, ln, box_paint(o.fill, o.border), clip = false, cull = false, label = o.label, flags = flags)
	if open {
		core.set_a11y_role(ctx, id, .Cell)
		core.set_rows(ctx, id, g.row_count, row)
		core.set_cell(ctx, id, g.column_count, column)
	}
	return open
}

@(private)
virtual_cell_close :: proc(ok: bool) {
	core.close(core.current())
}
