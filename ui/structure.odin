// Structure components of the shadcn/ui set: Accordion, Collapsible, Breadcrumb, Pagination, Sidebar
// and Carousel. Expansion and slide changes happen instantly; there is no animation anywhere in the
// library (DESIGN.md), so a change is a new frame and nothing else.
package ui

import "core:fmt"

import "../core"
import ph "../icons/phosphor"
import "../layout"

// An ID for a widget with an optional explicit key, defaulting to its label. Two widgets with the
// same label in one scope need different keys.
@(private)
named_id :: proc(ctx: ^core.Context, key, label: string) -> (id: Id, display: string) {
	if key != "" {
		return core.key_id(ctx, key), label
	}
	return core.label_id(ctx, label)
}

// ---- Accordion ----

// The header and body of one accordion item. `body` is whether the content is declared (the item is
// open); `res.changed` is whether the user toggled it.
Accordion_Item :: struct {
	res:  Response,
	body: bool,
}

@(private)
accordion_item_close :: proc(item: Accordion_Item) {
	if item.body {
		core.close(core.current())
	}
	core.close(core.current())
}

// One item of an accordion: a 36px header with the label and a caret over a bottom border, and the
// body (12px below the header, 8px between children) when `open`. The app owns `open` per item and
// toggles it on `res.changed`; contents are declared inside the `if`.
@(deferred_out = accordion_item_close)
accordion_item :: proc(label: string, open: bool, key := "") -> Accordion_Item {
	ctx := core.current()
	id, display := named_id(ctx, key, label)
	it := core.interact(ctx, id)
	ln := layout.Node {
		flex_direction = .Column,
		align_self     = .Stretch,
	}
	outer := core.open(ctx, core.auto_id(ctx), ln, nil)
	item := Accordion_Item{body = false}
	if outer {
		header := layout.Node {
			flex_direction  = .Row,
			align_items     = .Center,
			justify_content = .Space_Between,
			size            = {{0, .Auto}, {36, .Px}},
			flex_shrink     = 0,
		}
		paint: core.Paint
		if it.hovered {
			paint = core.Paint_Box{fill = .Overlay}
		}
		if core.open(ctx, id, header, paint, label = display, flags = {.Hit, .Focusable, .Activate}) {
			lbl := layout.Node{}
			core.leaf(ctx, core.auto_id(ctx), lbl, core.Paint_Text {
				s     = display,
				style = text_style(.Compact),
				color = .Fg,
				wrap  = false,
			}, measured = true)
			caret := layout.Node{size = {{12, .Px}, {12, .Px}}}
			core.leaf(ctx, core.auto_id(ctx), caret, core.Paint_Icon {
				icon = ph.CARET_UP if open else ph.CARET_DOWN,
				weight = .Bold,
				color = .Muted,
			})
			if open {
				core.set_a11y_state(ctx, id, {.Expanded})
			}
		}
		core.close(ctx)
		divider()
		if open {
			body := layout.Node {
				flex_direction = .Column,
				gap            = {8, 8},
				padding        = {12, 12, 0, 0},
				align_self     = .Stretch,
			}
			if core.open(ctx, core.auto_id(ctx), body, nil) {
				item.body = true
			}
		}
	}
	item.res = response_interactive(ctx, id, false)
	item.res.changed = it.clicked
	return item
}

// ---- Collapsible ----

Collapsible_Item :: struct {
	res:  Response,
	body: bool,
}

@(private)
collapsible_close :: proc(item: Collapsible_Item) {
	if item.body {
		core.close(core.current())
	}
	core.close(core.current())
}

// A single expandable section: a trigger row with a caret and the label, and the body 8px below it
// when `open`. Controlled like `accordion_item`.
@(deferred_out = collapsible_close)
collapsible :: proc(label: string, open: bool, key := "") -> Collapsible_Item {
	ctx := core.current()
	id, display := named_id(ctx, key, label)
	it := core.interact(ctx, id)
	ln := layout.Node {
		flex_direction = .Column,
		gap            = {8, 8},
		align_self     = .Stretch,
	}
	outer := core.open(ctx, core.auto_id(ctx), ln, nil)
	item := Collapsible_Item{body = false}
	if outer {
		trigger := layout.Node {
			flex_direction = .Row,
			align_items    = .Center,
			gap            = {6, 6},
			size           = {{0, .Auto}, {24, .Px}},
			flex_shrink    = 0,
		}
		paint: core.Paint
		if it.hovered {
			paint = core.Paint_Box{fill = .Overlay}
		}
		if core.open(ctx, id, trigger, paint, label = display, flags = {.Hit, .Focusable, .Activate}) {
			caret := layout.Node{size = {{10, .Px}, {10, .Px}}}
			core.leaf(ctx, core.auto_id(ctx), caret, core.Paint_Icon {
				icon = ph.CARET_DOWN if open else ph.CARET_RIGHT,
				weight = .Bold,
				color = .Muted,
			})
			lbl := layout.Node{}
			core.leaf(ctx, core.auto_id(ctx), lbl, core.Paint_Text {
				s     = display,
				style = text_style(.Compact),
				color = .Fg,
				wrap  = false,
			}, measured = true)
			if open {
				core.set_a11y_state(ctx, id, {.Expanded})
			}
		}
		core.close(ctx)
		if open {
			body := layout.Node {
				flex_direction = .Column,
				gap            = {8, 8},
				align_self     = .Stretch,
			}
			if core.open(ctx, core.auto_id(ctx), body, nil) {
				item.body = true
			}
		}
	}
	item.res = response_interactive(ctx, id, false)
	item.res.changed = it.clicked
	return item
}

// ---- Breadcrumb ----

// A breadcrumb trail: the items in a row separated by carets, the pages before the current one
// muted and clickable, the current one in the foreground color. Returns the index the user clicked,
// or -1.
breadcrumb :: proc(items: []string, key := "breadcrumb") -> (Response, int) {
	ctx := core.current()
	res := Response{id = core.key_id(ctx, key)}
	clicked := -1
	ln := layout.Node {
		flex_direction = .Row,
		align_items    = .Center,
		gap            = {6, 6},
		size           = {{0, .Auto}, {24, .Px}},
	}
	if core.open(ctx, res.id, ln, nil, label = key) {
		core.set_a11y_role(ctx, res.id, .Navigation)
		for item, i in items {
			last := i == len(items) - 1
			if i > 0 {
				sep := layout.Node{size = {{10, .Px}, {10, .Px}}}
				core.leaf(ctx, core.auto_id(ctx), sep, core.Paint_Icon {
					icon = ph.CARET_RIGHT,
					weight = .Bold,
					color = .Faint,
				})
			}
			id := core.key_id_int(ctx, i)
			it := core.interact(ctx, id)
			t := layout.Node {
				flex_direction = .Row,
				align_items    = .Center,
				size           = {{0, .Auto}, {24, .Px}},
			}
			paint: core.Paint
			if !last && it.hovered {
				paint = core.Paint_Box{fill = .Overlay}
			}
			flags := core.Node_Flags{.Hit, .Focusable, .Activate}
			if last {
				flags = {.Focusable} // the current page: focusable for the reader, not activatable
			}
			if core.open(ctx, id, t, paint, label = item, flags = flags) {
				color: core.Token = .Fg
				if !last {
					color = .Fg if it.hovered else .Muted
				}
				lbl := layout.Node{}
				core.leaf(ctx, core.auto_id(ctx), lbl, core.Paint_Text {
					s     = item,
					style = text_style(.Compact),
					color = color,
					wrap  = false,
				}, measured = true)
				if last {
					// The current page is focusable for the reader, but not a button; without a role
					// it would be a tab stop the semantic tree does not describe.
					core.set_a11y_role(ctx, id, .Group)
					core.set_a11y_state(ctx, id, {.Selected})
				}
			}
			core.close(ctx)
			if !last && it.clicked {
				clicked = i
			}
		}
	}
	core.close(ctx)
	res.changed = clicked >= 0
	return res, clicked
}

// ---- Pagination ----

// The pages to show: the first and last always, the current one and its neighbours, and -1 where a
// gap (an ellipsis) is.
@(private)
page_window :: proc(page, count, slots: int) -> []int {
	out := make([dynamic]int, 0, slots + 4, context.temp_allocator)
	if count <= slots + 2 {
		for i in 0 ..< count {
			append(&out, i)
		}
		return out[:]
	}
	start := clamp(page - slots / 2, 1, count - slots - 1)
	append(&out, 0)
	if start > 1 {
		append(&out, -1)
	}
	for i in start ..< start + slots {
		append(&out, i)
	}
	if start + slots < count - 1 {
		append(&out, -1)
	}
	append(&out, count - 1)
	return out[:]
}

// Pagination: previous, the page numbers, next. Controlled: returns the page the user asked for
// (the current one when nothing was clicked). `page` and the result are zero-based.
pagination :: proc(page, count: int, key := "pagination") -> (Response, int) {
	ctx := core.current()
	res := Response{id = core.key_id(ctx, key)}
	if count <= 0 {
		return res, page
	}
	cur := clamp(page, 0, count - 1)
	next := cur
	ln := layout.Node {
		flex_direction = .Row,
		align_items    = .Center,
		gap            = {4, 4},
		size           = {{0, .Auto}, {28, .Px}},
	}
	if core.open(ctx, res.id, ln, nil) {
		core.set_a11y_role(ctx, res.id, .Navigation)
		if b := pagination_arrow(ph.CARET_LEFT, "Previous page", cur > 0); b.clicked {
			next = cur - 1
		}
		for p, i in page_window(cur, count, 1) {
			if p < 0 {
				ell := layout.Node{size = {{20, .Px}, {28, .Px}}}
				core.leaf(ctx, core.key_id_int(ctx, 1000 + i), ell, core.Paint_Text {
					s     = "…",
					style = text_style(.Compact),
					color = .Faint,
					wrap  = false,
				}, measured = true)
				continue
			}
			if b := pagination_page(p, p == cur); b.clicked {
				next = p
			}
		}
		if b := pagination_arrow(ph.CARET_RIGHT, "Next page", cur < count - 1); b.clicked {
			next = cur + 1
		}
	}
	core.close(ctx)
	res.changed = next != cur
	return res, next
}

@(private)
pagination_arrow :: proc(glyph: Icon, label: string, enabled: bool) -> Response {
	ctx := core.current()
	id, _ := core.label_id(ctx, label)
	it := core.interact(ctx, id)
	ln := layout.Node {
		flex_direction  = .Row,
		align_items     = .Center,
		justify_content = .Center,
		size            = {{28, .Px}, {28, .Px}},
	}
	flags := core.Node_Flags{.Hit, .Focusable, .Activate}
	if !enabled {
		flags += {.Disabled}
	}
	paint: core.Paint
	if enabled && it.hovered {
		paint = core.Paint_Box{fill = .Overlay}
	}
	if core.open(ctx, id, ln, paint, label = label, flags = flags) {
		gl := layout.Node{size = {{12, .Px}, {12, .Px}}}
		core.leaf(ctx, core.auto_id(ctx), gl, core.Paint_Icon {
			icon = glyph,
			weight = .Bold,
			color = .Fg if enabled else .Faint,
		})
	}
	core.close(ctx)
	return response_interactive(ctx, id, !enabled)
}

@(private)
pagination_page :: proc(page: int, active: bool) -> Response {
	ctx := core.current()
	id := core.key_id_int(ctx, page)
	it := core.interact(ctx, id)
	ln := layout.Node {
		flex_direction  = .Row,
		align_items     = .Center,
		justify_content = .Center,
		size            = {{28, .Px}, {28, .Px}},
	}
	paint: core.Paint
	if active {
		paint = core.Paint_Box{fill = .Fg}
	} else if it.hovered {
		paint = core.Paint_Box{fill = .Overlay}
	}
	if core.open(ctx, id, ln, paint, label = fmt.tprintf("Page %d", page + 1), flags = {.Hit, .Focusable, .Activate}) {
		lbl := layout.Node{}
		core.leaf(ctx, core.auto_id(ctx), lbl, core.Paint_Text {
			s     = fmt.tprintf("%d", page + 1),
			style = text_style(.Compact),
			color = .Bg if active else .Fg,
			wrap  = false,
		}, measured = true)
		if active {
			core.set_a11y_state(ctx, id, {.Selected})
		}
	}
	core.close(ctx)
	res := response_interactive(ctx, id, false)
	if active {
		res.clicked = false
	}
	return res
}

// ---- Sidebar ----

// A vertical navigation rail: a bordered column, 220px wide by default, 8px of padding and 2px
// between items.
@(deferred_out = _close)
sidebar :: proc(o: Container_Options = {}) -> bool {
	opts := o
	if opts.width.kind == .Fit && opts.width.value == 0 {
		opts.width = fixed(220)
	}
	if opts.padding[0] == 0 && opts.padding[1] == 0 && opts.padding[2] == 0 && opts.padding[3] == 0 {
		opts.padding = {8, 8, 8, 8}
	}
	if opts.gap == 0 {
		opts.gap = 2
	}
	opts.align_x = .Stretch
	if opts.border == .None {
		opts.border = .Default
	}
	return open_box(opts, .Column)
}

// A group title inside a sidebar.
sidebar_group :: proc(label: string) {
	ctx := core.current()
	ln := layout.Node {
		flex_direction = .Row,
		align_items    = .Center,
		size           = {{0, .Auto}, {28, .Px}},
		padding        = {8, 8, 0, 0},
	}
	core.leaf(ctx, core.key_id(ctx, label), ln, core.Paint_Text {
		s     = label,
		style = text_style(.Label),
		color = .Faint,
		wrap  = false,
	}, measured = true)
}

// A sidebar entry: 32px, an optional icon, the label, an optional count on the right, and the
// active entry filled. Returns the interaction.
sidebar_item :: proc(label: string, icon: Icon = {}, active := false, count := -1) -> Response {
	ctx := core.current()
	id, display := core.label_id(ctx, label)
	core.register_name(ctx, display, id)
	it := core.interact(ctx, id)
	ln := layout.Node {
		flex_direction = .Row,
		align_items    = .Center,
		// The entry fills the rail's width: the active fill and the hit box cover the whole row, not
		// just the icon and padding. The label's zero basis then grows into the rest of it.
		align_self     = .Stretch,
		gap            = {8, 8},
		size           = {{0, .Auto}, {32, .Px}},
		padding        = {8, 8, 0, 0},
		flex_shrink    = 0,
	}
	paint: core.Paint
	if active {
		paint = core.Paint_Box{fill = .Overlay_Hover}
	} else if it.hovered {
		paint = core.Paint_Box{fill = .Overlay}
	}
	if core.open(ctx, id, ln, paint, label = display, flags = {.Hit, .Focusable, .Activate}) {
		if icon.name != "" {
			glyph := layout.Node{size = {{16, .Px}, {16, .Px}}}
			core.leaf(ctx, core.auto_id(ctx), glyph, core.Paint_Icon {
				icon = icon,
				weight = .Bold,
				color = .Fg if active else .Muted,
			})
		}
		lbl := layout.Node{flex_grow = 1, flex_shrink = 1, flex_basis = {0, .Px}}
		core.leaf(ctx, core.auto_id(ctx), lbl, core.Paint_Text {
			s     = display,
			style = text_style(.Compact),
			color = .Fg if active else .Muted,
			wrap  = false,
		}, measured = true)
		if count >= 0 {
			c := layout.Node{}
			core.leaf(ctx, core.auto_id(ctx), c, core.Paint_Text {
				s     = fmt.tprintf("%d", count),
				style = text_style(.Metadata),
				color = .Faint,
				wrap  = false,
			}, measured = true)
		}
		if active {
			core.set_a11y_state(ctx, id, {.Selected})
		}
	}
	core.close(ctx)
	return response_interactive(ctx, id, false)
}

// ---- Carousel ----

// The frame of the current slide: a clipped, bordered box. Declare the slide's content inside the
// `if`, then call `carousel_controls` below it.
@(deferred_out = _close)
carousel :: proc(height: Size = {}, key := "carousel") -> bool {
	ctx := core.current()
	ln := layout.Node {
		flex_direction  = .Row,
		align_items     = .Center,
		justify_content = .Center,
		align_self      = .Stretch,
	}
	item(ctx, &ln, {}, height)
	return core.open(ctx, core.key_id(ctx, key), ln, box_paint(.None, .Default), clip = true)
}

// A carousel's controls: the previous and next arrows either side of one dot per slide, the current
// dot filled. Returns the slide the user asked for (the current one when nothing was clicked).
carousel_controls :: proc(slide, count: int, key := "carousel-controls") -> (Response, int) {
	ctx := core.current()
	res := Response{id = core.key_id(ctx, key)}
	if count <= 0 {
		return res, slide
	}
	cur := clamp(slide, 0, count - 1)
	next := cur
	ln := layout.Node {
		flex_direction  = .Row,
		align_items     = .Center,
		justify_content = .Center,
		gap             = {10, 10},
		size            = {{0, .Auto}, {24, .Px}},
		align_self      = .Stretch,
	}
	if core.open(ctx, res.id, ln, nil) {
		if b := carousel_arrow(ph.CARET_LEFT, "Previous slide", cur > 0); b.clicked {
			next = cur - 1
		}
		for i in 0 ..< count {
			id := core.key_id_int(ctx, i)
			it := core.interact(ctx, id)
			dot := layout.Node {
				flex_direction  = .Row,
				align_items     = .Center,
				justify_content = .Center,
				size            = {{16, .Px}, {16, .Px}},
			}
			flags := core.Node_Flags{.Hit, .Focusable, .Activate}
			if core.open(ctx, id, dot, nil, label = fmt.tprintf("Slide %d", i + 1), flags = flags) {
				inner := layout.Node{size = {{6, .Px}, {6, .Px}}}
				core.leaf(ctx, core.auto_id(ctx), inner, core.Paint_Box {
					fill  = .Fg if i == cur else .Border_Strong,
					border = .Fg if it.hovered && i != cur else .None,
					border_width = 1 if it.hovered && i != cur else 0,
				})
				if i == cur {
					core.set_a11y_state(ctx, id, {.Selected})
				}
			}
			core.close(ctx)
			if it.clicked {
				next = i
			}
		}
		if b := carousel_arrow(ph.CARET_RIGHT, "Next slide", cur < count - 1); b.clicked {
			next = cur + 1
		}
	}
	core.close(ctx)
	res.changed = next != cur
	return res, next
}

@(private)
carousel_arrow :: proc(glyph: Icon, label: string, enabled: bool) -> Response {
	ctx := core.current()
	id, _ := core.label_id(ctx, label)
	it := core.interact(ctx, id)
	ln := layout.Node {
		flex_direction  = .Row,
		align_items     = .Center,
		justify_content = .Center,
		size            = {{20, .Px}, {20, .Px}},
	}
	flags := core.Node_Flags{.Hit, .Focusable, .Activate}
	if !enabled {
		flags += {.Disabled}
	}
	paint: core.Paint
	if enabled && it.hovered {
		paint = core.Paint_Box{fill = .Overlay}
	}
	if core.open(ctx, id, ln, paint, label = label, flags = flags) {
		gl := layout.Node{size = {{10, .Px}, {10, .Px}}}
		core.leaf(ctx, core.auto_id(ctx), gl, core.Paint_Icon {
			icon = glyph,
			weight = .Bold,
			color = .Fg if enabled else .Faint,
		})
	}
	core.close(ctx)
	return response_interactive(ctx, id, !enabled)
}
