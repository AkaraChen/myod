// Data pages: Table, Data Table and Command.
package shadcn

import "core:fmt"

import ui "myod:ui"

@(private)
COLUMNS := []ui.Table_Column {
	{title = "Name", width = 220, sortable = true},
	{title = "Status", width = 120, sortable = true},
	{title = "Amount", width = 120, numeric = true, sortable = true},
	{title = "Date", width = 120, sortable = true},
}

@(private)
cell_text :: proc(record, column: int) -> string {
	switch column {
	case 0:
		return record_name(record)
	case 1:
		return record_status(record)
	case 2:
		return record_amount(record)
	case 3:
		return record_date(record)
	}
	return ""
}

@(private)
small_cell :: proc(user: rawptr, row, column: int) -> string {
	return cell_text(row, column)
}

@(private)
data_cell :: proc(user: rawptr, row, column: int) -> string {
	s := (^State)(user)
	record := row
	if row >= 0 && row < len(s.rows) {
		record = s.rows[row]
	}
	return cell_text(record, column)
}

// ---- Table ----

@(private)
page_table :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "table-basic"})) {
		ui.text("Basic", .Subsection)
		note("Click a header to sort, click a cell to select it, Shift+click for rows, and Command/Ctrl+C copies the selection as TSV.")
		res := ui.table({
			id      = "table-demo",
			columns = COLUMNS,
			rows    = 24,
			cell    = small_cell,
			version = 1,
			height  = ui.fixed(360),
			label   = "Recent payments",
		})
		_ = res
		ui.text(
			res.row >= 0 ? fmt.tprintf("Selected row %d, column %d", res.row + 1, res.column + 1) : "Nothing selected",
			.Metadata,
			.Muted,
		)
	}
	if ui.column(panel({id = "table-states"})) {
		ui.text("States", .Subsection)
		note("Every cell is focusable; arrow keys move between cells and the table scrolls to keep the focused cell in view.")
	}
}

// ---- Data Table ----

@(private)
page_data_table :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "data-basic"})) {
		ui.text("Ten thousand rows", .Subsection)
		if ui.row({gap = 12, align_y = .Center, width = ui.grow(), wrap = true}) {
			if r, v := ui.text_input("Filter by name", s.filter, width = ui.fixed(260), key = "dt-filter"); r.changed {
				ui.dispatch(d, Filter_Set{v})
			}
			ui.text(fmt.tprintf("%d rows", len(s.rows)), .Metadata, .Muted)
		}
		// The cell callback reads the display-row mapping through the state pointer.
		st := s
		res := ui.data_table({
			id      = "data-table-demo",
			columns = COLUMNS,
			rows    = len(s.rows),
			cell    = data_cell,
			user    = &st,
			version = s.data_version,
			width   = ui.grow(),
			height  = ui.fixed(420),
			label   = "Payments",
		})
		ui.text(
			res.row >= 0 ? fmt.tprintf("Selected row %d, column %d", res.row + 1, res.column + 1) : "Nothing selected",
			.Metadata,
			.Muted,
		)
	}
	if ui.column(panel({id = "data-states"})) {
		ui.text("States", .Subsection)
		note("The header stays fixed while rows scroll, and moves with the columns horizontally. Drag a column edge to resize it; sorting and filtering are the app's own data.")
	}
}

// ---- Command ----

@(private)
COMMANDS := []ui.Command_Item {
	{value = "new-file", label = "New file", group = "File", hint = "⌘N"},
	{value = "new-window", label = "New window", group = "File", hint = "⇧⌘N"},
	{value = "open-file", label = "Open file…", group = "File", hint = "⌘O"},
	{value = "save", label = "Save", group = "File", hint = "⌘S"},
	{value = "save-as", label = "Save as…", group = "File", hint = "⇧⌘S"},
	{value = "export-pdf", label = "Export as PDF", group = "File"},
	{value = "close-window", label = "Close window", group = "File", hint = "⌘W"},
	{value = "undo", label = "Undo", group = "Edit", hint = "⌘Z"},
	{value = "redo", label = "Redo", group = "Edit", hint = "⇧⌘Z"},
	{value = "cut", label = "Cut", group = "Edit", hint = "⌘X"},
	{value = "copy", label = "Copy", group = "Edit", hint = "⌘C"},
	{value = "paste", label = "Paste", group = "Edit", hint = "⌘V"},
	{value = "select-all", label = "Select all", group = "Edit", hint = "⌘A"},
	{value = "find", label = "Find in file", group = "Edit", hint = "⌘F"},
	{value = "replace", label = "Replace in file", group = "Edit", hint = "⌥⌘F"},
	{value = "zoom-in", label = "Zoom in", group = "View", hint = "⌘+"},
	{value = "zoom-out", label = "Zoom out", group = "View", hint = "⌘-"},
	{value = "toggle-sidebar", label = "Toggle sidebar", group = "View", hint = "⌘B"},
	{value = "toggle-theme", label = "Toggle theme", group = "View"},
	{value = "go-line", label = "Go to line…", group = "Go", hint = "⌃G"},
	{value = "go-file", label = "Go to file…", group = "Go", hint = "⌘P"},
	{value = "go-symbol", label = "Go to symbol…", group = "Go", hint = "⇧⌘O"},
	{value = "run-tests", label = "Run tests", group = "Run"},
	{value = "build", label = "Build", group = "Run", hint = "⌘B"},
	{value = "debug", label = "Start debugging", group = "Run", hint = "F5"},
	{value = "git-commit", label = "Commit staged changes", group = "Git"},
	{value = "git-push", label = "Push", group = "Git"},
	{value = "git-pull", label = "Pull", group = "Git"},
	{value = "settings", label = "Open settings", group = "Preferences", hint = "⌘,"},
	{value = "keyboard", label = "Keyboard shortcuts", group = "Preferences", hint = "⌘K"},
	{value = "about", label = "About myod", group = "Help"},
}

@(private)
page_command :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "command-basic"})) {
		ui.text("Basic", .Subsection)
		note("A fuzzy palette: type any subsequence of a command's label, Up/Down move, Enter runs it, Esc closes.")
		if ui.row({gap = 8}) {
			if b := ui.button("Open command palette", variant = .Outline); b.clicked {
				ui.dispatch(d, Cmd_Set{true})
			}
		}
		ui.text(
			s.cmd_picked == "" ? "Nothing run yet" : fmt.tprintf("Last command: %s", s.cmd_picked),
			.Metadata,
			.Muted,
		)
		if _, picked := ui.command(d, Cmd_Set{false}, s.cmd_open, COMMANDS, "command-demo"); picked != "" {
			ui.dispatch(d, Cmd_Picked{picked})
		}
	}
	if ui.column(panel({id = "command-states"})) {
		ui.text("States", .Subsection)
		note("With no match the list says so; the highlight is virtualized, so a palette of thousands stays cheap.")
	}
}
