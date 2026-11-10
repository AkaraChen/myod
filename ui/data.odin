// Table and Data Table: the tabular components of the shadcn/ui set. The Data Table is built on the
// two-axis virtualization of M5, so its cost does not depend on how many rows or columns there are.
// Both share column widths, selection, TSV copying and sorting.
package ui

import "core:fmt"
import "core:sort"
import "core:strconv"
import "core:strings"

import "../core"
import ph "../icons/phosphor"
import "../layout"
import "../platform"

// A column of a table: a title, a width in logical pixels, and how its cells read.
Table_Column :: struct {
	title:    string,
	width:    f32,
	numeric:  bool, // right-aligned, and sorting compares numbers where the text parses
	sortable: bool,
}

// How a table reads its cells: the text of one cell (`user` is passed back).
Table_Cell :: proc(user: rawptr, row, column: int) -> string

@(private)
Table_State :: struct {
	widths:         [dynamic]f32, // per-column widths, kept in step with the app's columns
	order:          [dynamic]int, // display row -> app row, after sorting
	order_version:  u64,
	order_rows:     int,
	sort_column:    int, // -1: unsorted
	sort_ascending: bool,
	// Selection: a cell (sel_column >= 0) or a range of rows (sel_column = -1), from anchor_row.
	sel_row, sel_column, anchor_row: int,
	has_sel:     bool,
	resizing:    int, // the column whose edge is being dragged, -1
	// The frame a click was applied in: a ghost pass sees the same result again, and must not apply
	// it twice.
	input_frame: u64,
}

@(private)
table_state_free :: proc(p: rawptr) {
	st := (^Table_State)(p)
	delete(st.widths)
	delete(st.order)
}

@(private)
table_state :: proc(ctx: ^core.Context, id: Id, columns: []Table_Column) -> ^Table_State {
	st, created := core.state(ctx, id, Table_State)
	if created {
		core.set_state_free(ctx, id, table_state_free)
		st.sort_column = -1
		st.resizing = -1
		st.sel_row = -1
		st.sel_column = -1
		st.anchor_row = -1
	}
	if len(st.widths) != len(columns) {
		resize(&st.widths, len(columns))
		for c, i in columns {
			st.widths[i] = max(c.width, 24)
		}
	}
	if len(st.order) != st.order_rows {
		// Released allocations are not the order's business; just resize.
	}
	return st
}

// ---- Sorting ----

@(private)
Sort_Job :: struct {
	keys:       []string, // by app row
	order:      []int,
	numeric:    bool,
	descending: bool,
}

@(private)
sort_key_less :: proc(a, b: string, numeric: bool) -> bool {
	if numeric {
		na, oka := strconv.parse_f64(a)
		nb, okb := strconv.parse_f64(b)
		if oka && okb {
			return na < nb
		}
	}
	return a < b
}

@(private)
sort_len :: proc(it: sort.Interface) -> int {
	job := (^Sort_Job)(it.collection)
	return len(job.order)
}

@(private)
sort_less :: proc(it: sort.Interface, i, j: int) -> bool {
	job := (^Sort_Job)(it.collection)
	a := job.keys[job.order[i]]
	b := job.keys[job.order[j]]
	if job.descending {
		return sort_key_less(b, a, job.numeric)
	}
	return sort_key_less(a, b, job.numeric)
}

@(private)
sort_swap :: proc(it: sort.Interface, i, j: int) {
	job := (^Sort_Job)(it.collection)
	job.order[i], job.order[j] = job.order[j], job.order[i]
}

// Fills `st.order` with the display order for the current sort. `keys` is by app row.
@(private)
table_reorder :: proc(
	st: ^Table_State,
	rows: int,
	keys: []string,
	column: int,
	numeric: bool,
	ascending: bool,
) {
	resize(&st.order, rows)
	for i in 0 ..< rows {
		st.order[i] = i
	}
	if column < 0 || rows < 2 {
		return
	}
	job := Sort_Job{keys = keys, order = st.order[:], numeric = numeric, descending = !ascending}
	it := sort.Interface{len = sort_len, less = sort_less, swap = sort_swap, collection = &job}
	sort.sort(it)
}

// ---- Selection and copying ----

// Copies the selection as TSV: the selected rows (the anchor's row through the selected row) by the
// selected column, or by every column when the whole rows are selected.
@(private)
table_copy :: proc(
	st: ^Table_State,
	cols: []Table_Column,
	rows: int,
	cell: Table_Cell,
	user: rawptr,
) -> bool {
	if !st.has_sel || st.sel_row < 0 || len(st.order) < rows {
		return false
	}
	r0 := clamp(min(st.anchor_row, st.sel_row), 0, rows - 1)
	r1 := clamp(max(st.anchor_row, st.sel_row), 0, rows - 1)
	c0, c1 := 0, len(cols) - 1
	if st.sel_column >= 0 {
		c0, c1 = st.sel_column, st.sel_column
	}
	b := strings.builder_make(context.temp_allocator)
	for r in r0 ..= r1 {
		app_row := st.order[r]
		for c in c0 ..= c1 {
			if c > c0 {
				strings.write_byte(&b, '\t')
			}
			strings.write_string(&b, cell(user, app_row, c))
		}
		if r < r1 {
			strings.write_byte(&b, '\n')
		}
	}
	platform.set_clipboard_text(strings.to_string(b))
	return true
}

// Whether the keys the focused cell was given ask for a copy (Command/Ctrl + C).
@(private)
table_take_keys :: proc(ctx: ^core.Context, id: Id, st: ^Table_State) -> (copy: bool, delta_r, delta_c: int) {
	delta_r, delta_c = 0, 0
	for e in core.take_keys(ctx, id) {
		if e.kind != .Key_Down {
			continue
		}
		if e.key == .Char && (e.char == 'c' || e.char == 'C') && e.mods & {.Super, .Ctrl} != {} {
			copy = true
			continue
		}
		#partial switch e.key {
		case .Left:
			delta_c = -1
		case .Right:
			delta_c = 1
		case .Up:
			delta_r = -1
		case .Down:
			delta_r = 1
		}
	}
	return
}

// ---- Table (static) ----

Table_Options :: struct {
	id:         Key,
	columns:    []Table_Column,
	rows:       int, // all rows are declared; use `data_table` for large ones
	cell:       Table_Cell,
	user:       rawptr,
	version:    u64, // change when the data changes, so the sort is reapplied
	row_height: f32,
	height:     Size,
	label:      string,
}

Table_Result :: struct {
	res:      Response,
	row:      int, // the selected app row, -1 when none
	column:   int, // the selected column, -1 when whole rows are selected
	sort_by:  int,
	ascending: bool,
}

// A table for small data: a scrolling column of rows with a header row. Its cells are focusable and
// arrow keys move between them; clicking selects, Shift+click selects whole rows, and Command/Ctrl+C
// copies the selection as TSV.
table :: proc(o: Table_Options) -> Table_Result {
	ctx := core.current()
	id := key_id(ctx, o.id)
	st := table_state(ctx, id, o.columns)
	res := Table_Result{res = Response{id = id}, row = st.sel_row, column = st.sel_column}
	row_h := o.row_height if o.row_height > 0 else 32
	keys := make([]string, o.rows, context.temp_allocator)
	for r in 0 ..< o.rows {
		keys[r] = ""
	}
	if st.order_version != o.version || len(st.order) != o.rows || st.order_rows != o.rows {
		col, numeric := -1, false
		if st.sort_column >= 0 && st.sort_column < len(o.columns) {
			col = st.sort_column
			numeric = o.columns[col].numeric
			for r in 0 ..< o.rows {
				keys[r] = o.cell(o.user, r, col)
			}
		}
		table_reorder(st, o.rows, keys, col, numeric, st.sort_ascending)
		st.order_version = o.version
		st.order_rows = o.rows
	}
	total: f32 = 0
	for c in o.columns {
		total += max(c.width, 24)
	}

	outer := layout.Node {
		flex_direction = .Column,
		align_self     = .Stretch,
	}
	item(ctx, &outer, {}, o.height)
	if core.open(ctx, res.res.id, outer, core.Paint_Box{border = .Border_Strong, border_width = 1}, clip = true, label = o.label) {
		core.set_a11y_role(ctx, res.res.id, .Table)
		core.set_rows(ctx, res.res.id, o.rows, -1)
		core.set_cell(ctx, res.res.id, len(o.columns), -1)
		if scroll({width = grow(), height = grow(), gap = 0}) {
			inner := layout.Node {
				flex_direction = .Column,
				gap            = {0, 0},
				size           = {{total, .Px}, {0, .Auto}},
			}
			if core.open(ctx, core.auto_id(ctx), inner, nil) {
				// The header row.
				if row({width = fixed(total), height = fixed(32), align_y = .Center, gap = 0}) {
					for col, c in o.columns {
						cid := core.key_id(ctx, fmt.tprintf("column/%d", c))
						it := core.interact(ctx, cid)
						cell_ln := layout.Node {
							flex_direction = .Row,
							align_items    = .Center,
							justify_content = .End if col.numeric else .Start,
							size           = {{max(col.width, 24), .Px}, {32, .Px}},
							padding        = {8, 8, 0, 0},
							flex_shrink    = 0,
						}
						paint: core.Paint = core.Paint_Box{fill = .Overlay}
						flags := core.Node_Flags{.Hit, .Focusable, .Activate}
						if !col.sortable {
							flags = {.Focusable}
						}
						if core.open(ctx, cid, cell_ln, paint, label = col.title, flags = flags) {
							sorted := st.sort_column == c
							title := layout.Node{}
							core.leaf(ctx, core.auto_id(ctx), title, core.Paint_Text {
								s     = col.title,
								style = text_style(.Label),
								color = .Fg if sorted else .Muted,
								wrap  = false,
							}, measured = true)
							if sorted {
								g := layout.Node{size = {{10, .Px}, {10, .Px}}}
								core.leaf(ctx, core.auto_id(ctx), g, core.Paint_Icon {
									icon = ph.CARET_UP if st.sort_ascending else ph.CARET_DOWN,
									weight = .Bold,
									color = .Fg,
								})
							}
						}
						core.close(ctx)
						if it.clicked && col.sortable && st.input_frame != ctx.frame {
							st.input_frame = ctx.frame
							if st.sort_column == c {
								st.sort_ascending = !st.sort_ascending
							} else {
								st.sort_column = c
								st.sort_ascending = true
							}
							st.order_version = 0 // re-sort on the next pass
							core.unsettle(ctx)
						}
					}
				}
				divider()
				// The rows, in display order.
				for dr in 0 ..< min(o.rows, len(st.order)) {
					app_row := st.order[dr]
					if column({width = fixed(total), height = fixed(row_h + 1), gap = 0}) {
						if row({width = grow(), height = fixed(row_h), align_y = .Center, gap = 0}) {
							for col, c in o.columns {
								cid := core.key_id_int(ctx, dr * max(len(o.columns), 1) + c)
								it := core.interact(ctx, cid)
								selected := st.has_sel && st.sel_column == c && st.sel_row == dr
								in_row_sel := st.has_sel && st.sel_column < 0 && dr >= min(st.anchor_row, st.sel_row) && dr <= max(st.anchor_row, st.sel_row)
								cell_ln := layout.Node {
									flex_direction = .Row,
									align_items    = .Center,
									justify_content = .End if col.numeric else .Start,
									size           = {{max(col.width, 24), .Px}, {row_h, .Px}},
									padding        = {8, 8, 0, 0},
									flex_shrink    = 0,
								}
								paint: core.Paint
								if selected || in_row_sel {
									paint = core.Paint_Box{fill = .Overlay_Hover}
								} else if it.hovered {
									paint = core.Paint_Box{fill = .Overlay}
								}
								if core.open(ctx, cid, cell_ln, paint, label = o.cell(o.user, app_row, c), flags = {.Hit, .Focusable, .Activate, .Arrows}) {
									core.set_a11y_role(ctx, cid, .Cell)
									core.set_rows(ctx, cid, o.rows, dr)
									core.set_cell(ctx, cid, len(o.columns), c)
									t := layout.Node{}
									core.leaf(ctx, core.auto_id(ctx), t, core.Paint_Text {
										s = o.cell(o.user, app_row, c),
										style = text_style(.Compact),
										color = .Fg,
										wrap = false,
									}, measured = true)
									if selected {
										core.set_a11y_state(ctx, cid, {.Selected})
									}
								}
								core.close(ctx)
								if it.clicked && st.input_frame != ctx.frame {
									st.input_frame = ctx.frame
									shift := .Shift in ctx.input.mods
									st.has_sel = true
									st.sel_row = dr
									if shift {
										st.sel_column = -1
									} else {
										st.sel_column = c
										st.anchor_row = dr
									}
									core.unsettle(ctx)
								}
								if it.focused {
									do_copy, dr_delta, dc_delta := table_take_keys(ctx, cid, st)
									if do_copy {
										table_copy(st, o.columns, o.rows, o.cell, o.user)
									}
									if dr_delta != 0 || dc_delta != 0 {
										nr := clamp(dr + dr_delta, 0, o.rows - 1)
										nc := clamp(c + dc_delta, 0, len(o.columns) - 1)
										core.set_focus(ctx, core.key_id_int(ctx, nr * max(len(o.columns), 1) + nc), true)
										core.ensure_visible(ctx, core.key_id_int(ctx, nr * max(len(o.columns), 1) + nc))
										st.has_sel = true
										st.sel_row = nr
										st.sel_column = nc
										st.anchor_row = nr
										core.unsettle(ctx)
									}
								}
							}
						}
						divider()
					}
				}
			}
			core.close(ctx)
		}
	}
	core.close(ctx)
	res.res = response(ctx, id)
	res.row = st.sel_row
	res.column = st.sel_column
	res.sort_by = st.sort_column
	res.ascending = st.sort_ascending
	return res
}

// ---- Data Table ----

Data_Table_Options :: struct {
	id:            Key,
	columns:       []Table_Column,
	rows:          int, // the filtered rows; sorting happens over these
	cell:          Table_Cell,
	user:          rawptr,
	version:       u64, // change when the data (or the filter) changes
	row_height:    f32,
	header_height: f32,
	width, height: Size,
	label:         string,
}

Data_Table :: struct {
	res:         Response,
	row:         int,
	column:      int,
	sort_column: int,
	ascending:   bool,
}

@(private)
DT_HEADER_H :: f32(32)

// The ID of the cell at a display row and column (the same derivation `virtual_cell` uses).
@(private)
dt_cell_id :: proc(ctx: ^core.Context, g: Virtual_Grid, row, column: int) -> Id {
	return core.key_id_int(ctx, row * max(g.column_count, 1) + column)
}

// A table of any size: only the cells in view are declared, on both axes. The header stays fixed
// while rows scroll under it and moves with the columns horizontally; column edges are draggable,
// headers sort, cells and rows select, and Command/Ctrl+C copies the selection as TSV. Screen
// readers see a table with its row and column counts, rows and cells.
data_table :: proc(o: Data_Table_Options) -> Data_Table {
	ctx := core.current()
	id := key_id(ctx, o.id)
	st := table_state(ctx, id, o.columns)
	out := Data_Table{res = Response{id = id}, row = st.sel_row, column = st.sel_column}
	rh := o.row_height if o.row_height > 0 else 32
	hh := o.header_height if o.header_height > 0 else DT_HEADER_H

	// Sorting: the keys come from the app's cells, by app row.
	if st.order_version != o.version || st.order_rows != o.rows {
		keys := make([]string, o.rows, context.temp_allocator)
		col, numeric := -1, false
		if st.sort_column >= 0 && st.sort_column < len(o.columns) {
			col = st.sort_column
			numeric = o.columns[col].numeric
			for r in 0 ..< o.rows {
				keys[r] = o.cell(o.user, r, col)
			}
		}
		table_reorder(st, o.rows, keys, col, numeric, st.sort_ascending)
		st.order_version = o.version
		st.order_rows = o.rows
	}

	g := virtual_grid({
		id = o.id,
		rows = o.rows,
		columns = len(o.columns),
		row_height = rh,
		column_width = 100,
		column_widths = st.widths[:],
		width = o.width,
		height = o.height,
		border = .Strong,
		label = o.label,
	})
	if g.open {
		if g.row_last <= g.row_first || g.column_last <= g.column_first || len(st.order) < o.rows {
			// Nothing on screen; the header below still belongs to the grid.
		}
		for r in g.row_first ..< min(g.row_last, len(st.order)) {
			app_row := st.order[r]
			for c in g.column_first ..< g.column_last {
				if c >= len(o.columns) {
					continue
				}
				col := o.columns[c]
				text_value := o.cell(o.user, app_row, c)
				selected := st.has_sel && st.sel_column == c && st.sel_row == r
				in_row := st.has_sel && st.sel_column < 0 && r >= min(st.anchor_row, st.sel_row) && r <= max(st.anchor_row, st.sel_row)
				fill: Fill
				if selected || in_row {
					fill = .Overlay
				}
				cid := dt_cell_id(ctx, g, r, c)
				it := core.interact(ctx, cid)
				if it.hovered && !selected && !in_row {
					fill = .Bg
				}
				// The cell's own block: `virtual_cell` closes its node when the block ends, so the
				// navigation below runs in the grid's scope, where the same IDs are derived.
				{
					if virtual_cell(g, r, c, {
						padding = {8, 0, 8, 0},
						fill = fill,
						label = text_value,
						interactive = true,
					}) {
						t := layout.Node{align_self = .End if col.numeric else .Start}
						core.leaf(ctx, core.auto_id(ctx), t, core.Paint_Text {
							s     = text_value,
							style = text_style(.Compact),
							color = .Fg,
							wrap  = false,
						}, measured = true)
						if selected {
							core.set_a11y_state(ctx, cid, {.Selected})
						}
					}
				}
				ir := core.interact(ctx, cid)
				if ir.clicked && st.input_frame != ctx.frame {
					st.input_frame = ctx.frame
					st.has_sel = true
					st.sel_row = r
					if .Shift in ctx.input.mods {
						st.sel_column = -1
					} else {
						st.sel_column = c
						st.anchor_row = r
					}
					core.unsettle(ctx)
				}
				if ir.focused {
					do_copy, dr, dc := table_take_keys(ctx, cid, st)
					if do_copy {
						table_copy(st, o.columns, o.rows, o.cell, o.user)
					}
					if dr != 0 || dc != 0 {
						nr := clamp(r + dr, 0, o.rows - 1)
						nc := clamp(c + dc, 0, len(o.columns) - 1)
						// Bring the cell into view by moving the grid's own scroll offsets.
						x := cell_x(g, nc)
						y := f32(nr) * rh
						view := [2]f32{1, 1}
						if rect, ok := core.last_rect(ctx, g.id); ok && rect.w > 0 && rect.h > 0 {
							view = {rect.w, rect.h}
						}
						off := g.offset
						if x < off.x {
							off.x = x
						} else if x + cell_w(g, nc) > off.x + view.x {
							off.x = x + cell_w(g, nc) - view.x
						}
						if y < off.y {
							off.y = y
						} else if y + rh > off.y + view.y {
							off.y = y + rh - view.y
						}
						if off != g.offset {
							core.set_scroll(ctx, g.id, off)
						}
						core.set_focus(ctx, dt_cell_id(ctx, g, nr, nc), true)
						st.has_sel = true
						st.sel_row = nr
						st.sel_column = nc
						st.anchor_row = nr
						core.unsettle(ctx)
					}
				}
			}
		}

		// The header, fixed vertically and moving horizontally with the columns: positioned in
		// content coordinates at the grid's current offset, and declared after the cells so it
		// paints over them.
		for c in g.column_first ..< g.column_last {
			if c >= len(o.columns) {
				continue
			}
			col := o.columns[c]
			hid := core.key_id(ctx, fmt.tprintf("header/%d", c))
			hit := core.interact(ctx, hid)
			hln := layout.Node {
				position       = 1,
				flex_direction = .Row,
				align_items    = .Center,
				justify_content = .End if col.numeric else .Start,
				gap            = {6, 6},
				size           = {{cell_w(g, c), .Px}, {hh, .Px}},
				padding        = {8, 8, 0, 0},
			}
			hln.inset[0] = {cell_x(g, c), .Px}
			hln.inset[1] = {g.offset.y, .Px}
			flags := core.Node_Flags{.Hit, .Focusable, .Activate}
			if core.open(ctx, hid, hln, core.Paint_Box{fill = .Bg_Solid}, label = col.title, flags = flags) {
				sorted := st.sort_column == c
				title := layout.Node{}
				core.leaf(ctx, core.auto_id(ctx), title, core.Paint_Text {
					s     = col.title,
					style = text_style(.Label),
					color = .Fg if sorted else .Muted,
					wrap  = false,
				}, measured = true)
				if sorted {
					icon := layout.Node{size = {{10, .Px}, {10, .Px}}}
					core.leaf(ctx, core.auto_id(ctx), icon, core.Paint_Icon {
						icon = ph.CARET_UP if st.sort_ascending else ph.CARET_DOWN,
						weight = .Bold,
						color = .Fg,
					})
				}
				// The bottom edge.
				line := layout.Node{position = 1, size = {{0, .Auto}, {1, .Px}}}
				line.inset[3] = {0, .Px}
				core.leaf(ctx, core.auto_id(ctx), line, core.Paint_Box{fill = .Border_Strong})
			}
			core.close(ctx)
			if hit.clicked && st.input_frame != ctx.frame {
				st.input_frame = ctx.frame
				if !col.sortable {
					// Not sortable: nothing to do.
				} else if st.sort_column == c {
					st.sort_ascending = !st.sort_ascending
					st.order_version = 0
				} else {
					st.sort_column = c
					st.sort_ascending = true
					st.order_version = 0
				}
				if col.sortable {
					core.unsettle(ctx)
				}
			}
			// The column's edge: a 6px grip that drags the width.
			gid := core.key_id(ctx, fmt.tprintf("resize/%d", c))
			git := core.interact(ctx, gid)
			gln := layout.Node{position = 1, size = {{6, .Px}, {hh, .Px}}}
			gln.inset[2] = {-3, .Px}
			gln.inset[1] = {g.offset.y, .Px}
			paint: core.Paint
			if git.hovered || git.held {
				paint = core.Paint_Box{fill = .Border_Strong}
			}
			if core.open(ctx, gid, gln, paint, flags = {.Hit}) {
				// Cursor feedback while over the edge.
				if git.hovered || git.held {
					platform.set_cursor(.Resize_Horizontal)
				}
			}
			core.close(ctx)
			if git.held {
				if rect, ok := core.last_rect(ctx, hid); ok {
					p := core.pointer(ctx)
					st.widths[c] = clamp(p.x - rect.x, 40, 800)
					st.resizing = c
				}
			} else if st.resizing == c {
				st.resizing = -1
			}
		}
		// `virtual_grid` closes its node itself, when this procedure's scope ends.
	}
	out.res = response(ctx, id)
	out.row = st.sel_row
	out.column = st.sel_column
	out.sort_column = st.sort_column
	out.ascending = st.sort_ascending
	return out
}
