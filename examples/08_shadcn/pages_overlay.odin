// Popup and overlay pages: Popover, Hover Card, Context Menu, Menubar, Navigation Menu, Select,
// Combobox, Dialog, Alert Dialog, Sheet and Drawer.
package shadcn

import "core:fmt"

import ui "myod:ui"

// ---- Shared option lists ----

@(private)
FRUITS := []ui.Select_Option {
	{value = "apple", label = "Apple"},
	{value = "banana", label = "Banana"},
	{value = "cherry", label = "Cherry"},
	{value = "durian", label = "Durian (unavailable)", disabled = true},
	{value = "elderberry", label = "Elderberry"},
}

@(private)
LANGUAGES := []ui.Select_Option {
	{value = "odin", label = "Odin"},
	{value = "rust", label = "Rust"},
	{value = "zig", label = "Zig"},
	{value = "c", label = "C"},
	{value = "swift", label = "Swift"},
	{value = "lisp", label = "Common Lisp"},
	{value = "haskell", label = "Haskell"},
	{value = "smalltalk", label = "Smalltalk"},
}

@(private)
MENU_LABELS := []string{"File", "Edit", "View"}

@(private)
NAV_LABELS := []string{"Products", "Docs", "Pricing"}

@(private)
ALIGNS := []f32{0, 0.5, 1}

@(private)
PEOPLE := []string{"Ada Lovelace", "Grace Hopper", "Alan Turing"}

@(private)
Sheet_Demo :: struct {
	side:  ui.Sheet_Side,
	label: string,
}

@(private)
SHEET_SIDES := []Sheet_Demo {
	{ui.Sheet_Side.Right, "Right"},
	{.Left, "Left"},
	{.Top, "Top"},
	{.Bottom, "Bottom"},
}

// ---- Popover ----

@(private)
page_popover :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "popover-basic"})) {
		ui.text("Basic", .Subsection)
		note("A popover opens below its trigger, keeps itself inside the window, and closes on Esc or a click outside.")
		if ui.row({gap = 8, align_y = .Center}) {
			b := ui.button("Open popover")
			if b.clicked {
				ui.dispatch(d, Popover_Set{!s.popover_open})
			}
			ui.text(s.popover_open ? "Open" : "Closed", .Metadata, .Faint)
			if ui.popover(d, Popover_Set{false}, s.popover_open, b, "popover-basic-layer", min_width = 280) {
				ui.text("Dimensions", .Label)
				ui.text("Set the dimensions for the layer.", .Compact, .Muted)
				if r, v := ui.text_input("Width", "100%", key = "popover-width"); r.changed {
					_ = v
				}
				if ui.row({gap = 8, width = ui.grow(), align_x = .End}) {
					if b2 := ui.button("Close", variant = .Outline, size = .Small); b2.clicked {
						ui.dispatch(d, Popover_Set{false})
					}
				}
			}
		}
	}
	if ui.column(panel({id = "popover-alignment"})) {
		ui.text("Alignment", .Subsection)
		note("`align` places the panel at the trigger's left edge (0), center (0.5) or right edge (1).")
		if ui.row({gap = 8}) {
			for align in ALIGNS {
				if b := ui.button(fmt.tprintf("Align %.1f", align), size = .Small); b.clicked {
					ui.dispatch(d, Popover_Set{true})
				}
			}
		}
	}
	if ui.column(panel({id = "popover-keyboard"})) {
		ui.text("Keyboard", .Subsection)
		note("Tab moves inside the panel, Esc closes it, and focus returns to the trigger.")
		if ui.row({gap = 8}) {
			if b := ui.button("Open with the keyboard"); b.clicked {
				ui.dispatch(d, Popover_Set{true})
			}
		}
	}
}

// ---- Hover Card ----

@(private)
page_hover_card :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "hover-basic"})) {
		ui.text("Basic", .Subsection)
		note("Hover — or focus — a trigger for a moment and the card appears below it. It takes no input.")
		if ui.row({gap = 16, align_y = .Center}) {
			for name, i in PEOPLE {
				b := ui.button(name)
				ui.hover_card(
					b,
					name,
					"Mathematician and computing pioneer. The card appears after 300 ms of hover or focus.",
					fmt.tprintf("hover-card/%d", i),
				)
			}
		}
	}
	if ui.column(panel({id = "hover-focus"})) {
		ui.text("From the keyboard", .Subsection)
		note(fmt.tprintf("Last chosen action: %s", s.hover_action))
		if ui.row({gap = 8}) {
			if b := ui.button("Focus me", variant = .Ghost); b.clicked {
				ui.dispatch(d, Hover_Action{"Chose the keyboard trigger"})
			}
		}
	}
}

// ---- Context Menu ----

@(private)
page_context_menu :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "context-basic"})) {
		ui.text("Basic", .Subsection)
		note("Right-click the target. The menu anchors at its widget and closes on Esc or a click outside.")
		if ui.row({gap = 8}) {
			b := ui.button("Right-click here", variant = .Outline)
			if b.secondary_clicked {
				ui.dispatch(d, Context_Open{at = b.rect})
			}
		}
		if ui.context_menu(d, Context_Close{}, s.ctx_open, s.ctx_at) {
			if it := ui.menu_item("Back", shortcut = "⌘["); it.clicked {
				ui.dispatch(d, Menu_Action{"Back"})
			}
			if it := ui.menu_item("Forward", shortcut = "⌘]"); it.clicked {
				ui.dispatch(d, Menu_Action{"Forward"})
			}
			if it := ui.menu_item("Reload", shortcut = "⌘R"); it.clicked {
				ui.dispatch(d, Menu_Action{"Reload"})
			}
			if it := ui.menu_item("Copy link", submenu = true); it.clicked {
				ui.dispatch(d, Menu_Action{"Copy link"})
			}
			if it := ui.menu_item("Paste", shortcut = "⌘V", disabled = true); it.clicked {
				ui.dispatch(d, Menu_Action{"Paste"})
			}
			if it := ui.menu_item("Delete", danger = true); it.clicked {
				ui.dispatch(d, Menu_Action{"Delete"})
			}
		}
		ui.text(fmt.tprintf("Last action: %s", s.menu_action), .Metadata, .Muted)
	}
	if ui.column(panel({id = "context-notes"})) {
		ui.text("States", .Subsection)
		note("Disabled items are skipped by the keyboard and announced as disabled; a danger item uses the error color.")
	}
}

// ---- Menubar ----

@(private)
page_menubar :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "menubar-basic"})) {
		ui.text("File, Edit, View", .Subsection)
		note("Click a trigger, or use Left/Right while a menu is open. Hovering another trigger switches to it.")
		open, rects := ui.menubar(s.menubar_open, MENU_LABELS, "menubar-demo")
		if open != s.menubar_open {
			ui.dispatch(d, Menubar_Set{open})
		}
		if s.menubar_open >= 0 && s.menubar_open < len(rects) {
			anchor := ui.Response{rect = rects[s.menubar_open]}
			if ui.menu(d, Menubar_Set{-1}, true, anchor, "menubar-demo-menu") {
				switch s.menubar_open {
				case 0:
					if it := ui.menu_item("New window", shortcut = "⌘N"); it.clicked {
						ui.dispatch(d, Menu_Action{"New window"})
					}
					if it := ui.menu_item("Open…", shortcut = "⌘O"); it.clicked {
						ui.dispatch(d, Menu_Action{"Open…"})
					}
					if it := ui.menu_item("Close", shortcut = "⌘W"); it.clicked {
						ui.dispatch(d, Menu_Action{"Close"})
					}
				case 1:
					if it := ui.menu_item("Undo", shortcut = "⌘Z"); it.clicked {
						ui.dispatch(d, Menu_Action{"Undo"})
					}
					if it := ui.menu_item("Redo", shortcut = "⇧⌘Z", disabled = true); it.clicked {
						ui.dispatch(d, Menu_Action{"Redo"})
					}
					if it := ui.menu_item("Cut", shortcut = "⌘X"); it.clicked {
						ui.dispatch(d, Menu_Action{"Cut"})
					}
				case 2:
					if it := ui.menu_item("Zoom in", shortcut = "⌘+"); it.clicked {
						ui.dispatch(d, Menu_Action{"Zoom in"})
					}
					if it := ui.menu_item("Zoom out", shortcut = "⌘-"); it.clicked {
						ui.dispatch(d, Menu_Action{"Zoom out"})
					}
					if it := ui.menu_item("Reset zoom", shortcut = "⌘0"); it.clicked {
						ui.dispatch(d, Menu_Action{"Reset zoom"})
					}
				}
			}
		}
		ui.text(fmt.tprintf("Last action: %s", s.menu_action), .Metadata, .Muted)
	}
}

// ---- Navigation Menu ----

@(private)
page_navigation_menu :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "nav-basic"})) {
		ui.text("Basic", .Subsection)
		note("Navigation items open a panel; the bar is announced as navigation, its items as links.")
		open, rects := ui.navigation_menu(s.nav_open, NAV_LABELS, "nav-demo")
		if open != s.nav_open {
			ui.dispatch(d, Nav_Set{open})
		}
		if s.nav_open >= 0 && s.nav_open < len(rects) {
			anchor := ui.Response{rect = rects[s.nav_open]}
			if ui.popover(d, Nav_Set{-1}, true, anchor, "nav-demo-panel", min_width = 240) {
				ui.text(NAV_LABELS[s.nav_open], .Label)
				switch s.nav_open {
				case 0:
					if it := ui.menu_item("Overview"); it.clicked {
						ui.dispatch(d, Menu_Action{"Products → Overview"})
					}
					if it := ui.menu_item("Changelog"); it.clicked {
						ui.dispatch(d, Menu_Action{"Products → Changelog"})
					}
				case 1:
					if it := ui.menu_item("Getting started"); it.clicked {
						ui.dispatch(d, Menu_Action{"Docs → Getting started"})
					}
					if it := ui.menu_item("API reference"); it.clicked {
						ui.dispatch(d, Menu_Action{"Docs → API reference"})
					}
				case 2:
					if it := ui.menu_item("Free"); it.clicked {
						ui.dispatch(d, Menu_Action{"Pricing → Free"})
					}
					if it := ui.menu_item("Team"); it.clicked {
						ui.dispatch(d, Menu_Action{"Pricing → Team"})
					}
				}
			}
		}
		ui.text(fmt.tprintf("Last action: %s", s.menu_action), .Metadata, .Muted)
	}
	if ui.column(panel({id = "nav-notes"})) {
		ui.text("States", .Subsection)
		note("A closed bar keeps its triggers focusable; Enter opens the focused item's panel.")
	}
}

// ---- Select ----

@(private)
page_select :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "select-basic"})) {
		ui.text("Basic", .Subsection)
		if _, v := ui.select(s.select_value, FRUITS, "select-basic", ui.fixed(200)); v != s.select_value {
			ui.dispatch(d, Select_Set{v})
		}
		ui.text(fmt.tprintf("Value: %s", s.select_value), .Metadata, .Muted)
	}
	if ui.column(panel({id = "select-states"})) {
		ui.text("States", .Subsection)
		if ui.row({gap = 16, align_y = .Center, wrap = true}) {
			// A value that is not in the list reads as the placeholder.
			if _, v := ui.select("", FRUITS, "select-empty", ui.fixed(160)); v != "" {
				ui.dispatch(d, Select_Set{v})
			}
			if _, v := ui.select("banana", FRUITS, "select-disabled-select", ui.fixed(200), disabled = true); v != "banana" {
				ui.dispatch(d, Select_Set{v})
			}
		}
		note("Left: no value (placeholder). Right: the whole trigger disabled.")
	}
	if ui.column(panel({id = "select-keyboard"})) {
		ui.text("Keyboard", .Subsection)
		note("Enter or Space opens; Up/Down move the highlight; Enter picks; Esc closes and returns focus to the trigger.")
	}
}

// ---- Combobox ----

@(private)
page_combobox :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "combobox-basic"})) {
		ui.text("Basic", .Subsection)
		if _, v := ui.combobox(s.combo_value, LANGUAGES, "combobox-basic", ui.fixed(240)); v != s.combo_value {
			ui.dispatch(d, Combo_Set{v})
		}
		ui.text(
			s.combo_value == "" ? "Nothing chosen yet" : fmt.tprintf("Chosen: %s", s.combo_value),
			.Metadata,
			.Muted,
		)
	}
	if ui.column(panel({id = "combobox-disabled"})) {
		ui.text("Disabled", .Subsection)
		if _, v := ui.combobox("odin", LANGUAGES, "combobox-disabled", ui.fixed(240), disabled = true); v != "odin" {
			ui.dispatch(d, Combo_Set{v})
		}
	}
	if ui.column(panel({id = "combobox-keyboard"})) {
		ui.text("Keyboard", .Subsection)
		note("Type to filter; Up/Down move; Enter picks the highlight. The query is cleared when the popup closes.")
	}
}

// ---- Dialog ----

// The dialog's open flag is shared by both triggers, and only one `ui.dialog` is declared, so the
// page can never put two dialogs on screen.
@(private)
page_dialog :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "dialog-basic"})) {
		ui.text("Basic", .Subsection)
		note("A modal dialog blocks the page below, traps Tab, and takes Esc or a click outside as close.")
		if ui.row({gap = 8}) {
			if b := ui.button("Edit profile"); b.clicked {
				ui.dispatch(d, Dialog_Set{true})
			}
			if b := ui.button("Open with the keyboard", variant = .Outline); b.clicked {
				ui.dispatch(d, Dialog_Set{true})
			}
		}
		if ui.dialog(d, Dialog_Set{false}, s.dialog_open, "Edit profile", 440) {
			ui.text("Make changes to your profile here. Click save when you are done.", .Compact, .Muted)
			if r, v := ui.text_input("Name", "Ada Lovelace", key = "dialog-name"); r.changed {
				_ = v
			}
			if r, v := ui.text_input("Email", "ada@example.com", key = "dialog-email"); r.changed {
				_ = v
			}
			if ui.row({gap = 8, width = ui.grow(), align_x = .End}) {
				if b := ui.button("Cancel", variant = .Outline); b.clicked {
					ui.dispatch(d, Dialog_Set{false})
				}
				if b := ui.button("Save changes", variant = .Primary); b.clicked {
					ui.dispatch(d, Dialog_Set{false})
				}
			}
		}
	}
	if ui.column(panel({id = "dialog-notes"})) {
		ui.text("Keyboard", .Subsection)
		note("Focus enters the dialog on open and returns to the trigger on close. Tab cycles inside it only.")
	}
}

// ---- Alert Dialog ----

// As with the dialog, one `alert_dialog` and two triggers.
@(private)
page_alert_dialog :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "alert-basic"})) {
		ui.text("Basic", .Subsection)
		note("A confirmation. Cancel takes focus first; Esc and a click outside cancel.")
		if ui.row({gap = 8}) {
			if b := ui.button("Show confirmation"); b.clicked {
				ui.dispatch(d, Alert_Set{v = true, danger = false})
			}
			if b := ui.button("Delete project", variant = .Danger); b.clicked {
				ui.dispatch(d, Alert_Set{v = true, danger = true})
			}
		}
		danger := s.alert_danger
		title := danger ? "Delete the project?" : "Are you absolutely sure?"
		description := danger ? "The project and every deployment will be removed." : "This action cannot be undone. It will permanently delete the record."
		confirm := danger ? "Delete" : "Continue"
		cancel := danger ? "Keep" : "Cancel"
		if confirmed, cancelled := ui.alert_dialog(
			d,
			Alert_Set{v = false},
			s.alert_open,
			title,
			description,
			confirm,
			cancel,
			danger,
		); confirmed || cancelled {
			ui.dispatch(d, Alert_Result{confirmed ? "Confirmed" : "Cancelled"})
		}
	}
	if s.alert_result != "" {
		ui.text(fmt.tprintf("Last result: %s", s.alert_result), .Metadata, .Muted)
	}
}

// ---- Sheet ----

@(private)
page_sheet :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "sheet-sides"})) {
		ui.text("Every edge", .Subsection)
		note("A modal panel attached to an edge of the window. It appears instantly.")
		if ui.row({gap = 8, wrap = true}) {
			for side in SHEET_SIDES {
				if b := ui.button(side.label); b.clicked {
					ui.dispatch(d, Sheet_Side_Set{side.side})
				}
			}
		}
		if ui.sheet(d, Sheet_Set{false}, s.sheet_open, s.sheet_side, "Edit profile", 380, "sheet-demo") {
			ui.text("A sheet's contents are declared inside the `if`.", .Compact, .Muted)
			if r, v := ui.text_input("Name", "Ada Lovelace", key = "sheet-name"); r.changed {
				_ = v
			}
			if r, v := ui.text_area("Notes", "A sheet works from any edge of the window.", 3, key = "sheet-notes"); r.changed {
				_ = v
			}
			if ui.row({gap = 8, width = ui.grow(), align_x = .End}) {
				if b := ui.button("Close"); b.clicked {
					ui.dispatch(d, Sheet_Set{false})
				}
			}
		}
	}
	if ui.column(panel({id = "sheet-keyboard"})) {
		ui.text("Keyboard", .Subsection)
		note("Esc and a click outside close; focus is trapped while open and returns to the trigger.")
	}
}

// ---- Drawer ----

@(private)
page_drawer :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "drawer-basic"})) {
		ui.text("Basic", .Subsection)
		note("A drawer comes up from the bottom edge with a grab handle, and is modal like a sheet.")
		if ui.row({gap = 8}) {
			if b := ui.button("Open drawer"); b.clicked {
				ui.dispatch(d, Drawer_Set{true})
			}
		}
		if ui.drawer(d, Drawer_Set{false}, s.drawer_open, "Edit profile", 300, "drawer-demo") {
			ui.text("Press Esc or click outside to dismiss.", .Compact, .Muted)
			if r, v := ui.text_input("Name", "Ada Lovelace", key = "drawer-name"); r.changed {
				_ = v
			}
			if ui.row({gap = 8, width = ui.grow(), align_x = .End}) {
				if b := ui.button("Cancel", variant = .Outline); b.clicked {
					ui.dispatch(d, Drawer_Set{false})
				}
				if b := ui.button("Save", variant = .Primary); b.clicked {
					ui.dispatch(d, Drawer_Set{false})
				}
			}
		}
	}
}
