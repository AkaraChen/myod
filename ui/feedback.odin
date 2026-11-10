// Feedback and identity components: the toast list and the (square) avatar.
//
// The toast list is application state, like every list in the library: `toast_list` only declares
// what the app holds. Auto-dismiss is the app's timer too. The usual shape is one `ui.after` per
// toast, carrying the toast's generation token, so a toast dismissed and replaced before its timer
// fires is not removed twice:
//
//     Toast_Expire{index = i, generation = generation}
//
//     // when the timer fires:
//     if msg.generation == s.toasts[msg.index].generation { remove(&s.toasts, msg.index) }
//
// Each toast is a live region (Role.Status with A11y_Flag.Live), so a screen reader announces it
// without the user having to find it.
package ui

import "core:fmt"
import "core:unicode"

import "../core"
import ph "../icons/phosphor"
import "../layout"

// ---- Toast ----

Toast_Variant :: enum {
	Default,
	Success,
	Destructive,
}

// One toast. `id` is the app's own identity for it; it only needs to be unique while the toast is
// on screen, and is what a dismissal reports back.
Toast :: struct {
	id:          u64,
	title:       string,
	description: string,
	variant:     Toast_Variant,
	// The app's own token for auto-dismiss: a timer captured this value, and only the toast that
	// still carries it is removed when the timer fires. The component ignores it.
	generation:  u64,
}

Toast_List_Result :: struct {
	res:             Response,
	dismissed:       int, // the index dismissed this pass, -1 when none
	dismissed_id:    u64,
}

// The toast stack, in the window's bottom-right corner: the newest toast at the bottom. Each toast is
// a card with its title, description and close button, and each one is a live region, so it is
// announced as it appears. Controlled: the app owns the slice and rebuilds it on `dismissed`.
toast_list :: proc(toasts: []Toast, key := "toasts") -> Toast_List_Result {
	ctx := core.current()
	id := layer_id(ctx, key)
	out := Toast_List_Result{res = Response{id = id}, dismissed = -1}
	if len(toasts) == 0 {
		return out
	}
	o := core.Layer_Options{bottom_right = true}
	ln := layout.Node {
		position       = 1,
		flex_direction = .Column,
		align_items    = .End,
		gap            = {8, 8},
	}
	if !core.open_layer(ctx, id, ln, nil, o) {
		return out
	}
	core.set_a11y_role(ctx, id, .Group)
	for t, i in toasts {
		cid := core.key_id_int(ctx, int(t.id))
		card := layout.Node {
			flex_direction = .Row,
			align_items    = .Start,
			gap            = {10, 10},
			size           = {{340, .Px}, {0, .Auto}},
			padding        = {12, 12, 12, 12},
		}
		paint := core.Paint_Box{fill = .Bg_Solid, border = .Border_Strong, border_width = 1}
		if core.open(ctx, cid, card, paint, label = t.title) {
			core.set_a11y_role(ctx, cid, .Status)
			core.set_a11y_state(ctx, cid, {.Live})
			glyph: Icon
			color: core.Token = .Muted
			#partial switch t.variant {
			case .Success:
				glyph = ph.CHECK_CIRCLE
				color = .Success
			case .Destructive:
				glyph = ph.WARNING
				color = .Error
			}
			if glyph.name != "" {
				g := layout.Node{size = {{16, .Px}, {16, .Px}}, margin = {0, 1, 0, 0}}
				core.leaf(ctx, core.auto_id(ctx), g, core.Paint_Icon {
					icon = glyph,
					weight = .Bold,
					color = color,
				})
			}
			if column({width = grow(), gap = 3}) {
				if t.title != "" {
					text(t.title, .Label, .Fg)
				}
				if t.description != "" {
					text(t.description, .Metadata, .Muted)
				}
			}
			if b := icon_button(ph.X, "Dismiss", .Ghost, .Small); b.clicked {
				out.dismissed = i
				out.dismissed_id = t.id
			}
		}
		core.close(ctx)
	}
	core.close(ctx)
	if out.dismissed >= 0 {
		out.res.changed = true
	}
	return out
}

// ---- Avatar ----

// A square avatar, `size` pixels a side, showing up to two initials from `name`, or a person glyph
// when the name is empty. Screen readers get the full name.
avatar :: proc(name: string, size := 32, key := "") -> Response {
	ctx := core.current()
	id: Id
	if key != "" {
		id = core.key_id(ctx, key)
	} else {
		id, _ = core.label_id(ctx, name if name != "" else "\x00avatar")
	}
	it := core.interact(ctx, id)
	label := name if name != "" else "Avatar"
	ln := layout.Node {
		flex_direction  = .Row,
		align_items     = .Center,
		justify_content = .Center,
		size            = {{f32(size), .Px}, {f32(size), .Px}},
		flex_shrink     = 0,
	}
	paint: core.Paint = box_paint(.Overlay, .Default)
	if it.hovered {
		paint = core.Paint_Box{fill = .Overlay, border = .Border_Strong, border_width = 1}
	}
	if core.open(ctx, id, ln, paint, label = label, flags = {.Hit, .Focusable}) {
		core.set_a11y_role(ctx, id, .Image)
		initials := avatar_initials(name)
		if initials == "" {
			g := layout.Node{size = {{f32(size) / 2, .Px}, {f32(size) / 2, .Px}}}
			core.leaf(ctx, core.auto_id(ctx), g, core.Paint_Icon {
				icon = ph.USER,
				weight = .Bold,
				color = .Muted,
			})
		} else {
			core.leaf(ctx, core.auto_id(ctx), layout.Node{}, core.Paint_Text {
				s     = initials,
				style = text_style(size >= 40 ? .Compact : .Metadata),
				color = .Fg,
				wrap  = false,
			}, measured = true)
		}
	}
	core.close(ctx)
	return response_interactive(ctx, id, false)
}

// The first and last word's first letters, upper-cased. One word gives one letter.
@(private)
avatar_initials :: proc(name: string) -> string {
	first, last: rune
	count := 0
	at_word := true
	for r in name {
		if unicode.is_space(r) {
			at_word = true
			continue
		}
		if at_word {
			if count == 0 {
				first = unicode.to_upper(r)
			}
			last = unicode.to_upper(r)
			count += 1
			at_word = false
		}
	}
	if count == 0 {
		return ""
	}
	if count > 1 {
		return fmt.tprintf("%c%c", first, last)
	}
	return fmt.tprintf("%c", first)
}
