// Containers and layout (ARCHITECTURE.md, "API design → 4, 9, 13"). Containers are opened with `if`
// and close themselves at the end of the scope; they return false when culled (core/), and then
// their content is not declared at all.
package ui

import "../core"
import "../layout"

Id :: core.Id
Rect :: core.Rect

// A container's identity within its parent's ID scope, for content whose position among its
// siblings is not stable (list items).
Key :: union {
	int,
	string,
}

Size_Kind :: enum {
	Fit,
	Grow,
	Fixed,
	Percent,
}

// How big something is along one axis:
//   Fit (the zero value): as big as its content; in the parent's main axis it may shrink down to
//                         its min-content size (text then wraps)
//   Grow:    shares the parent's free space in the main axis (by `value`, the weight); stretches in
//            the cross axis and in grid cells
//   Fixed:   exactly `value` logical pixels
//   Percent: `value` (0..1) of the parent's size
// `min` and `max` (logical pixels, 0 = none) clamp any of them.
Size :: struct {
	kind:            Size_Kind,
	value, min, max: f32,
}

fit :: proc(min: f32 = 0, max: f32 = 0) -> Size {
	return {kind = .Fit, min = min, max = max}
}

grow :: proc(min: f32 = 0, max: f32 = 0, weight: f32 = 1) -> Size {
	return {kind = .Grow, value = weight, min = min, max = max}
}

// `grow()` as a constant, for default parameters (which Odin requires to be constant).
GROW :: Size{kind = .Grow, value = 1}

fixed :: proc(v: f32) -> Size {
	return {kind = .Fixed, value = v}
}

percent :: proc(v: f32) -> Size {
	return {kind = .Percent, value = v}
}

// Where children go along an axis. Stretch only applies across the main axis, Space_Between only
// along it.
Align :: enum {
	Start,
	Center,
	End,
	Stretch,
	Space_Between,
}

Fill :: enum {
	None,
	Bg,
	Bg_Solid,
	Overlay,
}

// A 1px border in the `border` or `border-strong` token.
Border :: enum {
	None,
	Default,
	Strong,
}

// Edges in the order left, top, right, bottom. `padding = 8` sets all four.
Edges :: [4]f32

Container_Options :: struct {
	id:                    Key,
	width, height:         Size,
	padding:               Edges,
	gap:                   f32,
	align_x, align_y:      Align,
	wrap:                  bool, // a row wraps into several rows, a column into several columns
	fill:                  Fill,
	border:                Border,
	clip:                  bool, // clip the content to the container
	sticky:                bool, // stays at the top of its scrolling parent (a direct child of `scroll`)
	column_span, row_span: int, // when the parent is a grid
}

// A grid track: `px(240)`, `fr(1)`, `auto()`, `minmax(px(240), fr(1))`, `repeat_fill(...)`.
Track :: layout.Track

Grid_Options :: struct {
	id:                    Key,
	width, height:         Size,
	padding:               Edges,
	columns, rows:         []Track,
	auto_rows:             Track, // rows beyond `rows`; auto by default
	gap:                   f32,
	row_gap:               f32, // 0: same as gap
	align_x, align_y:      Align, // of each item inside its cell, unless the item grows
	fill:                  Fill,
	border:                Border,
	clip:                  bool,
	column_span, row_span: int, // when the parent is a grid
}

px :: proc(v: f32) -> Track {
	return {min = {v, .Px}, max = {v, .Px}}
}

fr :: proc(v: f32 = 1) -> Track {
	return {min = {0, .Auto}, max = {v, .Fr}}
}

auto :: proc() -> Track {
	return {}
}

min_content :: proc() -> Track {
	return {min = {0, .Min_Content}, max = {0, .Min_Content}}
}

max_content :: proc() -> Track {
	return {min = {0, .Max_Content}, max = {0, .Max_Content}}
}

// minmax(min, max): the minimum of `lo`, the maximum of `hi`.
minmax :: proc(lo, hi: Track) -> Track {
	return {min = lo.min, max = hi.max}
}

// repeat(n, track)
repeat :: proc(n: int, t: Track) -> Track {
	r := t
	r.repeat = .Count
	r.count = u32(max(n, 1))
	return r
}

// repeat(auto-fill, track): as many columns as fit.
repeat_fill :: proc(t: Track) -> Track {
	r := t
	r.repeat = .Auto_Fill
	return r
}

// repeat(auto-fit, track): as many as fit, with empty ones collapsed.
repeat_fit :: proc(t: Track) -> Track {
	r := t
	r.repeat = .Auto_Fit
	return r
}

@(deferred_out = _close)
row :: proc(o: Container_Options = {}) -> bool {
	return open_box(o, .Row)
}

@(deferred_out = _close)
column :: proc(o: Container_Options = {}) -> bool {
	return open_box(o, .Column)
}

// A row in a list. Give it the item's `id` so its content keeps its identity when items move.
@(deferred_out = _close)
list_item :: proc(o: Container_Options = {}) -> bool {
	return open_box(o, .Row)
}

// A scrolling column: the wheel, the keyboard and focus movement scroll its content
// (core/scroll.odin).
@(deferred_out = _close)
scroll :: proc(o: Container_Options = {}) -> bool {
	opts := o
	opts.clip = true
	return open_box(opts, .Column, {.Scroll})
}

// A bar pinned to the top of the nearest `scroll` container (a Data Table's header). Declare it as a
// direct child of the scroll container, after the content, so it paints above the rows that scroll
// under it; reserve its height with the scroll container's top padding.
@(deferred_out = _close)
sticky :: proc(o: Container_Options = {}) -> bool {
	ctx := core.current()
	ln := layout.Node {
		position       = 1, // out of the flow: it does not move with the content
		flex_direction = .Row,
		align_items    = .Center,
		padding        = edges(o.padding),
		gap            = {o.gap, o.gap},
	}
	ln.inset[0] = {0, .Px}
	ln.inset[1] = {0, .Px}
	ln.inset[2] = {0, .Px}
	if o.height.kind == .Fixed {
		ln.size[1] = {o.height.value, .Px}
	}
	if o.border != .None {
		ln.border = 1
	}
	return core.open(ctx, key_id(ctx, o.id), ln, box_paint(o.fill, o.border), clip = false, flags = {.Sticky})
}

@(deferred_out = _close)
grid :: proc(o: Grid_Options) -> bool {
	ctx := core.current()
	ln := layout.Node {
		display     = .Grid,
		padding     = edges(o.padding),
		gap         = {o.gap, o.row_gap if o.row_gap > 0 else o.gap},
		align_items = cell_align(o.align_y),
		justify_items = cell_align(o.align_x),
	}
	if o.border != .None {
		ln.border = 1
	}
	item(ctx, &ln, o.width, o.height, o.column_span, o.row_span)
	auto_rows: []Track
	if o.auto_rows != {} {
		auto_rows = []Track{o.auto_rows}
	}
	tracks := core.Grid_Tracks{columns = o.columns, rows = o.rows, auto_rows = auto_rows}
	return core.open(ctx, key_id(ctx, o.id), ln, box_paint(o.fill, o.border), tracks, clip = o.clip)
}

@(private)
_close :: proc(ok: bool) {
	core.close(core.current())
}

// Pushes an ID scope: widgets declared until `pop_id` get IDs within it.
push_id :: proc(key: Key) {
	ctx := core.current()
	core.push_id(ctx, key_id(ctx, key))
}

pop_id :: proc() {
	core.pop_id(core.current())
}

// Fills the free space along the parent's main axis.
spacer :: proc() {
	ctx := core.current()
	ln := layout.Node{flex_grow = 1, flex_shrink = 1, flex_basis = {0, .Px}}
	core.leaf(ctx, core.auto_id(ctx), ln)
}

// A 1px line in the `border` token across the parent: vertical in a row, horizontal otherwise.
divider :: proc() {
	ctx := core.current()
	dir, in_grid := core.parent_direction(ctx)
	ln := layout.Node{align_self = .Stretch, justify_self = .Stretch}
	vertical := dir == .Row && !in_grid
	ln.size[0 if vertical else 1] = {1, .Px}
	core.leaf(ctx, core.auto_id(ctx), ln, core.Paint_Line{color = .Border, thickness = 1, vertical = vertical})
}

// The size a node had in the last layout. If this frame's layout gives it another size, `view` runs
// again with the new one before anything is shown (a ghost pass), so the result is never stale on
// screen.
size_of :: proc(id: Id) -> [2]f32 {
	return core.measured(core.current(), id)
}

@(private)
open_box :: proc(o: Container_Options, dir: layout.Direction, flags: core.Node_Flags = {}) -> bool {
	ctx := core.current()
	ln := layout.Node {
		flex_direction = dir,
		flex_wrap      = b8(o.wrap),
		padding        = edges(o.padding),
		gap            = {o.gap, o.gap},
	}
	main, cross := o.align_x, o.align_y
	if dir == .Column {
		main, cross = o.align_y, o.align_x
	}
	ln.justify_content = justify(main)
	ln.align_items = cell_align(cross)
	if o.wrap {
		ln.align_content = .Start
	}
	f := flags
	if o.sticky {
		f += {.Sticky}
	}
	if o.border != .None {
		ln.border = 1
	}
	item(ctx, &ln, o.width, o.height, o.column_span, o.row_span)
	if .Scroll in f {
		// A scroll container does not take its content's size as its automatic minimum, as on the
		// web: without this it could not shrink below its content and would never scroll. Taffy
		// needs to see the overflow itself, not just the flag: it is what reports the scrollable
		// extent and what keeps the container's content out of its parent's intrinsic size.
		ln.overflow_x = .Scroll
		ln.overflow_y = .Scroll
		if ln.min_size[0].unit == .Auto {
			ln.min_size[0] = {0, .Px}
		}
		if ln.min_size[1].unit == .Auto {
			ln.min_size[1] = {0, .Px}
		}
	}
	return core.open(ctx, key_id(ctx, o.id), ln, box_paint(o.fill, o.border), clip = o.clip, flags = f)
}

// Sets how a node sits in its parent: sizes, flex item properties or grid placement.
@(private)
item :: proc(ctx: ^core.Context, ln: ^layout.Node, width, height: Size, column_span := 0, row_span := 0) {
	dir, in_grid := core.parent_direction(ctx)
	main_axis := 0 if dir == .Row else 1
	sizes := [2]Size{width, height}
	for s, axis in sizes {
		main := !in_grid && axis == main_axis
		switch s.kind {
		case .Fit:
			if main {
				ln.flex_shrink = 1
			}
		case .Grow:
			if main {
				ln.flex_grow = s.value if s.value > 0 else 1
				ln.flex_shrink = 1
				ln.flex_basis = {0, .Px}
			} else if s.max > 0 {
				// Stretching would pin it to the start; 100% clamped by max keeps the parent's alignment
				// (a centered column of `grow(max = 720)` sections stays centered).
				ln.size[axis] = {1, .Percent}
			} else if axis == 0 && in_grid {
				ln.justify_self = .Stretch
			} else {
				ln.align_self = .Stretch
			}
		case .Fixed:
			ln.size[axis] = {s.value, .Px}
		case .Percent:
			ln.size[axis] = {s.value, .Percent}
		}
		if s.min > 0 {
			ln.min_size[axis] = {s.min, .Px}
		}
		if s.max > 0 {
			ln.max_size[axis] = {s.max, .Px}
		}
	}
	if in_grid {
		if column_span > 1 {
			ln.grid_column[1] = {.Span, i16(column_span)}
		}
		if row_span > 1 {
			ln.grid_row[1] = {.Span, i16(row_span)}
		}
	}
}

@(private)
key_id :: proc(ctx: ^core.Context, key: Key) -> Id {
	switch k in key {
	case int:
		return core.key_id_int(ctx, k)
	case string:
		return core.key_id(ctx, k)
	}
	return core.auto_id(ctx)
}

@(private)
box_paint :: proc(fill: Fill, border: Border) -> core.Paint {
	if fill == .None && border == .None {
		return nil
	}
	p := core.Paint_Box{border_width = 1}
	switch fill {
	case .None:
	case .Bg:
		p.fill = .Bg
	case .Bg_Solid:
		p.fill = .Bg_Solid
	case .Overlay:
		p.fill = .Overlay
	}
	switch border {
	case .None:
		p.border_width = 0
	case .Default:
		p.border = .Border
	case .Strong:
		p.border = .Border_Strong
	}
	return p
}

// Left, top, right, bottom → Taffy's left, right, top, bottom.
@(private)
edges :: proc(e: Edges) -> [4]f32 {
	return {e[0], e[2], e[1], e[3]}
}

@(private)
justify :: proc(a: Align) -> layout.Align {
	switch a {
	case .Start, .Stretch:
		return .Start
	case .Center:
		return .Center
	case .End:
		return .End
	case .Space_Between:
		return .Space_Between
	}
	return .Start
}

@(private)
cell_align :: proc(a: Align) -> layout.Align {
	switch a {
	case .Start, .Space_Between:
		return .Start
	case .Center:
		return .Center
	case .End:
		return .End
	case .Stretch:
		return .Stretch
	}
	return .Start
}

// The ID of the innermost open container (or push_id scope), e.g. for `size_of`.
container_id :: proc() -> Id {
	return core.scope(core.current())
}
