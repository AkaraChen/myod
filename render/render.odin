// Draw commands: plain data that describes one frame. The backend consumes them; nothing here
// depends on the GPU (see ARCHITECTURE.md, "Module layout").
package render

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

Draw_Command :: union {
	Cmd_Rect,
	Cmd_Clip_Push,
	Cmd_Clip_Pop,
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
