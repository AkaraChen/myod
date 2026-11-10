// Tests of the M8 component set's keyboard operation and semantics (ARCHITECTURE.md, "Testing"):
// everything a screen-reader user does — Tab to a widget, activate it, read what changed — has to
// work without a pointer.
package ui

import "core:fmt"
import "core:strings"
import "core:testing"

import "../platform"

// ---- Accordion and Collapsible ----

Accordion_Demo :: struct {
	open: [2]bool,
}

Accordion_Toggle :: struct {
	i: int,
}

accordion_update :: proc(s: ^Accordion_Demo, msg: Accordion_Toggle, fx: ^Effects(Accordion_Toggle)) {
	s.open[msg.i] = !s.open[msg.i]
}

accordion_view :: proc(s: Accordion_Demo, d: Dispatch(Accordion_Toggle)) {
	if column({width = fixed(420), padding = 20, gap = 4}) {
		for label, i in ([2]string{"Shipping", "Returns"}) {
			it := accordion_item(label, s.open[i])
			if it.res.changed {
				dispatch(d, Accordion_Toggle{i})
			}
			if it.body {
				text(fmt.tprintf("%s details", label), .Compact)
			}
		}
		it := collapsible("Advanced", s.open[1], "advanced")
		if it.res.changed {
			dispatch(d, Accordion_Toggle{1})
		}
		if it.body {
			text("Advanced details", .Compact)
		}
	}
}

@(test)
accordion_keyboard :: proc(t: ^testing.T) {
	h := test_harness(Accordion_Demo{}, accordion_update, accordion_view)
	defer test_destroy(h)

	// The header is a button with its expanded state announced.
	testing.expect(t, test_click(h, .Button, "Shipping"))
	testing.expect(t, h.store.state.open[0], "a click opens the item")
	testing.expect(t, test_find(h, .Static_Text, "Shipping details") != nil, "the body is declared")
	n := test_find(h, .Button, "Shipping")
	testing.expect(t, n != nil && .Expanded in n.flags, "the expanded state is announced")

	// Space closes it again: a focused header is activatable from the keyboard.
	test_key(h, .Space)
	testing.expect(t, !h.store.state.open[0], "Space toggles the item")
	testing.expect(t, test_find(h, .Static_Text, "Shipping details") == nil, "the body is gone")

	// Tab reaches the next header, and Enter toggles that one.
	test_key(h, .Tab)
	test_key(h, .Enter)
	testing.expect(t, h.store.state.open[1], "Enter toggles the focused header")
	testing.expect(t, test_find(h, .Static_Text, "Returns details") != nil)
}

@(test)
collapsible_keyboard :: proc(t: ^testing.T) {
	h := test_harness(Accordion_Demo{}, accordion_update, accordion_view)
	defer test_destroy(h)

	testing.expect(t, test_click(h, .Button, "Advanced"))
	testing.expect(t, h.store.state.open[1])
	testing.expect(t, test_find(h, .Static_Text, "Advanced details") != nil)
	test_key(h, .Space)
	testing.expect(t, !h.store.state.open[1])
}

// ---- Breadcrumb, Pagination ----

Breadcrumb_Demo :: struct {
	crumb: int,
	page:  int,
	last:  int,
}

CRUMBS := [3]string{"Home", "Components", "Breadcrumb"}

Breadcrumb_Msg :: struct {
	kind:  int, // 0: crumb, 1: page
	value: int,
}

breadcrumb_update :: proc(s: ^Breadcrumb_Demo, msg: Breadcrumb_Msg, fx: ^Effects(Breadcrumb_Msg)) {
	switch msg.kind {
	case 0:
		s.crumb = msg.value
		s.last = msg.value
	case 1:
		s.page = msg.value
		s.last = msg.value
	}
}

breadcrumb_view :: proc(s: Breadcrumb_Demo, d: Dispatch(Breadcrumb_Msg)) {
	if column({width = fixed(500), padding = 20, gap = 12}) {
		if res, i := breadcrumb(CRUMBS[:], "crumbs"); res.changed {
			dispatch(d, Breadcrumb_Msg{0, i})
		}
		if res, p := pagination(s.page, 10, "pages"); res.changed {
			dispatch(d, Breadcrumb_Msg{1, p})
		}
		text(fmt.tprintf("crumb %d page %d", s.crumb, s.page), .Compact)
	}
}

@(test)
breadcrumb_and_pagination_keyboard :: proc(t: ^testing.T) {
	h := test_harness(Breadcrumb_Demo{}, breadcrumb_update, breadcrumb_view)
	defer test_destroy(h)

	// Tab to the second crumb and activate it with Enter.
	testing.expect(t, test_click(h, .Button, "Home"))
	testing.expect_value(t, h.store.state.crumb, 0)
	test_key(h, .Tab)
	test_key(h, .Enter)
	testing.expect_value(t, h.store.state.crumb, 1)

	// The current page is exposed (it is a focus stop, so the tree must describe it).
	n := test_find(h, .Group, "Breadcrumb")
	testing.expect(t, n != nil, "the current crumb has a semantic node")
	testing.expect(t, n != nil && .Selected in n.flags, "and is marked selected")

	// Pagination: clicking Next focuses it, and Enter activates the focus again.
	testing.expect(t, test_click(h, .Button, "Next page"))
	testing.expect_value(t, h.store.state.page, 1)
	test_key(h, .Enter)
	testing.expect_value(t, h.store.state.page, 2)

	// The page buttons are activatable from the keyboard too.
	testing.expect(t, test_click(h, .Button, "Page 10"))
	testing.expect_value(t, h.store.state.page, 9)
}

@(test)
pagination_disabled_arrow :: proc(t: ^testing.T) {
	h := test_harness(Breadcrumb_Demo{}, breadcrumb_update, breadcrumb_view)
	defer test_destroy(h)

	// Previous page at the first page is disabled: the tree says so and a click changes nothing.
	n := test_find(h, .Button, "Previous page")
	testing.expect(t, n != nil && .Disabled in n.flags, "the arrow at the first page is disabled")
	test_click(h, .Button, "Previous page")
	testing.expect_value(t, h.store.state.page, 0)
}

// ---- Sidebar, Carousel ----

Sidebar_Demo :: struct {
	active: int,
	slide:  int,
}

Sidebar_Msg :: struct {
	kind: int, // 0: sidebar, 1: carousel
	to:   int,
}

sidebar_update :: proc(s: ^Sidebar_Demo, msg: Sidebar_Msg, fx: ^Effects(Sidebar_Msg)) {
	if msg.kind == 0 {
		s.active = msg.to
	} else {
		s.slide = msg.to
	}
}

sidebar_view :: proc(s: Sidebar_Demo, d: Dispatch(Sidebar_Msg)) {
	if row({width = grow(), height = grow(), padding = 20, gap = 12}) {
		if sidebar() {
			sidebar_group("Main")
			for label, i in ([3]string{"Inbox", "Drafts", "Sent"}) {
				if it := sidebar_item(label, active = i == s.active); it.clicked {
					dispatch(d, Sidebar_Msg{0, i})
				}
			}
		}
		if column({width = grow(), height = grow(), gap = 8}) {
			if carousel(fixed(120)) {
				text(fmt.tprintf("Slide %d", s.slide + 1), .Subsection)
			}
			if _, slide := carousel_controls(s.slide, 3, "slides"); slide != s.slide {
				dispatch(d, Sidebar_Msg{1, slide})
			}
		}
	}
	text(fmt.tprintf("active %d slide %d", s.active, s.slide), .Metadata)
}

@(test)
sidebar_and_carousel_keyboard :: proc(t: ^testing.T) {
	h := test_harness(Sidebar_Demo{}, sidebar_update, sidebar_view)
	defer test_destroy(h)

	testing.expect(t, test_click(h, .Button, "Drafts"))
	testing.expect_value(t, h.store.state.active, 1)
	n := test_find(h, .Button, "Drafts")
	testing.expect(t, n != nil && .Selected in n.flags, "the active entry is selected")

	// Carousel dots: focus one with a click, Tab to the next, activate it with Enter.
	testing.expect(t, test_click(h, .Button, "Slide 1"))
	testing.expect_value(t, h.store.state.slide, 0)
	test_key(h, .Tab)
	test_key(h, .Enter)
	testing.expect_value(t, h.store.state.slide, 1)
	n = test_find(h, .Button, "Slide 2")
	testing.expect(t, n != nil && .Selected in n.flags, "the current slide is selected")

	// The current slide's text is declared inside the frame.
	testing.expect(t, test_find(h, .Static_Text, "Slide 2") != nil)
}

// ---- Input OTP ----

Otp_Demo :: struct {
	code: string,
}

Otp_Set :: struct {
	code: string,
}

otp_update :: proc(s: ^Otp_Demo, msg: Otp_Set, fx: ^Effects(Otp_Set)) {
	s.code = strings.clone(msg.code)
}

otp_view :: proc(s: Otp_Demo, d: Dispatch(Otp_Set)) {
	if column({width = fixed(400), padding = 20}) {
		if _, v := input_otp(s.code, 4, "otp"); v != s.code {
			dispatch(d, Otp_Set{v})
		}
	}
}

@(test)
input_otp_keyboard :: proc(t: ^testing.T) {
	h := test_harness(Otp_Demo{}, otp_update, otp_view)
	defer test_destroy(h)

	// Typing fills a cell and advances; Backspace on an empty cell moves back and clears.
	testing.expect(t, test_click(h, .Textbox, "Digit 1 of 4"))
	append(&h.window.events, platform.Event{kind = .Text_Input, text = "1"})
	test_frame(h)
	testing.expect_value(t, h.store.state.code, "1")
	append(&h.window.events, platform.Event{kind = .Text_Input, text = "2"})
	test_frame(h)
	testing.expect_value(t, h.store.state.code, "12")

	testing.expect(t, test_find(h, .Textbox, "Digit 3 of 4") != nil)
	test_key(h, .Backspace)
	testing.expect_value(t, h.store.state.code, "1")
}

// ---- Calendar ----

Calendar_Demo :: struct {
	month: Date,
	date:  Date,
}

Calendar_Set :: struct {
	month: Date,
	date:  Date,
}

calendar_update :: proc(s: ^Calendar_Demo, msg: Calendar_Set, fx: ^Effects(Calendar_Set)) {
	s.month = msg.month
	s.date = msg.date
}

calendar_view :: proc(s: Calendar_Demo, d: Dispatch(Calendar_Set)) {
	if column({width = grow(), height = grow(), padding = 20}) {
		cr := calendar(s.month, s.date, "cal")
		if cr.month != s.month || cr.date != s.date {
			dispatch(d, Calendar_Set{cr.month, cr.date})
		}
	}
}

@(test)
calendar_keyboard :: proc(t: ^testing.T) {
	h := test_harness(Calendar_Demo{month = {2026, 11, 1}, date = {2026, 11, 10}}, calendar_update, calendar_view)
	defer test_destroy(h)

	// Days are buttons named by their full date.
	testing.expect(t, test_click(h, .Button, "Nov 15, 2026"))
	testing.expect_value(t, h.store.state.date, Date{2026, 11, 15})

	// Arrows move the selection by a day or a week, across the month's edge when needed.
	test_key(h, .Right)
	testing.expect_value(t, h.store.state.date, Date{2026, 11, 16})
	test_key(h, .Down)
	testing.expect_value(t, h.store.state.date, Date{2026, 11, 23})

	// Tab moves focus to the next day without changing the selection; Enter picks it.
	test_key(h, .Tab)
	test_key(h, .Enter)
	testing.expect_value(t, h.store.state.date, Date{2026, 11, 24})

	// The month arrows switch months.
	testing.expect(t, test_click(h, .Button, "Next month"))
	testing.expect_value(t, h.store.state.month.month, 12)
}

// ---- Date Picker ----

Date_Demo :: struct {
	value: Date,
}

Date_Set :: struct {
	value: Date,
}

date_update :: proc(s: ^Date_Demo, msg: Date_Set, fx: ^Effects(Date_Set)) {
	s.value = msg.value
}

date_view :: proc(s: Date_Demo, d: Dispatch(Date_Set)) {
	if column({width = fixed(400), padding = 20}) {
		if _, v := date_picker(s.value, "dp", fixed(200)); v != s.value {
			dispatch(d, Date_Set{v})
		}
	}
}

@(test)
date_picker_pointer :: proc(t: ^testing.T) {
	h := test_harness(Date_Demo{}, date_update, date_view)
	defer test_destroy(h)

	testing.expect(t, test_click(h, .Button, "Pick a date"))
	testing.expect(t, test_find(h, .Button, "Nov 15, 2026") != nil, "the calendar is open")
	testing.expect(t, test_click(h, .Button, "Nov 15, 2026"))
	testing.expect_value(t, h.store.state.value, Date{2026, 11, 15})
	// The trigger keeps its new name, so look for a control only the calendar has.
	testing.expect(t, test_find(h, .Button, "Next month") == nil, "picking closes the popover")
}

@(test)
date_picker_keyboard :: proc(t: ^testing.T) {
	h := test_harness(Date_Demo{}, date_update, date_view)
	defer test_destroy(h)

	// Opening focuses the layer's first control (the previous-month button); two Tabs reach the
	// grid, then the arrows and Enter pick a day. The grid starts on Oct 26, 2026.
	testing.expect(t, test_click(h, .Button, "Pick a date"))
	test_key(h, .Tab)
	test_key(h, .Tab)
	test_key(h, .Right)
	test_key(h, .Enter)
	testing.expect_value(t, h.store.state.value, Date{2026, 10, 27})
}

@(test)
date_picker_escape :: proc(t: ^testing.T) {
	h := test_harness(Date_Demo{value = {2026, 11, 15}}, date_update, date_view)
	defer test_destroy(h)

	testing.expect(t, test_click(h, .Button, "Nov 15, 2026"))
	test_key(h, .Escape)
	testing.expect(t, test_find(h, .Button, "Nov 16, 2026") == nil, "Esc closes the popover")
	testing.expect_value(t, h.store.state.value, Date{2026, 11, 15})
	// Focus returned to the trigger: Space would reopen it.
	test_key(h, .Space)
	testing.expect(t, test_find(h, .Button, "Nov 16, 2026") != nil, "Space reopens from the trigger")
}

// ---- Table (static) ----

TABLE_DATA := [5][2]string{
	{"Delta", "4"},
	{"Alpha", "2"},
	{"Echo", "5"},
	{"Bravo", "1"},
	{"Charlie", "3"},
}

Table_Demo :: struct{}

table_cell :: proc(user: rawptr, row, column: int) -> string {
	return TABLE_DATA[row][column]
}

table_view :: proc(s: Table_Demo, d: Dispatch(int)) {
	if column({width = grow(), height = grow(), padding = 20, gap = 8}) {
		cols := [2]Table_Column{{title = "Name", width = 120, sortable = true}, {title = "Age", width = 80, numeric = true, sortable = true}}
		tr := table({
			id = "table-test",
			columns = cols[:],
			rows = len(TABLE_DATA),
			cell = table_cell,
			version = 1,
			height = fixed(220),
			label = "People",
		})
		text(fmt.tprintf("state %d %d %d %v", tr.row, tr.column, tr.sort_by, tr.ascending), .Metadata)
	}
}

@(test)
table_sorting_and_keyboard :: proc(t: ^testing.T) {
	h := test_harness(Table_Demo{}, proc(s: ^Table_Demo, msg: int, fx: ^Effects(int)) {}, table_view)
	defer test_destroy(h)

	// The header sorts; the first display row is the alphabetically first name.
	testing.expect(t, test_click(h, .Button, "Name"))
	n := test_find(h, .Cell, "Alpha")
	testing.expect(t, n != nil, "the body cells are exposed as cells")
	if n != nil {
		testing.expect_value(t, n.row_index, 0)
		testing.expect(t, .Selected not_in n.flags, "sorting does not select")
	}

	// Clicking the header again reverses the order.
	testing.expect(t, test_click(h, .Button, "Name"))
	n = test_find(h, .Cell, "Echo")
	testing.expect(t, n != nil)
	if n != nil {
		testing.expect_value(t, n.row_index, 0)
	}

	// A cell click selects it; the arrows move to its neighbours and the selection follows.
	testing.expect(t, test_click(h, .Cell, "Bravo"))
	n = test_find(h, .Cell, "Bravo")
	testing.expect(t, n != nil && .Selected in n.flags, "the clicked cell is selected")
	test_key(h, .Right)
	n = test_find(h, .Cell, "1")
	testing.expect(t, n != nil && .Selected in n.flags, "Right moves to the next column")
	test_key(h, .Down)
	n = test_find(h, .Cell, "2")
	testing.expect(t, n != nil && .Selected in n.flags, "Down moves to the next row")
	n = test_find(h, .Cell, "Alpha")
	testing.expect(t, n != nil && n.row_index == 4, "the sorted order is unchanged")
}

// ---- Data Table ----

Data_Demo :: struct{}

data_cell :: proc(user: rawptr, row, column: int) -> string {
	return fmt.tprintf("%d-%d", row, column)
}

data_view :: proc(s: Data_Demo, d: Dispatch(int)) {
	if column({width = grow(), height = grow(), padding = 20, gap = 8}) {
		cols := [3]Table_Column{{title = "A", width = 100, sortable = true}, {title = "B", width = 100, sortable = true}, {title = "C", width = 100, sortable = true}}
		dt := data_table({
			id = "dt-test",
			columns = cols[:],
			rows = 200,
			cell = data_cell,
			version = 1,
			width = fixed(330),
			height = fixed(240),
			label = "Numbers",
		})
		text(fmt.tprintf("state %d %d %d %v", dt.row, dt.column, dt.sort_column, dt.ascending), .Metadata)
	}
}

@(test)
data_table_keyboard :: proc(t: ^testing.T) {
	h := test_harness(Data_Demo{}, proc(s: ^Data_Demo, msg: int, fx: ^Effects(int)) {}, data_view)
	defer test_destroy(h)

	// The cells are table cells with their row and column recorded; they select on a click.
	testing.expect(t, test_click(h, .Cell, "5-1"))
	testing.expect(t, test_find(h, .Cell, "5-1").flags & {.Selected} != {})
	testing.expect_value(t, test_find(h, .Cell, "5-1").row_index, 5)

	// The arrows move the selection; the focused cell is scrolled into view.
	test_key(h, .Down)
	testing.expect(t, test_find(h, .Cell, "6-1").flags & {.Selected} != {}, "Down moves a row")
	test_key(h, .Right)
	testing.expect(t, test_find(h, .Cell, "6-2").flags & {.Selected} != {}, "Right moves a column")

	// The header sorts, and the first row changes.
	testing.expect(t, test_click(h, .Button, "A"))
	testing.expect(t, test_find(h, .Cell, "0-0").row_index == 0, "the ascending sort starts at row 0")
}

// ---- Command ----

Cmd_Demo :: struct {
	open: bool,
	last: string,
}

Cmd_Msg :: struct {
	kind:  int, // 0: open, 1: close, 2: picked
	value: string,
}

COMMANDS := []Command_Item {
	{value = "copy-link", label = "Copy link"},
	{value = "delete-line", label = "Delete line"},
	{value = "paste", label = "Paste"},
}

cmd_update :: proc(s: ^Cmd_Demo, msg: Cmd_Msg, fx: ^Effects(Cmd_Msg)) {
	switch msg.kind {
	case 0:
		s.open = true
	case 1:
		s.open = false
	case 2:
		s.last = msg.value
	}
}

cmd_view :: proc(s: Cmd_Demo, d: Dispatch(Cmd_Msg)) {
	if column({width = grow(), height = grow(), padding = 20, gap = 8}) {
		if button("Open palette").clicked {
			dispatch(d, Cmd_Msg{kind = 0})
		}
		text(fmt.tprintf("last %s", s.last), .Metadata)
	}
	if _, picked := command(d, Cmd_Msg{kind = 1}, s.open, COMMANDS, "cmd"); picked != "" {
		dispatch(d, Cmd_Msg{kind = 2, value = picked})
	}
}

@(test)
command_palette_keyboard :: proc(t: ^testing.T) {
	h := test_harness(Cmd_Demo{}, cmd_update, cmd_view)
	defer test_destroy(h)

	// The palette opens focused on its search field; Down and Enter run the second command.
	testing.expect(t, test_click(h, .Button, "Open palette"))
	testing.expect(t, h.store.state.open, "the palette is open")
	testing.expect(t, test_find(h, .List, "Commands") != nil, "the results are a list")
	test_key(h, .Down)
	test_key(h, .Enter)
	testing.expect_value(t, h.store.state.last, "delete-line")
	testing.expect(t, !h.store.state.open, "running a command closes the palette")

	// Typing filters the list; Enter runs the one match.
	testing.expect(t, test_click(h, .Button, "Open palette"))
	test_type(h, .Textbox, "Search commands", "past")
	testing.expect(t, test_find(h, .List_Item, "Delete line") == nil, "the filter drops non-matches")
	testing.expect(t, test_find(h, .List_Item, "Paste") != nil)
	test_key(h, .Enter)
	testing.expect_value(t, h.store.state.last, "paste")

	// Esc closes it and leaves the last command alone.
	testing.expect(t, test_click(h, .Button, "Open palette"))
	test_key(h, .Escape)
	testing.expect(t, !h.store.state.open)
	testing.expect_value(t, h.store.state.last, "paste")
}

// ---- Toast ----

Toast_Demo :: struct {
	count: int,
}

Toast_Msg :: struct {
	dismissed: int,
}

toast_update :: proc(s: ^Toast_Demo, msg: Toast_Msg, fx: ^Effects(Toast_Msg)) {
	if msg.dismissed >= 0 {
		s.count = 0
	}
}

toast_view :: proc(s: Toast_Demo, d: Dispatch(Toast_Msg)) {
	if s.count > 0 {
		toasts := [1]Toast{{id = 7, title = "Saved", description = "Your changes were saved."}}
		if r := toast_list(toasts[:], "toasts"); r.dismissed >= 0 {
			dispatch(d, Toast_Msg{dismissed = r.dismissed})
		}
	}
}

@(test)
toast_live_region :: proc(t: ^testing.T) {
	h := test_harness(Toast_Demo{count = 1}, toast_update, toast_view)
	defer test_destroy(h)

	n := test_find(h, .Status, "Saved")
	testing.expect(t, n != nil, "the toast is a status")
	testing.expect(t, n != nil && .Live in n.flags, "and a live region, so it is announced")
	testing.expect(t, test_find(h, .Static_Text, "Your changes were saved.") != nil)

	testing.expect(t, test_click(h, .Button, "Dismiss"))
	testing.expect_value(t, h.store.state.count, 0)
	testing.expect(t, test_find(h, .Status, "Saved") == nil, "dismissing removes the toast")
}

// ---- Avatar and Field ----

Avatar_Demo :: struct{}

avatar_view :: proc(s: Avatar_Demo, d: Dispatch(int)) {
	if column({width = fixed(320), padding = 20, gap = 12}) {
		avatar("Ada Lovelace", 40)
		if f := field("Email", description = "We never share it."); f.open {
			text_input("Email", "", width = fixed(200), hide_label = true)
		}
	}
}

@(test)
avatar_and_field_semantics :: proc(t: ^testing.T) {
	h := test_harness(Avatar_Demo{}, proc(s: ^Avatar_Demo, msg: int, fx: ^Effects(int)) {}, avatar_view)
	defer test_destroy(h)

	n := test_find(h, .Image, "Ada Lovelace")
	testing.expect(t, n != nil, "an avatar exposes the full name, not the initials")
	testing.expect(t, test_find(h, .Static_Text, "Email") != nil, "the field label is text")
	testing.expect(t, test_find(h, .Static_Text, "We never share it.") != nil, "the description is below it")
	testing.expect(t, test_find(h, .Textbox, "Email") != nil, "the control carries the same name")
}
