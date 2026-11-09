// Odin side of myod's Taffy wrapper (ffi/src/layout.rs): the C structs, mirrored field for field,
// and the exported functions. core/ fills a flat node array each frame and reads layouts back per
// slot; see ffi/src/layout.rs for how slots carry Taffy's cache across frames.
package layout

when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	@(export) foreign import ffi "../third_party/prebuilt/macos-arm64/libmyod_ffi.a"
} else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	@(export) foreign import ffi {"../third_party/prebuilt/linux-x86_64/libmyod_ffi.a", "system:pthread", "system:dl", "system:m"}
} else when ODIN_OS == .Linux && ODIN_ARCH == .arm64 {
	@(export) foreign import ffi {"../third_party/prebuilt/linux-arm64/libmyod_ffi.a", "system:pthread", "system:dl", "system:m"}
} else {
	#panic("myod does not support this platform yet: only macOS arm64, Linux x86_64 and Linux arm64")
}

Unit :: enum u32 {
	Auto,
	Px,
	Percent, // value in 0..1
}

// A length: auto, logical pixels or a fraction of the parent.
Dim :: struct {
	value: f32,
	unit:  Unit,
}

Track_Unit :: enum u32 {
	Auto,
	Px,
	Percent,
	Fr,
	Min_Content,
	Max_Content,
	Fit_Content, // fit-content(value px)
}

Track_Size :: struct {
	value: f32,
	unit:  Track_Unit,
}

Repeat :: enum u32 {
	None,
	Auto_Fill,
	Auto_Fit,
	Count,
}

// One grid track, minmax(min, max), optionally repeated on its own: repeat(count, minmax(min, max)).
Track :: struct {
	min, max: Track_Size,
	repeat:   Repeat,
	count:    u32,
}

Place_Kind :: enum u16 {
	Auto,
	Line,
	Span,
}

Placement :: struct {
	kind:  Place_Kind,
	value: i16,
}

// A range of tracks in Input.tracks.
Tracks :: struct {
	first, count: u32,
}

Display :: enum u8 {
	Flex,
	Grid,
	None,
}

Direction :: enum u8 {
	Row,
	Column,
}

Align :: enum u8 {
	None, // the CSS initial value ("normal")
	Start,
	End,
	Flex_Start,
	Flex_End,
	Center,
	Baseline,
	Stretch,
	Space_Between,
	Space_Around,
	Space_Evenly,
}

Overflow :: enum u8 {
	Visible,
	Clip,
	Hidden,
	Scroll,
}

// One node of a frame's tree. Edge arrays are ordered left, right, top, bottom.
// Note the zero value: flex_shrink 0 (CSS's initial value is 1) and no aspect ratio.
Node :: struct {
	first_child:       u32, // into Input.children
	child_count:       u32,
	slot:              u32,
	measure:           u32, // nonzero: a leaf sized by the measure callback
	display:           Display,
	flex_direction:    Direction,
	flex_wrap:         b8,
	align_items:       Align,
	align_self:        Align,
	align_content:     Align,
	justify_content:   Align,
	justify_items:     Align,
	justify_self:      Align,
	position:          u8, // 0 relative, 1 absolute
	overflow_x:        Overflow,
	overflow_y:        Overflow,
	grid_auto_flow:    u8, // 0 row, 1 column, 2 row dense, 3 column dense
	_:                 [3]u8,
	size:              [2]Dim,
	min_size:          [2]Dim,
	max_size:          [2]Dim,
	margin:            [4]f32,
	inset:             [4]Dim,
	padding:           [4]f32,
	border:            [4]f32,
	gap:               [2]f32, // between columns, between rows
	flex_grow:         f32,
	flex_shrink:       f32,
	flex_basis:        Dim,
	aspect_ratio:      f32, // width / height; 0: none
	grid_columns:      Tracks,
	grid_rows:         Tracks,
	grid_auto_columns: Tracks,
	grid_auto_rows:    Tracks,
	grid_column:       [2]Placement, // start, end
	grid_row:          [2]Placement,
}

// A slot's last layout, relative to its parent's border box, in logical pixels (unrounded).
Slot_Layout :: struct {
	x, y, w, h:           f32,
	content_w, content_h: f32, // extent of the content (scrollable overflow), from the node's origin
}

// Answers "how big is this leaf": `known_*` is NaN where not fixed; `avail_*` is the available
// space, with +inf meaning max-content and -inf min-content. Writes width and height to `out`.
Measure_Proc :: #type proc "c" (user: rawptr, node: u32, known_w, known_h, avail_w, avail_h: f32, out: [^]f32)

Input :: struct {
	nodes:          [^]Node,
	children:       [^]u32,
	tracks:         [^]Track,
	user:           rawptr,
	measure:        Measure_Proc,
	node_count:     u32,
	children_count: u32,
	track_count:    u32,
	root:           u32,
	width, height:  f32, // available size of the root; NaN: max-content
}

Stats :: struct {
	computed:   u32, // distinct nodes laid out (not answered from the cache)
	passes:     u32, // layout computations, counting each node once per pass over it
	cache_hits: u32,
	measured:   u32, // measure callbacks
}

Ctx :: distinct rawptr

@(default_calling_convention = "c")
foreign ffi {
	@(link_name = "myod_layout_new")
	create :: proc() -> Ctx ---
	@(link_name = "myod_layout_free")
	destroy :: proc(ctx: Ctx) ---
	// Makes room for `slots` slots; new ones start with an empty cache. Invalidates `results`.
	@(link_name = "myod_layout_reserve")
	reserve :: proc(ctx: Ctx, slots: u32) ---
	// Empties a slot's layout cache.
	@(link_name = "myod_layout_clear")
	clear_slot :: proc(ctx: Ctx, slot: u32) ---
	// The per-slot layouts, valid until the next `reserve`.
	@(link_name = "myod_layout_results")
	results :: proc(ctx: Ctx) -> [^]Slot_Layout ---
	@(link_name = "myod_layout_compute")
	compute :: proc(ctx: Ctx, input: ^Input, stats: ^Stats) ---
	@(link_name = "myod_layout_abi")
	abi :: proc(out: [^]u32) ---
}

// Checks that the Odin mirror of the C structs matches the library.
abi_ok :: proc() -> bool {
	sizes: [5]u32
	abi(&sizes[0])
	return sizes == {size_of(Node), size_of(Track), size_of(Slot_Layout), size_of(Input), size_of(Stats)}
}
