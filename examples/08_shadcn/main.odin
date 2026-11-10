// The M8 acceptance example: the full shadcn/ui component set, one page per component, in the order
// of the shadcn docs. Every page shows all the states of its component, and everything is operable
// with the keyboard and a screen reader.
//
// The pages are in pages_*.odin. Toasts are application state here: each one schedules a `ui.after`
// timer carrying its generation token, so a toast dismissed before its timer fires is not removed a
// second time.
package shadcn

import "core:fmt"
import "core:strings"
import "core:time"

import ui "myod:ui"

// ---- Pages ----

Page :: enum {
	Popover,
	Hover_Card,
	Context_Menu,
	Menubar,
	Navigation_Menu,
	Select,
	Combobox,
	Dialog,
	Alert_Dialog,
	Sheet,
	Drawer,
	Accordion,
	Collapsible,
	Breadcrumb,
	Pagination,
	Sidebar,
	Carousel,
	Field,
	Input_OTP,
	Calendar,
	Date_Picker,
	Table,
	Data_Table,
	Command,
	Toast,
	Avatar,
	Chart_Bar,
	Chart_Line,
	Chart_Area,
	Chart_Pie,
	Chart_Radar,
}

Group :: struct {
	name:  string,
	pages: []Page,
}

GROUPS := []Group {
	{"Popup and overlay", []Page{.Popover, .Hover_Card, .Context_Menu, .Menubar, .Navigation_Menu, .Select, .Combobox, .Dialog, .Alert_Dialog, .Sheet, .Drawer}},
	{"Structure", []Page{.Accordion, .Collapsible, .Breadcrumb, .Pagination, .Sidebar, .Carousel}},
	{"Forms", []Page{.Field, .Input_OTP, .Calendar, .Date_Picker}},
	{"Data", []Page{.Table, .Data_Table, .Command}},
	{"Feedback and identity", []Page{.Toast, .Avatar}},
	{"Charts", []Page{.Chart_Bar, .Chart_Line, .Chart_Area, .Chart_Pie, .Chart_Radar}},
}

page_label :: proc(p: Page) -> string {
	switch p {
	case .Popover:
		return "Popover"
	case .Hover_Card:
		return "Hover Card"
	case .Context_Menu:
		return "Context Menu"
	case .Menubar:
		return "Menubar"
	case .Navigation_Menu:
		return "Navigation Menu"
	case .Select:
		return "Select"
	case .Combobox:
		return "Combobox"
	case .Dialog:
		return "Dialog"
	case .Alert_Dialog:
		return "Alert Dialog"
	case .Sheet:
		return "Sheet"
	case .Drawer:
		return "Drawer"
	case .Accordion:
		return "Accordion"
	case .Collapsible:
		return "Collapsible"
	case .Breadcrumb:
		return "Breadcrumb"
	case .Pagination:
		return "Pagination"
	case .Sidebar:
		return "Sidebar"
	case .Carousel:
		return "Carousel"
	case .Field:
		return "Field"
	case .Input_OTP:
		return "Input OTP"
	case .Calendar:
		return "Calendar"
	case .Date_Picker:
		return "Date Picker"
	case .Table:
		return "Table"
	case .Data_Table:
		return "Data Table"
	case .Command:
		return "Command"
	case .Toast:
		return "Toast"
	case .Avatar:
		return "Avatar"
	case .Chart_Bar:
		return "Bar Chart"
	case .Chart_Line:
		return "Line Chart"
	case .Chart_Area:
		return "Area Chart"
	case .Chart_Pie:
		return "Pie Chart"
	case .Chart_Radar:
		return "Radar Chart"
	}
	return ""
}

page_lede :: proc(p: Page) -> string {
	switch p {
	case .Popover:
		return "An anchored panel with focus and close handling of its own."
	case .Hover_Card:
		return "A preview that appears after the trigger has been hovered or focused for a moment."
	case .Context_Menu:
		return "A menu opened by a right click on its target."
	case .Menubar:
		return "A bar of menus; Left and Right move between them while one is open."
	case .Navigation_Menu:
		return "A navigation bar whose items open panels."
	case .Select:
		return "A single-choice listbox with keyboard selection."
	case .Combobox:
		return "A searchable select: typing filters, Up/Down move, Enter picks."
	case .Dialog:
		return "A modal dialog: focus is trapped, Esc and a click outside close it."
	case .Alert_Dialog:
		return "A confirmation with a cancel and a confirm action."
	case .Sheet:
		return "A modal panel attached to a window edge. It appears instantly."
	case .Drawer:
		return "A sheet from the bottom edge, with a grab handle."
	case .Accordion:
		return "Stacked sections that expand and collapse instantly."
	case .Collapsible:
		return "One section with a trigger."
	case .Breadcrumb:
		return "The trail to the current page; every step is focusable."
	case .Pagination:
		return "Page numbers with ellipses, previous and next."
	case .Sidebar:
		return "A navigation rail with groups, icons and counts."
	case .Carousel:
		return "Slides with arrows and dots; switching is instant."
	case .Field:
		return "A label, a control and either a description or an error."
	case .Input_OTP:
		return "One digit per cell; typing advances, Backspace goes back."
	case .Calendar:
		return "A month grid with arrow-key day navigation."
	case .Date_Picker:
		return "A trigger and a calendar in a popover."
	case .Table:
		return "A small table: sorting, cell and row selection, TSV copying."
	case .Data_Table:
		return "Ten thousand rows, virtualized on both axes: fixed header, sorting, resizing, filtering, TSV copying."
	case .Command:
		return "A fuzzy command palette with a virtualized result list."
	case .Toast:
		return "Application-owned toasts, dismissed by a timer with generation filtering."
	case .Avatar:
		return "A square avatar with initials, at three sizes."
	case .Chart_Bar:
		return "Bars, stacked and grouped, rasterized once per data version and size."
	case .Chart_Line:
		return "Lines with a hover crosshair and a value tooltip."
	case .Chart_Area:
		return "Filled areas, with the same overlay hover."
	case .Chart_Pie:
		return "A pie and a donut; hovering a slice shows its share."
	case .Chart_Radar:
		return "Overlaid series on shared axes."
	}
	return ""
}

// ---- Data ----

@(private)
DT_COUNT :: 10000

@(private)
FIRST_NAMES := []string{"Ada", "Grace", "Alan", "Edsger", "Barbara", "Donald", "Margaret", "Linus", "Ken", "Frances", "John", "Anita", "Niklaus", "Radia", "Vint", "Shafi"}
@(private)
LAST_NAMES := []string{"Lovelace", "Hopper", "Turing", "Dijkstra", "Liskov", "Knuth", "Hamilton", "Torvalds", "Thompson", "Allen", "McCarthy", "Borg", "Wirth", "Perlman", "Cerf", "Goldwasser"}
@(private)
STATUSES := []string{"Active", "Pending", "Paused", "Archived"}
@(private)
MONTHS := []string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

@(private)
record_name :: proc(i: int) -> string {
	first := FIRST_NAMES[i % len(FIRST_NAMES)]
	last := LAST_NAMES[(i / len(FIRST_NAMES)) % len(LAST_NAMES)]
	return fmt.tprintf("%s %s %d", first, last, i + 1)
}

@(private)
record_status :: proc(i: int) -> string {
	return STATUSES[i % len(STATUSES)]
}

@(private)
record_amount :: proc(i: int) -> string {
	// A deterministic, parseable amount, so numeric sorting is exercised.
	cents := (i * 7919) % 900000 + 1000
	return fmt.tprintf("%d.%02d", cents / 100, cents % 100)
}

@(private)
record_date :: proc(i: int) -> string {
	day := i % 28 + 1
	month := (i / 28) % 12 + 1
	return fmt.tprintf("%s %d", MONTHS[month - 1], day)
}

// Case-insensitive substring match, for the data table's filter.
@(private)
contains_fold :: proc(haystack, needle: string) -> bool {
	if needle == "" {
		return true
	}
	if len(needle) > len(haystack) {
		return false
	}
	for i in 0 ..= len(haystack) - len(needle) {
		ok := true
		for j in 0 ..< len(needle) {
			a := haystack[i + j]
			b := needle[j]
			if a >= 'A' && a <= 'Z' {
				a += 'a' - 'A'
			}
			if b >= 'A' && b <= 'Z' {
				b += 'a' - 'A'
			}
			if a != b {
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

// ---- State ----

State :: struct {
	page: Page,

	// Overlays.
	popover_open: bool,
	ctx_open:     bool,
	ctx_at:       ui.Rect,
	menubar_open: int,
	nav_open:     int,
	menu_action:  string,
	select_value: string,
	combo_value:  string,
	dialog_open:  bool,
	alert_open:   bool,
	alert_danger: bool,
	alert_result: string,
	sheet_open:   bool,
	sheet_side:   ui.Sheet_Side,
	drawer_open:  bool,
	hover_action: string,

	// Structure.
	acc_open:  [3]bool,
	coll_open: bool,
	crumb:     int,
	page_no:   int,
	carousel:  int,
	side_sel:  int,

	// Forms.
	field_email:   string,
	field_account: string,
	field_bio:     string,
	otp:         string,
	cal_month:   ui.Date,
	cal_date:    ui.Date,
	date_value:  ui.Date,

	// Table and command.
	filter:       string,
	rows:         [dynamic]int,
	data_version: u64,
	cmd_open:     bool,
	cmd_picked:   string,

	// Feedback.
	toasts:    [dynamic]ui.Toast,
	toast_gen: u64,

	// Charts.
	chart_version: u64,
}

Msg :: union {
	Page_To,
	Reached_End,
	Popover_Set,
	Context_Open,
	Context_Close,
	Menubar_Set,
	Nav_Set,
	Menu_Action,
	Select_Set,
	Combo_Set,
	Dialog_Set,
	Alert_Set,
	Alert_Result,
	Sheet_Set,
	Sheet_Side_Set,
	Drawer_Set,
	Hover_Action,
	Accordion_Toggle,
	Collapsible_Set,
	Crumb_Set,
	Page_Set,
	Carousel_Set,
	Sidebar_Set,
	Field_Set,
	Account_Set,
	Bio_Set,
	Otp_Set,
	Calendar_Set,
	Date_Set,
	Filter_Set,
	Cmd_Set,
	Cmd_Picked,
	Toast_Add,
	Toast_Expire,
	Chart_Bump,
}

Page_To :: struct{ p: Page }
Reached_End :: struct{}
Popover_Set :: struct{ v: bool }
Context_Open :: struct{ at: ui.Rect }
Context_Close :: struct{}
Menubar_Set :: struct{ i: int }
Nav_Set :: struct{ i: int }
Menu_Action :: struct{ s: string }
Select_Set :: struct{ v: string }
Combo_Set :: struct{ v: string }
Dialog_Set :: struct{ v: bool }
Alert_Set :: struct {
	v:      bool,
	danger: bool,
}
Alert_Result :: struct{ s: string }
Sheet_Set :: struct{ v: bool }
Sheet_Side_Set :: struct{ s: ui.Sheet_Side }
Drawer_Set :: struct{ v: bool }
Hover_Action :: struct{ s: string }
Accordion_Toggle :: struct{ i: int }
Collapsible_Set :: struct{ v: bool }
Crumb_Set :: struct{ i: int }
Page_Set :: struct{ i: int }
Carousel_Set :: struct{ i: int }
Sidebar_Set :: struct{ i: int }
Field_Set :: struct{ v: string }
Account_Set :: struct{ v: string }
Bio_Set :: struct{ v: string }
Otp_Set :: struct{ v: string }
Calendar_Set :: struct {
	month, date: ui.Date,
}
Date_Set :: struct{ v: ui.Date }
Filter_Set :: struct{ v: string }
Cmd_Set :: struct{ v: bool }
Cmd_Picked :: struct{ v: string }
Toast_Add :: struct {
	title, description: string,
	variant:            ui.Toast_Variant,
}
Toast_Expire :: struct {
	id, generation: u64,
	force:          bool, // the user dismissed it: no generation check
}
Chart_Bump :: struct{}

@(private)
set_str :: proc(dst: ^string, v: string) {
	if dst^ == v {
		return
	}
	delete(dst^)
	dst^ = strings.clone(v)
}

// Rebuilds the data table's filtered row index: `rows` maps a display row to the record.
@(private)
rebuild_rows :: proc(s: ^State) {
	clear(&s.rows)
	reserve(&s.rows, DT_COUNT)
	for i in 0 ..< DT_COUNT {
		if s.filter == "" || contains_fold(record_name(i), s.filter) {
			append(&s.rows, i)
		}
	}
	s.data_version += 1
}

// ---- update ----

update :: proc(s: ^State, msg: Msg, fx: ^ui.Effects(Msg)) {
	switch m in msg {
	case Page_To:
		s.page = m.p
	case Reached_End:
	case Popover_Set:
		s.popover_open = m.v
	case Context_Open:
		s.ctx_open = true
		s.ctx_at = m.at
	case Context_Close:
		s.ctx_open = false
	case Menubar_Set:
		s.menubar_open = m.i
	case Nav_Set:
		s.nav_open = m.i
	case Menu_Action:
		set_str(&s.menu_action, m.s)
		s.menubar_open = -1
		s.nav_open = -1
		s.ctx_open = false
		set_str(&s.hover_action, m.s)
	case Select_Set:
		set_str(&s.select_value, m.v)
	case Combo_Set:
		set_str(&s.combo_value, m.v)
	case Dialog_Set:
		s.dialog_open = m.v
	case Alert_Set:
		s.alert_open = m.v
		if m.v {
			s.alert_danger = m.danger
		}
	case Alert_Result:
		set_str(&s.alert_result, m.s)
	case Sheet_Set:
		s.sheet_open = m.v
	case Sheet_Side_Set:
		s.sheet_side = m.s
		s.sheet_open = true
	case Drawer_Set:
		s.drawer_open = m.v
	case Hover_Action:
		set_str(&s.hover_action, m.s)
	case Accordion_Toggle:
		if m.i >= 0 && m.i < len(s.acc_open) {
			s.acc_open[m.i] = !s.acc_open[m.i]
		}
	case Collapsible_Set:
		s.coll_open = m.v
	case Crumb_Set:
		s.crumb = m.i
	case Page_Set:
		s.page_no = m.i
	case Carousel_Set:
		s.carousel = m.i
	case Sidebar_Set:
		s.side_sel = m.i
	case Field_Set:
		set_str(&s.field_email, m.v)
	case Account_Set:
		set_str(&s.field_account, m.v)
	case Bio_Set:
		set_str(&s.field_bio, m.v)
	case Otp_Set:
		set_str(&s.otp, m.v)
	case Calendar_Set:
		s.cal_month = m.month
		s.cal_date = m.date
	case Date_Set:
		s.date_value = m.v
	case Filter_Set:
		set_str(&s.filter, m.v)
		rebuild_rows(s)
	case Cmd_Set:
		s.cmd_open = m.v
	case Cmd_Picked:
		set_str(&s.cmd_picked, m.v)
		s.cmd_open = false
	case Toast_Add:
		s.toast_gen += 1
		t := ui.Toast {
			id          = s.toast_gen,
			title       = strings.clone(m.title),
			description = strings.clone(m.description),
			variant     = m.variant,
			generation  = s.toast_gen,
		}
		append(&s.toasts, t)
		// The timer carries the generation: a toast removed and replaced meanwhile (with another
		// id and another generation) is not touched by this one.
		ui.after(fx, 5 * time.Second, Toast_Expire{id = t.id, generation = t.generation})
	case Toast_Expire:
		for t, i in s.toasts {
			if t.id != m.id {
				continue
			}
			if !m.force && t.generation != m.generation {
				continue
			}
			delete(t.title)
			delete(t.description)
			ordered_remove(&s.toasts, i)
			break
		}
	case Chart_Bump:
		s.chart_version += 1
	}
}

// ---- State lifecycle ----

init_state :: proc() -> State {
	s := State {
		page         = .Popover,
		menubar_open = -1,
		nav_open     = -1,
		menu_action  = strings.clone("Nothing chosen yet"),
		hover_action = strings.clone("Nothing chosen yet"),
		select_value = strings.clone("apple"),
		combo_value  = strings.clone(""),
		alert_result = strings.clone(""),
		field_email  = strings.clone(""),
		field_account = strings.clone(""),
		field_bio    = strings.clone(""),
		otp          = strings.clone(""),
		cal_month    = ui.Date{2026, 11, 1},
		cal_date     = ui.Date{2026, 11, 10},
		date_value   = ui.Date{2026, 11, 10},
		filter       = strings.clone(""),
		cmd_picked   = strings.clone(""),
		rows         = make([dynamic]int),
		toasts       = make([dynamic]ui.Toast),
		chart_version = 1,
	}
	rebuild_rows(&s)
	return s
}

state_destroy :: proc(s: ^State) {
	delete(s.menu_action)
	delete(s.hover_action)
	delete(s.select_value)
	delete(s.combo_value)
	delete(s.alert_result)
	delete(s.field_email)
	delete(s.field_account)
	delete(s.field_bio)
	delete(s.otp)
	delete(s.filter)
	delete(s.cmd_picked)
	for t in s.toasts {
		delete(t.title)
		delete(t.description)
	}
	delete(s.toasts)
	delete(s.rows)
}

// ---- view ----

view :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.row({width = ui.grow(), height = ui.grow(), gap = 0}) {
		if ui.sidebar({height = ui.grow()}) {
			if ui.scroll({width = ui.grow(), height = ui.grow(), gap = 2}) {
				for g in GROUPS {
					ui.sidebar_group(g.name)
					for p in g.pages {
						if it := ui.sidebar_item(page_label(p), active = s.page == p); it.clicked {
							ui.dispatch(d, Page_To{p})
						}
					}
				}
			}
		}
		if ui.scroll_events(d, Reached_End{}, {id = "page", width = ui.grow(), height = ui.grow()}) {
			if ui.column({padding = 36, gap = 28, width = ui.grow(), align_x = .Center}) {
				if ui.column({width = ui.grow(max = 900), gap = 6}) {
					ui.text(page_label(s.page), .Page_Title)
					ui.text(page_lede(s.page), .Lede, .Muted)
				}
				if ui.column({width = ui.grow(max = 900), gap = 20, align_x = .Stretch}) {
					page_view(s, d)
				}
			}
		}
	}
	// Toasts are app state, and they float over every page.
	if r := ui.toast_list(s.toasts[:]); r.dismissed >= 0 {
		ui.dispatch(d, Toast_Expire{id = r.dismissed_id, force = true})
	}
}

@(private)
page_view :: proc(s: State, d: ui.Dispatch(Msg)) {
	switch s.page {
	case .Popover:
		page_popover(s, d)
	case .Hover_Card:
		page_hover_card(s, d)
	case .Context_Menu:
		page_context_menu(s, d)
	case .Menubar:
		page_menubar(s, d)
	case .Navigation_Menu:
		page_navigation_menu(s, d)
	case .Select:
		page_select(s, d)
	case .Combobox:
		page_combobox(s, d)
	case .Dialog:
		page_dialog(s, d)
	case .Alert_Dialog:
		page_alert_dialog(s, d)
	case .Sheet:
		page_sheet(s, d)
	case .Drawer:
		page_drawer(s, d)
	case .Accordion:
		page_accordion(s, d)
	case .Collapsible:
		page_collapsible(s, d)
	case .Breadcrumb:
		page_breadcrumb(s, d)
	case .Pagination:
		page_pagination(s, d)
	case .Sidebar:
		page_sidebar(s, d)
	case .Carousel:
		page_carousel(s, d)
	case .Field:
		page_field(s, d)
	case .Input_OTP:
		page_input_otp(s, d)
	case .Calendar:
		page_calendar(s, d)
	case .Date_Picker:
		page_date_picker(s, d)
	case .Table:
		page_table(s, d)
	case .Data_Table:
		page_data_table(s, d)
	case .Command:
		page_command(s, d)
	case .Toast:
		page_toast(s, d)
	case .Avatar:
		page_avatar(s, d)
	case .Chart_Bar:
		page_chart_bar(s, d)
	case .Chart_Line:
		page_chart_line(s, d)
	case .Chart_Area:
		page_chart_area(s, d)
	case .Chart_Pie:
		page_chart_pie(s, d)
	case .Chart_Radar:
		page_chart_radar(s, d)
	}
}

// A bordered panel, for one state of a component. The options are returned for the caller's
// `ui.column`: the container must be opened in the same scope as its content, so this cannot be a
// procedure that opens and closes it (a deferred close would run before the caller's body).
@(private)
panel :: proc(o: ui.Container_Options = {}) -> ui.Container_Options {
	opts := o
	if opts.padding == {} {
		opts.padding = {16, 16, 16, 16}
	}
	if opts.border == .None {
		opts.border = .Default
	}
	if opts.gap == 0 {
		opts.gap = 12
	}
	opts.align_x = .Stretch
	return opts
}

// A caption for a demo panel.
@(private)
note :: proc(s: string) {
	ui.text(s, .Metadata, .Muted)
}

main :: proc() {
	window := ui.open_window({title = "shadcn/ui", size = {1280, 900}})
	store: ui.Store(State, Msg)
	state := init_state()
	ui.store_init(&store, &window, state, update, destroy = state_destroy)
	for ui.next_frame(&window) {
		view(store.state, ui.dispatcher(&store))
	}
	ui.store_destroy(&store)
	ui.close_window(&window)
}
