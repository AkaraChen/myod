// Draw commands: plain data that describes one frame. The backend consumes them; nothing here
// depends on the GPU (see ARCHITECTURE.md, "Module layout").
package render

import "../atlas"
import "../theme"

Color :: theme.Color

// A rectangle in logical pixels.
Rect :: struct {
	x, y, w, h: f32,
}

// How a rectangle's edges map to physical pixels.
Snap :: enum u8 {
	// Snap each edge independently. Adjacent boxes share edges exactly and rounding error never
	// accumulates, but the size may vary by a pixel depending on position. Right for layout boxes.
	Edges,
	// Snap the origin and round the size (at least 1 physical pixel). Every line of the same
	// logical thickness gets the same physical thickness. Right for hairlines and dividers.
	Size,
}

// A filled rectangle with an optional inner border. Borders are drawn inside the rectangle.
// A zero `fill.a` draws no fill; a zero `border_width` draws no border.
Cmd_Rect :: struct {
	rect:         Rect,
	fill:         Color,
	border_color: Color,
	border_width: f32, // logical pixels; at least 1 physical pixel when non-zero
	snap:         Snap,
}

// Intersects the current clip with `rect` until the matching Cmd_Clip_Pop.
Cmd_Clip_Push :: struct {
	rect: Rect,
}

Cmd_Clip_Pop :: struct {}

// One glyph or icon image, already rasterized into an atlas.
Glyph_Quad :: struct {
	atlas:  atlas.Kind,
	page:   i32,
	texel:  [4]i32, // x, y, w, h in the atlas page
	offset: [2]i32, // top-left relative to the run origin, physical pixels
}

// A run of glyphs shaped and rasterized for one display scale. `origin` is the baseline start in
// logical pixels; the backend snaps it to a physical pixel and adds each quad's integer offset, so
// every glyph lands on whole pixels and samples its texels 1:1.
Cmd_Glyph_Run :: struct {
	origin: [2]f32,
	color:  Color, // multiplies mask glyphs; only the alpha applies to color glyphs
	quads:  []Glyph_Quad,
}

// Debug view: a whole atlas page scaled into `rect` (MYOD_DEBUG_ATLAS).
Cmd_Atlas_View :: struct {
	rect:  Rect,
	atlas: atlas.Kind,
	page:  i32,
	color: Color, // multiplies the mask atlas
}

Draw_Command :: union {
	Cmd_Rect,
	Cmd_Clip_Push,
	Cmd_Clip_Pop,
	Cmd_Glyph_Run,
	Cmd_Atlas_View,
}

// The commands for one frame. Allocate it with context.temp_allocator; it lives for one frame.
Command_List :: struct {
	commands: [dynamic]Draw_Command,
}

make_command_list :: proc(allocator := context.temp_allocator) -> Command_List {
	return {commands = make([dynamic]Draw_Command, 0, 256, allocator)}
}

fill :: proc(list: ^Command_List, rect: Rect, color: Color) {
	append(&list.commands, Cmd_Rect{rect = rect, fill = color})
}

// A hairline or other thin bar (dividers, separators): same logical thickness, same physical thickness.
line :: proc(list: ^Command_List, rect: Rect, color: Color) {
	append(&list.commands, Cmd_Rect{rect = rect, fill = color, snap = .Size})
}

// A rectangle with a border and an optional fill (pass a zero color for no fill).
bordered :: proc(list: ^Command_List, rect: Rect, border_color: Color, border_width: f32, fill: Color = {}) {
	append(&list.commands, Cmd_Rect{rect = rect, fill = fill, border_color = border_color, border_width = border_width})
}

clip_push :: proc(list: ^Command_List, rect: Rect) {
	append(&list.commands, Cmd_Clip_Push{rect = rect})
}

clip_pop :: proc(list: ^Command_List) {
	append(&list.commands, Cmd_Clip_Pop{})
}
