// 06_columns: a table with one million rows and a hundred thousand columns (ROADMAP.md, M5,
// "horizontal virtualization").
//
// `ui.virtual_grid` virtualizes both axes: it declares only the cells in view (plus a little
// overscan), positions them itself, and reports the full extent to the scroll container, so the
// cost of a frame does not depend on the size of the table. The wheel scrolls vertically, a
// horizontal trackpad gesture scrolls the columns; the footer names the visible cell rectangle.
package columns

import "core:fmt"

import ui "myod:ui"

ROWS :: 1_000_000
COLUMNS :: 100_000

State :: struct {}

// The grid owns its scrolling; the store is here for the frame loop's shape. A message type with a
// single unused case is enough for `Store`.
Ping :: struct {}

Msg :: union {
	Ping,
}

update :: proc(s: ^State, msg: Msg, fx: ^ui.Effects(Msg)) {}

view :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column({padding = 16, gap = 8, height = ui.grow()}) {
		if ui.row({gap = 12, align_y = .Center, width = ui.grow()}) {
			ui.text("十万列", .Page_Title)
			ui.spacer()
			ui.text("1,000,000 行 × 100,000 列", .Metadata, color = .Faint)
		}
		g := grid()
		footer(g)
	}
}

// The grid's `@(deferred_out)` close runs at the end of this proc, so anything declared after the
// call in `view` is a sibling of the grid, not a child of its scroll container.
grid :: proc() -> ui.Virtual_Grid {
	g := ui.virtual_grid({
		id = "grid",
		rows = ROWS,
		columns = COLUMNS,
		row_height = 28,
		column_width = 120,
		width = ui.grow(),
		height = ui.grow(),
		border = .Default,
	})
	if g.open {
		for row in g.row_first ..< g.row_last {
			for column in g.column_first ..< g.column_last {
				if ui.virtual_cell(g, row, column, {padding = {10, 4, 10, 4}}) {
					ui.text(fmt.tprintf("R%d · C%d", row + 1, column + 1), .Compact, color = .Muted, wrap = false)
				}
			}
		}
	}
	return g
}

footer :: proc(g: ui.Virtual_Grid) {
	if ui.row({gap = 8, align_y = .Center, width = ui.grow()}) {
		ui.text("1,000,000 行 · 100,000 列", .Metadata, color = .Faint)
		ui.spacer()
		if g.open && g.row_count > 0 && g.column_count > 0 {
			ui.text(
				fmt.tprintf(
					"显示 R%d–R%d · C%d–C%d",
					g.visible_row_first + 1,
					g.visible_row_last,
					g.visible_column_first + 1,
					g.visible_column_last,
				),
				.Metadata,
				color = .Faint,
			)
		}
	}
}

main :: proc() {
	window := ui.open_window({title = "十万列", size = {1000, 720}})
	defer ui.close_window(&window)

	store: ui.Store(State, Msg)
	ui.store_init(&store, &window, State{}, update)
	defer ui.store_destroy(&store)

	for ui.next_frame(&window) {
		view(store.state, ui.dispatcher(&store))
	}
}
