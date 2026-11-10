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
	// A splitter's movement since the last frame, in logical pixels along its axis.
	drag:      f32,
	dragging:  bool,
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

// Text in one of the type roles. It wraps to the width it gets unless `wrap` is false. Body text is
// selectable by default (ARCHITECTURE.md, "API design → 16"); `interactive` text takes clicks
// instead and is not selectable (a todo title that enters edit mode on a double click).
text :: proc(
	s: string,
	style: Text_Style = .Body,
	color: Color = .Fg,
	width: Size = {},
	wrap := true,
	interactive := false,
) -> Response {
	ctx := core.current()
	id := core.auto_id(ctx)
	ln: layout.Node
	item(ctx, &ln, width, {})
	flags := core.Node_Flags{}
	if interactive {
		flags += {.Hit}
	}
	core.leaf(ctx, id, ln, core.Paint_Text{s = s, style = text_style(style), color = token(color), wrap = wrap}, measured = true, flags = flags)
	if interactive {
		return response_interactive(ctx, id, false)
	}
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

// An image the app owns: RGBA8 pixels, `w * 4` bytes per row, straight alpha. Bump `version` when
// the pixels change (the backend keeps one GPU texture per version until it goes unused).
Image :: struct {
	pixels:  []u8,
	w, h:    int,
	version: u64,
}

Image_Fit :: core.Image_Fit

// An image, drawn into the node's rect. Without explicit sizes it takes the image's pixel size.
image :: proc(img: Image, width: Size = {}, height: Size = {}, fit: Image_Fit = .Contain) -> Response {
	ctx := core.current()
	id := core.auto_id(ctx)
	ln := layout.Node{}
	w, h := width, height
	if w.kind == .Fit && w.min == 0 && w.max == 0 {
		w = fixed(f32(img.w))
	}
	if h.kind == .Fit && h.min == 0 && h.max == 0 {
		h = fixed(f32(img.h))
	}
	item(ctx, &ln, w, h)
	core.leaf(ctx, id, ln, core.Paint_Image{pixels = img.pixels, w = img.w, h = img.h, version = img.version, fit = fit})
	return response(ctx, id)
}

// A tag: label type in the signal color, with a 1px border in the same color (DESIGN.md, "Tag").
tag :: proc(s: string, color: Color = .Muted) -> Response {
	ctx := core.current()
	id := core.auto_id(ctx)
	ln := layout.Node {
		flex_direction  = .Row,
		align_items     = .Center,
		justify_content = .Center,
		size            = {{0, .Auto}, {20, .Px}},
		padding         = {6, 0, 6, 0},
	}
	opened := core.open(ctx, id, ln, core.Paint_Box{border = token(color), border_width = 1})
	if opened {
		leaf := layout.Node{}
		core.leaf(ctx, core.auto_id(ctx), leaf, core.Paint_Text {s = s, style = text_style(.Label), color = token(color)}, measured = true)
	}
	core.close(ctx)
	return response(ctx, id)
}

// A section heading: number, title, and an annotation on the right, over a strong border
// (DESIGN.md, "Section heading").
section_heading :: proc(title: string, number: string = "", note: string = "") {
	if column({gap = 8}) {
		if row({gap = 8, align_y = .Center, width = grow()}) {
			if number != "" {
				text(number, .Metadata, .Faint)
			}
			text(title, .Label)
			spacer()
			if note != "" {
				text(note, .Metadata, .Faint)
			}
		}
		strong_divider()
	}
	// 12px below the heading, before the section's content.
	leaf_box({height = fixed(12)})
}

// A key/value row (DESIGN.md, "List row"): 28px, a bottom border, the key muted and the value bold
// on the right, optionally in a signal color.
list_row :: proc(key, value: string, color: Color = .Fg) -> Response {
	ctx := core.current()
	id := core.auto_id(ctx)
	ln := layout.Node {
		flex_direction = .Column,
		size           = {{0, .Auto}, {28, .Px}},
		align_self     = .Stretch, // the value goes to the right edge of the parent
	}
	opened := core.open(ctx, id, ln, nil)
	if opened {
		if row({padding = {8, 0, 8, 0}, align_y = .Center, width = grow(), height = grow()}) {
			text(key, .Compact, .Muted)
			spacer()
			text(value, .Compact, color, wrap = false)
		}
		divider()
	}
	core.close(ctx)
	return response(ctx, id)
}

@(private)
strong_divider :: proc() {
	ctx := core.current()
	ln := layout.Node{align_self = .Stretch, size = {{}, {1, .Px}}}
	core.leaf(ctx, core.auto_id(ctx), ln, core.Paint_Line{color = .Border_Strong, thickness = 1})
}

// A fixed-size empty box, for spacing.
@(private)
leaf_box :: proc(o: Container_Options) -> bool {
	ctx := core.current()
	ln := layout.Node{}
	item(ctx, &ln, o.width, o.height)
	core.leaf(ctx, core.auto_id(ctx), ln, box_paint(o.fill, o.border))
	return true
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
