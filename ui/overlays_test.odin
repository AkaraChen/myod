// Tests of the popup widgets' keyboard operation (ARCHITECTURE.md, "Testing"): Select and Combobox
// must be usable without a pointer, which is what a screen-reader user does.
package ui

import "core:testing"

import "../platform"

Select_Demo :: struct {
	value: string,
}

Select_Set :: struct {
	value: string,
}

select_demo_update :: proc(s: ^Select_Demo, msg: Select_Set, fx: ^Effects(Select_Set)) {
	s.value = msg.value
}

select_demo_view :: proc(s: Select_Demo, d: Dispatch(Select_Set)) {
	if row({width = grow(), height = grow(), padding = 20}) {
		if _, v := select(s.value, DEMO_OPTIONS, "select-test", fixed(200)); v != s.value {
			dispatch(d, Select_Set{v})
		}
		if column({width = grow(), height = grow()}) {
			text("content")
		}
	}
}

DEMO_OPTIONS := []Select_Option {
	{value = "apple", label = "Apple"},
	{value = "banana", label = "Banana"},
	{value = "cherry", label = "Cherry"},
	{value = "durian", label = "Durian", disabled = true},
	{value = "elderberry", label = "Elderberry"},
}

@(test)
select_keyboard :: proc(t: ^testing.T) {
	h := test_harness(Select_Demo{value = "apple"}, select_demo_update, select_demo_view)
	defer test_destroy(h)

	// A click opens the listbox; Down and Enter pick the next option.
	testing.expect(t, test_click(h, .Button, "Apple"))
	testing.expect(t, test_find(h, .List_Box, "Apple") != nil, "the listbox is open")
	test_key(h, .Down)
	test_key(h, .Enter)
	testing.expect_value(t, h.store.state.value, "banana")
	testing.expect(t, test_find(h, .List_Box, "Banana") == nil, "picking closes the listbox")
}

@(test)
select_keyboard_skips_disabled :: proc(t: ^testing.T) {
	h := test_harness(Select_Demo{value = "banana"}, select_demo_update, select_demo_view)
	defer test_destroy(h)

	// Banana is the highlight; Down moves to Cherry, Down again skips the disabled Durian.
	testing.expect(t, test_click(h, .Button, "Banana"))
	test_key(h, .Down)
	test_key(h, .Down)
	test_key(h, .Enter)
	testing.expect_value(t, h.store.state.value, "elderberry")
}

@(test)
select_escape_keeps_value :: proc(t: ^testing.T) {
	h := test_harness(Select_Demo{value = "apple"}, select_demo_update, select_demo_view)
	defer test_destroy(h)

	testing.expect(t, test_click(h, .Button, "Apple"))
	testing.expect(t, test_find(h, .List_Box, "Apple") != nil, "the listbox is open")
	test_key(h, .Escape)
	testing.expect(t, test_find(h, .List_Box, "Apple") == nil, "Esc closes the listbox")
	testing.expect_value(t, h.store.state.value, "apple")
}

// ---- Menubar ----

Menubar_Demo :: struct {
	open:   int,
	picked: string,
}

Menubar_Set :: struct {
	open:   int,
	picked: string,
}

menubar_demo_update :: proc(s: ^Menubar_Demo, msg: Menubar_Set, fx: ^Effects(Menubar_Set)) {
	if msg.picked != "" {
		s.picked = msg.picked
		s.open = -1
		return
	}
	s.open = msg.open
}

MENUBAR_LABELS := []string{"File", "Edit", "View"}

menubar_demo_view :: proc(s: Menubar_Demo, d: Dispatch(Menubar_Set)) {
	if column({width = grow(), height = grow(), padding = 20, align_x = .Stretch}) {
		open, rects := menubar(s.open, MENUBAR_LABELS, "menubar-test")
		if open != s.open {
			dispatch(d, Menubar_Set{open = open})
		}
		if s.open >= 0 && s.open < len(rects) {
			anchor := Response{rect = rects[s.open]}
			if menu(d, Menubar_Set{open = -1}, true, anchor, "menubar-test-menu") {
				switch s.open {
				case 0:
					if it := menu_item("New window"); it.clicked {
						dispatch(d, Menubar_Set{open = -1, picked = "New window"})
					}
				case 1:
					if it := menu_item("Undo"); it.clicked {
						dispatch(d, Menubar_Set{open = -1, picked = "Undo"})
					}
				case 2:
					if it := menu_item("Zoom in"); it.clicked {
						dispatch(d, Menubar_Set{open = -1, picked = "Zoom in"})
					}
				}
			}
		}
	}
}

@(test)
menubar_left_right_switches_menus :: proc(t: ^testing.T) {
	h := test_harness(Menubar_Demo{open = -1}, menubar_demo_update, menubar_demo_view)
	defer test_destroy(h)

	// Click File: its menu opens and takes the focus.
	testing.expect(t, test_click(h, .Button, "File"))
	testing.expect_value(t, h.store.state.open, 0)
	testing.expect(t, test_find(h, .Button, "New window") != nil, "the File menu is open")

	// Right moves to the Edit trigger and its menu replaces the File one.
	test_key(h, .Right)
	testing.expect_value(t, h.store.state.open, 1)
	testing.expect(t, test_find(h, .Button, "Undo") != nil, "the Edit menu replaced it")
	testing.expect(t, test_find(h, .Button, "New window") == nil, "the File menu closed")

	// The new menu took the focus, so Enter runs its first item.
	test_key(h, .Enter)
	testing.expect_value(t, h.store.state.picked, "Undo")
	testing.expect_value(t, h.store.state.open, -1)
}

// ---- Combobox ----

Combobox_Demo :: struct {
	value: string,
}

combobox_demo_update :: proc(s: ^Combobox_Demo, msg: Select_Set, fx: ^Effects(Select_Set)) {
	s.value = msg.value
}

combobox_demo_view :: proc(s: Combobox_Demo, d: Dispatch(Select_Set)) {
	if row({width = grow(), height = grow(), padding = 20}) {
		if _, v := combobox(s.value, DEMO_OPTIONS, "combobox-test", fixed(240)); v != s.value {
			dispatch(d, Select_Set{v})
		}
		if column({width = grow(), height = grow()}) {
			text("content")
		}
	}
}

@(test)
combobox_keyboard :: proc(t: ^testing.T) {
	h := test_harness(Combobox_Demo{}, combobox_demo_update, combobox_demo_view)
	defer test_destroy(h)

	// The popup focuses its search field: typing filters, Enter picks the highlight.
	testing.expect(t, test_click(h, .Button, "Select…"))
	append(&h.window.events, platform.Event{kind = .Text_Input, text = "ban"})
	test_frame(h)
	test_key(h, .Enter)
	testing.expect_value(t, h.store.state.value, "banana")
}

