// Controls: the widgets that take input. They declare their node with the interaction flags and read
// the input phase while declaring, so hover, press and focus are drawn on the very pass that sees
// them (ARCHITECTURE.md, "API design → 3"; DESIGN.md, "Components").
package ui

import "../core"
import "../layout"

// The button variants of DESIGN.md, "Components": outline is the default, primary the main action,
// ghost for toolbars, danger for destructive actions.
Button_Variant :: enum {
	Outline,
	Primary,
	Ghost,
	Danger,
}

// Components share a height of 28px (24px for small), so buttons and inputs line up
// (DESIGN.md, "Components").
Control_Size :: enum {
	Default,
	Small,
}

// A button with a label, and optionally an icon before it. Returns the pass's interaction.
button :: proc(
	label: string,
	icon: Icon = {},
	variant: Button_Variant = .Outline,
	size: Control_Size = .Default,
	disabled := false,
) -> Response {
	return button_impl(label, icon, false, variant, size, disabled)
}

// A square, icon-only button (28×28, 24×24 for small). `label` is its accessible name.
icon_button :: proc(
	icon: Icon,
	label: string,
	variant: Button_Variant = .Outline,
	size: Control_Size = .Default,
	disabled := false,
) -> Response {
	return button_impl(label, icon, true, variant, size, disabled)
}

@(private)
button_impl :: proc(
	label: string,
	glyph: Icon,
	icon_only: bool,
	variant: Button_Variant,
	size: Control_Size,
	disabled: bool,
) -> Response {
	ctx := core.current()
	id, display := core.label_id(ctx, label)
	core.register_name(ctx, label, id)

	it := core.interact(ctx, id)
	hovered := it.hovered && !disabled
	pressed := it.pressed && !disabled
	height: f32 = 24 if size == .Small else 28
	pad_x: f32 = 8 if size == .Small else 12
	icon_size: f32 = 14 if size == .Small else 16
	gap: f32 = 4 if size == .Small else 6

	ln := layout.Node {
		flex_direction  = .Row,
		align_items     = .Center,
		justify_content = .Center,
		gap             = {gap, gap},
		size            = {{0, .Auto}, {height, .Px}},
	}
	if icon_only {
		ln.size[0] = {height, .Px}
	} else {
		ln.padding = edges({pad_x, 0, pad_x, 0})
	}

	p := core.Paint_Box{border_width = 1}
	fg_token: core.Token = .Fg
	switch variant {
	case .Outline:
		p.border = .Border
		if pressed {
			p.fill = .Overlay_Hover
		} else if hovered {
			p.fill = .Overlay
		}
	case .Ghost:
		p.border_width = 0
		if pressed {
			p.fill = .Overlay_Hover
		} else if hovered {
			p.fill = .Overlay
		}
	case .Primary:
		p.fill = .Fg
		p.border_width = 0
		fg_token = .Bg
	case .Danger:
		p.fill = .Error
		p.border_width = 0
		fg_token = .Bg
	}

	flags := core.Node_Flags{.Hit, .Focusable, .Activate}
	if disabled {
		flags += {.Disabled}
	}
	opened := core.open(ctx, id, ln, p, label = display, flags = flags)
	if opened {
		if glyph.name != "" {
			leaf := layout.Node{size = {{icon_size, .Px}, {icon_size, .Px}}}
			core.leaf(ctx, core.auto_id(ctx), leaf, core.Paint_Icon {
				icon = glyph,
				weight = .Bold,
				color = fg_token,
			})
		}
		if !icon_only {
			lbl := layout.Node{}
			core.leaf(ctx, core.auto_id(ctx), lbl, core.Paint_Text {
				s = display,
				style = text_style(.Label),
				color = fg_token,
			}, measured = true)
		}
	}
	core.close(ctx)

	return response_interactive(ctx, id, disabled)
}

// A Response carrying the pass's interaction state. Disabled widgets report nothing.
@(private)
response_interactive :: proc(ctx: ^core.Context, id: Id, disabled: bool) -> Response {
	r, _ := core.last_rect(ctx, id)
	it := core.interact(ctx, id)
	res := Response {
		id             = id,
		rect           = r,
		focused        = it.focused,
		lost_focus     = it.lost_focus,
	}
	if disabled {
		return res
	}
	res.hovered = it.hovered
	res.pressed = it.pressed
	res.clicked = it.clicked
	res.double_clicked = it.double_clicked
	return res
}
