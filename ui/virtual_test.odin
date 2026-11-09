// Tests of virtual lists and grids (ROADMAP.md, M5): only the rows in view are declared, measured
// heights are kept and used for positions and the content extent, scroll requests move as little as
// possible, and focus scrolling brings rows back into view. The grid virtualizes both axes.
package ui

import "core:math"
import "core:testing"

import "../core"
import "../platform"

V_State :: struct {
	count:    int,
	stick:    bool,
	version:  u64,
	row_h:    f32, // 0: rows are measured from their content
	estimate: f32,
}

Jump :: struct {
	index: int,
}
Grow :: struct {
	by: int,
}

V_Msg :: union {
	Jump,
	Grow,
}

v_update :: proc(s: ^V_State, msg: V_Msg, fx: ^Effects(V_Msg)) {
	switch m in msg {
	case Jump:
		scroll_to_index(fx, "rows", m.index)
	case Grow:
		s.count += m.by
	}
}

// An even row is 20 tall, an odd row 60: measured heights differ from the estimate.
@(private)
v_row_height :: proc(index: int) -> f32 {
	return 20 if index % 2 == 0 else 60
}

// The declaration of the last pass, for assertions on the range it chose.
@(private)
g_vlist: Virtual_List

v_view :: proc(s: V_State, d: Dispatch(V_Msg)) {
	if column({padding = 10, width = grow(), height = grow()}) {
		if l := virtual_list({
			id = "rows",
			count = s.count,
			row_height = s.row_h,
			estimate = s.estimate,
			stick_bottom = s.stick,
			version = s.version,
			width = grow(),
			height = grow(),
		}); l.open {
			g_vlist = l
			for i in l.first ..< l.last {
				if virtual_item(l, i) {
					// A fixed-size box makes the row's height exact.
					h := s.row_h if s.row_h > 0 else v_row_height(i)
					if column({height = fixed(h)}) {}
				}
			}
		}
	}
}

@(private)
v_list :: proc(h: ^Test_Harness(V_State, V_Msg)) -> (A11y_Node, bool) {
	for n in h.window.ctx.a11y {
		if n.role == .List {
			return n, true
		}
	}
	return {}, false
}

@(private)
v_row :: proc(h: ^Test_Harness(V_State, V_Msg), index: int) -> (A11y_Node, bool) {
	for n in h.window.ctx.a11y {
		if n.role == .List_Item && n.row_index == i32(index) {
			return n, true
		}
	}
	return {}, false
}

@(private)
v_declared_rows :: proc(h: ^Test_Harness(V_State, V_Msg)) -> int {
	n := 0
	for a in h.window.ctx.a11y {
		if a.role == .List_Item {
			n += 1
		}
	}
	return n
}

@(private)
v_focused :: proc(h: ^Test_Harness(V_State, V_Msg)) -> (A11y_Node, bool) {
	for n in h.window.ctx.a11y {
		if .Focused in n.flags {
			return n, true
		}
	}
	return {}, false
}

// A list's content extent, from the scroll limits the resolve step wrote.
@(private)
v_content :: proc(h: ^Test_Harness($S, $M), id: Id) -> f32 {
	view, max, ok := core.scroll_limits(&h.window.ctx, id)
	return max.y + view.y if ok else 0
}

@(private)
v_scroll :: proc(h: ^Test_Harness($S, $M), id: Id) -> f32 {
	return core.scroll_offset(&h.window.ctx, id).y
}

@(test)
virtual_list_declares_only_the_rows_in_view :: proc(t: ^testing.T) {
	h := test_harness(V_State{count = 10_000, row_h = 28}, v_update, v_view)
	defer test_destroy(h)

	list, ok := v_list(h)
	testing.expect(t, ok, "the list is in the semantic tree")
	testing.expect_value(t, list.row_count, 10_000)

	// 580px of viewport at 28px a row is 21 rows, plus the overscan on both sides.
	rows := v_declared_rows(h)
	testing.expectf(t, rows >= 21 && rows <= 40, "declared %d rows", rows)
	testing.expectf(t, math.abs(v_content(h, list.id) - 280_000) < 1, "content %v", v_content(h, list.id))

	first, found := v_row(h, 0)
	testing.expect(t, found, "the first row is declared")
	testing.expect(t, first.rect.y == list.rect.y, "the first row starts at the top")
}

@(test)
virtual_list_scrolls_with_the_wheel :: proc(t: ^testing.T) {
	h := test_harness(V_State{count = 10_000, row_h = 28}, v_update, v_view)
	defer test_destroy(h)

	list, _ := v_list(h)
	pos := [2]f32{list.rect.x + 10, list.rect.y + 10}
	append(&h.window.events, platform.Event{kind = .Wheel, pos = pos, wheel = {delta = {0, -140}, precise = true}})
	test_frame(h)

	// 140px is exactly five rows.
	testing.expectf(t, math.abs(v_scroll(h, list.id) - 140) < 1, "offset %v", v_scroll(h, list.id))
	testing.expect_value(t, g_vlist.visible_first, 5)
	row, found := v_row(h, 5)
	testing.expect(t, found, "row 5 is declared")
	testing.expectf(t, math.abs(row.rect.y - list.rect.y) < 1, "row 5 sits at the top")
}

@(test)
virtual_list_scroll_to_index_moves_as_little_as_possible :: proc(t: ^testing.T) {
	h := test_harness(V_State{count = 10_000, row_h = 28}, v_update, v_view)
	defer test_destroy(h)

	list, _ := v_list(h)
	dispatch(dispatcher(&h.store), Jump{index = 9_000})
	test_frame(h)

	list, _ = v_list(h)
	row, found := v_row(h, 9_000)
	testing.expect(t, found, "row 9000 is declared")
	bottom := list.rect.y + list.rect.h
	testing.expectf(
		t,
		math.abs(row.rect.y + row.rect.h - bottom) < 1.5,
		"row 9000 at %v..%v (%v), viewport ends at %v, offset %v",
		row.rect.y,
		row.rect.y + row.rect.h,
		row.rect.h,
		bottom,
		v_scroll(h, list.id),
	)

	// Going back up to a row above the top lands it at the top edge.
	dispatch(dispatcher(&h.store), Jump{index = 10})
	test_frame(h)
	list, _ = v_list(h)
	row, found = v_row(h, 10)
	testing.expect(t, found, "row 10 is declared")
	testing.expectf(t, math.abs(row.rect.y - list.rect.y) < 1.5, "row 10 landed at the top edge")
}

@(test)
virtual_list_tab_and_arrows_move_focus_and_scroll :: proc(t: ^testing.T) {
	h := test_harness(V_State{count = 10_000, row_h = 28}, v_update, v_view)
	defer test_destroy(h)

	test_key(h, .Tab)
	f, found := v_focused(h)
	testing.expect(t, found, "Tab focused something")
	testing.expect_value(t, f.row_index, 0)

	for _ in 0 ..< 25 {
		test_key(h, .Down)
	}
	f, found = v_focused(h)
	list, _ := v_list(h)
	testing.expect(t, found && f.role == .List_Item, "focus is still on a row")
	testing.expectf(t, f.row_index >= 20, "focus moved down: row %v", f.row_index)
	testing.expectf(t, v_scroll(h, list.id) > 0, "the list scrolled to keep the row in view")
	testing.expect(
		t,
		f.rect.y >= list.rect.y - 1 && f.rect.y + f.rect.h <= list.rect.y + list.rect.h + 1,
		"the focused row is fully inside the viewport",
	)
}

@(test)
virtual_list_sticks_to_the_bottom_when_rows_are_appended :: proc(t: ^testing.T) {
	h := test_harness(V_State{count = 100, row_h = 28, stick = true}, v_update, v_view)
	defer test_destroy(h)

	list, _ := v_list(h)
	pos := [2]f32{list.rect.x + 10, list.rect.y + 10}
	append(&h.window.events, platform.Event{kind = .Wheel, pos = pos, wheel = {delta = {0, -1_000_000}, precise = true}})
	test_frame(h)
	_, max, _ := core.scroll_limits(&h.window.ctx, list.id)
	testing.expectf(t, math.abs(v_scroll(h, list.id) - max.y) < 1, "scrolled to the bottom")

	dispatch(dispatcher(&h.store), Grow{by = 50})
	test_frame(h)
	list, _ = v_list(h)
	_, max, _ = core.scroll_limits(&h.window.ctx, list.id)
	testing.expectf(
		t,
		math.abs(v_scroll(h, list.id) - max.y) < 1,
		"still at the bottom after appending: %v of %v",
		v_scroll(h, list.id),
		max.y,
	)
	_, found := v_row(h, 149)
	testing.expectf(
		t,
		found,
		"the appended rows are declared: count %d, declaring %d..%d, offset %v of %v",
		g_vlist.count,
		g_vlist.first,
		g_vlist.last,
		v_scroll(h, list.id),
		max.y,
	)
}

@(test)
virtual_list_places_rows_from_measured_heights :: proc(t: ^testing.T) {
	h := test_harness(V_State{count = 1_000, estimate = 30}, v_update, v_view)
	defer test_destroy(h)

	list, _ := v_list(h)
	rows := v_declared_rows(h)
	testing.expect(t, rows >= 10, "the viewport of variable rows is declared")

	// The measured rows are 20 or 60 tall, not the 30 estimate: the content is not 30,000 any more.
	testing.expectf(t, math.abs(v_content(h, list.id) - 30_000) > 1, "measured heights changed the total")

	// Every declared row starts where the heights of the rows above it end. The rows above the
	// viewport are measured too, so the running sum is exact from the top.
	y := f32(0)
	for i in 0 ..< rows {
		row, found := v_row(h, i)
		testing.expect(t, found, "rows are declared from 0 with no scroll")
		if !found {
			return
		}
		testing.expectf(t, math.abs((row.rect.y - list.rect.y) - y) < 1, "row %d at %v, want %v", i, row.rect.y - list.rect.y, y)
		y += v_row_height(i)
	}
}

// ---- The internals: positions are computed lazily, only as far as a pass looks ----

@(test)
virtual_positions_are_computed_lazily :: proc(t: ^testing.T) {
	st: Virtual_State
	defer virtual_state_free(&st)
	o := Virtual_List_Options{count = 1_000_000, row_height = 30}
	ensure_to_y(&st, o, 600)
	testing.expectf(t, st.valid > 20 && st.valid < 200, "computed %d rows near the viewport", st.valid)
	testing.expect_value(t, row_at(&st, o.count, 0), 0)
	testing.expect_value(t, row_at(&st, o.count, 299), 9)
	testing.expect_value(t, row_at(&st, o.count, 300), 10)
	testing.expect_value(t, row_at(&st, o.count, 1_000_000_000), st.valid - 1)
}

@(test)
virtual_cum_uses_measured_heights_and_estimates :: proc(t: ^testing.T) {
	st: Virtual_State
	defer virtual_state_free(&st)
	o := Virtual_List_Options{count = 10, estimate = 30}
	st.heights[0] = 20
	st.heights[1] = 60
	st.heights[2] = 20
	ensure_cum(&st, o, 4)
	testing.expect_value(t, st.cum[0], f32(0))
	testing.expect_value(t, st.cum[1], f32(20))
	testing.expect_value(t, st.cum[2], f32(80))
	testing.expect_value(t, st.cum[3], f32(100))
	testing.expect_value(t, st.cum[4], f32(130)) // the fourth row is still the estimate
}

// ---- Tables ----

@(private)
g_grid: Virtual_Grid

G_State :: struct{}

Ping :: struct{}

G_Msg :: union {
	Ping,
}

g_update :: proc(s: ^G_State, msg: G_Msg, fx: ^Effects(G_Msg)) {}

g_view :: proc(s: G_State, d: Dispatch(G_Msg)) {
	if column({padding = 10, width = grow(), height = grow()}) {
		g_grid = g_grid_view()
	}
}

@(private)
g_grid_view :: proc() -> Virtual_Grid {
	g := virtual_grid({
		id = "grid",
		rows = 100_000,
		columns = 1_000,
		row_height = 40,
		column_width = 50,
		width = grow(),
		height = grow(),
	})
	if g.open {
		for row in g.row_first ..< g.row_last {
			for column in g.column_first ..< g.column_last {
				if virtual_cell(g, row, column) {}
			}
		}
	}
	return g
}

@(private)
g_table :: proc(h: ^Test_Harness(G_State, G_Msg)) -> (A11y_Node, bool) {
	for n in h.window.ctx.a11y {
		if n.role == .Table {
			return n, true
		}
	}
	return {}, false
}

@(private)
g_cell :: proc(h: ^Test_Harness(G_State, G_Msg), row, column: int) -> (A11y_Node, bool) {
	for n in h.window.ctx.a11y {
		if n.role == .Cell && n.row_index == i32(row) && n.column_index == i32(column) {
			return n, true
		}
	}
	return {}, false
}

@(test)
virtual_grid_declares_only_the_cells_in_view :: proc(t: ^testing.T) {
	h := test_harness(G_State{}, g_update, g_view)
	defer test_destroy(h)

	table, ok := g_table(h)
	testing.expect(t, ok, "the grid is a table")
	testing.expect_value(t, table.row_count, 100_000)
	testing.expect_value(t, table.column_count, 1_000)

	cells := 0
	for n in h.window.ctx.a11y {
		if n.role == .Cell {
			cells += 1
		}
	}
	// 580 x 580 of viewport holds 11.6 x 14.5 cells; with overscan that is a few hundred.
	testing.expectf(t, cells > 100 && cells < 1_000, "declared %d cells", cells)

	// The grid knows its exact extent without laying out a single off-screen cell.
	view, max, found := core.scroll_limits(&h.window.ctx, table.id)
	testing.expect(t, found)
	testing.expectf(t, math.abs((max.x + view.x) - 50_000) < 1, "content width %v", max.x + view.x)
	testing.expectf(t, math.abs((max.y + view.y) - 4_000_000) < 1, "content height %v", max.y + view.y)

	corner, has := g_cell(h, 0, 0)
	testing.expect(t, has, "the top-left cell is declared")
	testing.expect(t, corner.rect.x == table.rect.x && corner.rect.y == table.rect.y, "the first cell is at the origin")
}

@(test)
virtual_grid_scrolls_on_both_axes :: proc(t: ^testing.T) {
	h := test_harness(G_State{}, g_update, g_view)
	defer test_destroy(h)

	table, _ := g_table(h)
	// Scroll so row 3 and column 4 start exactly at the viewport's top-left.
	core.set_scroll(&h.window.ctx, table.id, {200, 120})
	test_frame(h)

	table, _ = g_table(h)
	testing.expect_value(t, g_grid.visible_row_first, 3) // 120 / 40
	testing.expect_value(t, g_grid.visible_column_first, 4) // 200 / 50
	cell, found := g_cell(h, 3, 4)
	testing.expect(t, found, "the cell at the scrolled origin is declared")
	testing.expect(
		t,
		math.abs(cell.rect.x - table.rect.x) < 1 && math.abs(cell.rect.y - table.rect.y) < 1,
		"the view starts at row 3, column 4",
	)
}
