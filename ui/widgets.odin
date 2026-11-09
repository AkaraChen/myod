// Display widgets: text and icons. Interactive widgets arrive with M4 (see draft.odin).
package ui

import "../core"
import "../icons"
import "../layout"
import txt "../text"

Icon :: icons.Icon

Response :: struct {
	id:                                               Id,
	rect:                                             Rect, // where it was in the last layout
	hovered, pressed, clicked, double_clicked:        bool,
	changed, submitted, cancelled, focused, lost_focus: bool,
}

// The type roles of DESIGN.md, "Typography".
Text_Style :: enum {
	Display,
	Page_Title,
	Title,
	Section,
	Subsection,
	Lede,
	Body,
	Compact,
	Label,
	Metadata,
}

// Text and icon colors: tokens only (ARCHITECTURE.md, "API design → 10").
Color :: enum {
	Fg,
	Muted,
	Faint,
	Error,
	Warning,
	Success,
	Info,
}

// Text in one of the type roles. It wraps to the width it gets unless `wrap` is false.
text :: proc(s: string, style: Text_Style = .Body, color: Color = .Fg, width: Size = {}, wrap := true) -> Response {
	ctx := core.current()
	id := core.auto_id(ctx)
	ln: layout.Node
	item(ctx, &ln, width, {})
	core.leaf(ctx, id, ln, core.Paint_Text{s = s, style = text_style(style), color = token(color), wrap = wrap}, measured = true)
	return response(ctx, id)
}

// A Phosphor icon, `size` logical pixels square. Bold by default (DESIGN.md, "Icons").
icon :: proc(i: Icon, size: f32 = 16, weight: icons.Weight = .Bold, color: Color = .Fg) -> Response {
	ctx := core.current()
	id := core.auto_id(ctx)
	ln := layout.Node{size = {{size, .Px}, {size, .Px}}}
	core.leaf(ctx, id, ln, core.Paint_Icon{icon = i, weight = weight, color = token(color)})
	return response(ctx, id)
}

text_style :: proc(s: Text_Style) -> txt.Style {
	switch s {
	case .Display:
		return {size = 48, line_height = 56, weight = .Bold}
	case .Page_Title:
		return {size = 40, line_height = 48, weight = .Bold}
	case .Title:
		return {size = 32, line_height = 40, weight = .Bold}
	case .Section:
		return {size = 24, line_height = 32, weight = .Bold}
	case .Subsection:
		return {size = 20, line_height = 26, weight = .Bold}
	case .Lede:
		return {size = 18, line_height = 28, weight = .Regular}
	case .Body:
		return {size = 16, line_height = 24, weight = .Regular}
	case .Compact:
		return {size = 14, line_height = 20, weight = .Regular}
	case .Label:
		return {size = 12, line_height = 20, weight = .Bold, uppercase = true, letter_spacing = 0.12}
	case .Metadata:
		return {size = 12, line_height = 20, weight = .Regular}
	}
	return {size = 16, line_height = 24}
}

@(private)
token :: proc(c: Color) -> core.Token {
	switch c {
	case .Fg:
		return .Fg
	case .Muted:
		return .Muted
	case .Faint:
		return .Faint
	case .Error:
		return .Error
	case .Warning:
		return .Warning
	case .Success:
		return .Success
	case .Info:
		return .Info
	}
	return .Fg
}

@(private)
response :: proc(ctx: ^core.Context, id: Id) -> Response {
	r, _ := core.last_rect(ctx, id)
	return {id = id, rect = r}
}
