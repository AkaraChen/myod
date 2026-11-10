// Structure pages: Accordion, Collapsible, Breadcrumb, Pagination, Sidebar and Carousel.
package shadcn

import "core:fmt"

import ph "myod:icons/phosphor"
import ui "myod:ui"

// ---- Accordion ----

@(private)
ACCORDION_LABELS := []string{"Is it accessible?", "Is it styled?", "Is it animated?"}

@(private)
ACCORDION_BODIES := []string{
	"Yes. It uses the same roles and keyboard handling as every other component: the header is a button, Space or Enter toggles it, and the expanded state is announced.",
	"Yes. It comes with default styles, and every color comes from the theme tokens, so it follows the light and dark modes.",
	"No. The library has no animation anywhere; opening an item is a new frame and nothing else.",
}

@(private)
page_accordion :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "accordion-basic"})) {
		ui.text("Basic", .Subsection)
		for label, i in ACCORDION_LABELS {
			it := ui.accordion_item(label, s.acc_open[i], fmt.tprintf("accordion/%d", i))
			if it.res.changed {
				ui.dispatch(d, Accordion_Toggle{i})
			}
			if it.body {
				ui.text(ACCORDION_BODIES[i], .Compact, .Muted)
			}
		}
	}
	if ui.column(panel({id = "accordion-states"})) {
		ui.text("States", .Subsection)
		note("Several items may be open at once: the app owns one flag per item, and every header is focusable.")
	}
}

// ---- Collapsible ----

@(private)
page_collapsible :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "collapsible-basic"})) {
		ui.text("Basic", .Subsection)
		it := ui.collapsible("@peduarte starred 3 repositories", s.coll_open, "collapsible-demo")
		if it.res.changed {
			ui.dispatch(d, Collapsible_Set{!s.coll_open})
		}
		if it.body {
			if ui.row({gap = 8, align_y = .Center}) {
				ui.icon(ph.GITHUB_LOGO, 16, .Bold, .Muted)
				ui.text("@radix-ui/primitives", .Compact)
			}
			if ui.row({gap = 8, align_y = .Center}) {
				ui.icon(ph.GITHUB_LOGO, 16, .Bold, .Muted)
				ui.text("@radix-ui/colors", .Compact)
			}
		}
	}
	if ui.column(panel({id = "collapsible-closed"})) {
		ui.text("States", .Subsection)
		note("The trigger row is focusable; the body is declared only while the item is open, and the caret marks the state.")
	}
}

// ---- Breadcrumb ----

@(private)
CRUMBS := []string{"Home", "Components", "Breadcrumb"}

@(private)
page_breadcrumb :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "breadcrumb-basic"})) {
		ui.text("Basic", .Subsection)
		if res, i := ui.breadcrumb(CRUMBS, "breadcrumb-demo"); res.changed {
			ui.dispatch(d, Crumb_Set{i})
		}
		ui.text(fmt.tprintf("Current step: %s", CRUMBS[s.crumb]), .Metadata, .Muted)
	}
	if ui.column(panel({id = "breadcrumb-states"})) {
		ui.text("States", .Subsection)
		note("Every step is focusable; Enter activates it, and the last step is the current page.")
	}
}

// ---- Pagination ----

@(private)
page_pagination :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "pagination-basic"})) {
		ui.text("Basic", .Subsection)
		if res, p := ui.pagination(s.page_no, 12, "pagination-demo"); res.changed {
			ui.dispatch(d, Page_Set{p})
		}
		ui.text(fmt.tprintf("Page %d of 12", s.page_no + 1), .Metadata, .Muted)
	}
	if ui.column(panel({id = "pagination-states"})) {
		ui.text("States", .Subsection)
		note("Previous is disabled on the first page and Next on the last; the number row collapses to ellipses when it gets long.")
	}
}

// ---- Sidebar ----

@(private)
SIDEBAR_MAIN := []string{"Inbox", "Drafts", "Sent", "Trash"}

@(private)
SIDEBAR_SETTINGS := []string{"Profile", "Billing"}

@(private)
page_sidebar :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.row({height = ui.fixed(300), border = .Default, clip = true, gap = 0, align_y = .Stretch}) {
		if ui.sidebar({height = ui.grow()}) {
			ui.sidebar_group("Application")
			for label, i in SIDEBAR_MAIN {
				if it := ui.sidebar_item(label, ph.ENVELOPE_SIMPLE, s.side_sel == i, 3 if i == 0 else -1); it.clicked {
					ui.dispatch(d, Sidebar_Set{i})
				}
			}
			ui.sidebar_group("Settings")
			for label, i in SIDEBAR_SETTINGS {
				if it := ui.sidebar_item(label, ph.GEAR, s.side_sel == 4 + i); it.clicked {
					ui.dispatch(d, Sidebar_Set{4 + i})
				}
			}
		}
		if ui.column({width = ui.grow(), height = ui.grow(), padding = 20, gap = 6}) {
			ui.text("Content", .Section)
			ui.text(
				"The rail is a bordered column of groups and entries; the active entry is filled and marked selected for screen readers.",
				.Compact,
				.Muted,
			)
		}
	}
	if ui.column(panel({id = "sidebar-states"})) {
		ui.text("States", .Subsection)
		note("Entries take an icon, an optional count, hover and an active state; groups are section headings.")
	}
}

// ---- Carousel ----

@(private)
page_carousel :: proc(s: State, d: ui.Dispatch(Msg)) {
	if ui.column(panel({id = "carousel-basic"})) {
		ui.text("Basic", .Subsection)
		if ui.carousel(ui.fixed(180), "carousel-demo") {
			if ui.column({align_x = .Center, gap = 6}) {
				ui.text(fmt.tprintf("Slide %d", s.carousel + 1), .Section)
				ui.text(
					"The frame is a clipped box; the app declares the slide's content inside it.",
					.Compact,
					.Muted,
					width = ui.fixed(420),
				)
			}
		}
		if ui.row({width = ui.grow(), align_x = .Center}) {
			if _, next := ui.carousel_controls(s.carousel, 3, "carousel-demo-controls"); next != s.carousel {
				ui.dispatch(d, Carousel_Set{next})
			}
		}
	}
	if ui.column(panel({id = "carousel-states"})) {
		ui.text("States", .Subsection)
		note("The arrows are disabled at the ends; each dot is focusable and marks the current slide as selected.")
	}
}
