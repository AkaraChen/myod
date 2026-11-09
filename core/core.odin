// The declaration layer and the frame tree (ARCHITECTURE.md, "API design" and "Frame tree and
// performance").
//
// Each pass, `view` declares a tree of nodes into a flat, pre-order array. Declaring is cheap: one
// record, an ID and a content hash. After `view`, Taffy lays the array out (layout/), absolute rects
// are rounded to physical pixels, and only then are draw commands generated.
//
// What has to outlive a pass lives in a *slot*, one per widget ID: the last rect, the hash its layout
// cache belongs to, and the library's per-ID state. Slots not declared for RECLAIM_FRAMES frames are
// reclaimed.
//
// - Subtree reuse: a node's hash covers its ID, its style, what it draws and, through its children's
//   hashes, everything declared below it (a Merkle tree). When it matches the hash the slot's layout
//   cache was built for, Taffy answers the whole subtree from the cache without descending into it.
// - Culling: a container that was entirely outside the visible area in the previous pass is not
//   opened (it returns false) and becomes a placeholder of its previous size. The slots inside it are
//   kept alive. If the placeholder turns out to be visible after layout, the pass reruns.
// - Ghost passes: when layout disagrees with a size `view` read (`measured`), or a culled container
//   became visible, the pass is discarded and `view` runs again, at most MAX_PASSES times.
package core

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:time"

import "../icons"
import "../layout"
import "../render"
import "../text"
import "../theme"

Id :: distinct u64
Rect :: render.Rect

MAX_PASSES :: 3
RECLAIM_FRAMES :: 120

// Colors are always tokens (ARCHITECTURE.md, "API design → 10"), resolved against the surface they
// are drawn on.
Token :: enum u8 {
	None,
	Bg,
	Bg_Solid,
	Fg,
	Muted,
	Faint,
	Border,
	Border_Strong,
	Overlay,
	Overlay_Hover,
	Error,
	Warning,
	Success,
	Info,
}

// What a node draws, recorded during `view` and drawn after layout with the final rect.
Paint_Box :: struct {
	fill:         Token,
	border:       Token,
	border_width: f32,
}

Paint_Text :: struct {
	s:     string,
	style: text.Style, // its color is ignored: `color` is resolved at draw time
	color: Token,
	wrap:  bool,
}

// A hairline along the node (dividers). Its thickness comes from `thickness` (logical pixels), not
// from the laid-out rect, so every line is equally thick in physical pixels wherever it lands.
Paint_Line :: struct {
	color:     Token,
	thickness: f32,
	vertical:  bool,
}

Paint_Icon :: struct {
	icon:   icons.Icon,
	weight: icons.Weight,
	color:  Token,
}

Paint :: union {
	Paint_Box,
	Paint_Text,
	Paint_Line,
	Paint_Icon,
}

Node_Flag :: enum u8 {
	Culled, // a placeholder for a container outside the visible area
	Clip, // clips its descendants to its rect
	Hit, // takes the pointer: hover, press, click (input phase)
	Focusable, // takes keyboard focus on press and with Tab
	Activate, // Space and Enter click it while focused
	Disabled, // drawn at the theme's disabled opacity, with everything inside; takes no input
}
Node_Flags :: bit_set[Node_Flag;u8]

Node :: struct {
	id:           Id,
	hash:         u64, // own content; once finished, also every child's hash (Merkle)
	paint:        Paint,
	rect:         Rect, // absolute, logical pixels, edges on physical pixels (after layout)
	slot:         i32,
	parent:       i32,
	end:          i32, // the subtree is [index, end)
	first_child:  i32,
	last_child:   i32,
	next_sibling: i32,
	child_count:  i32,
	flags:        Node_Flags,
	// Semantics for the accessibility tree (a11y.odin).
	role:         Role,
	name:         string,
	a11y_value:   string,
}

Slot :: struct {
	id:          Id,
	in_use:      bool,
	has_rect:    bool,
	last_frame:  u64, // the last frame it was declared, or kept alive inside a culled container
	layout_hash: u64, // the subtree hash its layout cache belongs to; 0: none
	rect:        Rect, // from the last pass it was laid out in
	seen:        u32, // the pass stamp of that layout
	index:       i32, // its index in that pass's tree
	declared:    u32, // the pass stamp of its last declaration, to catch duplicate IDs
	kept:        [dynamic]i32, // while culled: the slots inside, kept alive
	state:       rawptr, // the library's per-ID state (`state`)
	state_type:  typeid,
}

Tree :: struct {
	nodes:    [dynamic]Node,
	lnodes:   [dynamic]layout.Node, // the same nodes as Taffy sees them
	children: [dynamic]u32,
	tracks:   [dynamic]layout.Track,
}

Grid_Tracks :: struct {
	columns, rows, auto_columns, auto_rows: []layout.Track,
}

Stats :: struct {
	declared:     int, // nodes declared in the last pass
	culled:       int, // containers culled in the last pass
	reused:       int, // nodes whose subtree did not change, so their layout cache stayed valid
	reused_roots: int, // the largest such subtrees
	passes:       int, // passes this frame (1 unless a ghost pass happened)
	layout:       layout.Stats,
	view_time:    time.Duration,
	layout_time:  time.Duration, // Taffy plus rect resolution
	draw_time:    time.Duration,
	frame_time:   time.Duration,
}

View_Proc :: #type proc(data: rawptr)

Context :: struct {
	text:       ^text.Context,
	theme:      theme.Theme,
	scale:      f32,
	viewport:   Rect, // the visible area, in root coordinates
	frame:      u64,
	stamp:      u32, // increments every pass
	trees:      [2]Tree, // this pass and the previous one
	cur:        int,
	stack:      [dynamic]i32, // open containers
	scopes:     [dynamic]Id, // ID scopes: open containers and push_id
	slots:      [dynamic]Slot,
	slot_of:    map[Id]i32,
	free_slots: [dynamic]i32,
	reads:      [dynamic]Read,
	warned:     map[Id]bool,
	names:      map[string]Id, // widget keys declared this pass, for focus("key")
	layout:     layout.Ctx,
	stats:      Stats,
	odin:       runtime.Context, // for the measure callback
	no_culling: bool, // for tests: lay out everything
	a11y:       [dynamic]A11y_Node, // the semantic tree of the last pass
	a11y_prev:  [dynamic]A11y_Node, // for MYOD_A11Y_LOG
	a11y_log:   bool,
	ax:         rawptr, // the platform accessibility adapter (a11y_macos.odin)
	// An accessibility action changed an interaction result outside the platform event stream.
	frame_requested: bool,
	size:        [2]f32, // the window's logical size this frame
	frame_start: time.Tick,
	pass_start:  time.Tick,
	input:       Input,
}

@(private)
Read :: struct {
	id:   Id,
	size: [2]f32, // zero if the node had no layout yet
}

@(private, thread_local)
current_ctx: ^Context

ROOT_ID :: Id(0x6d796f645f726f6f) // "myod_roo"

init :: proc(ctx: ^Context, txt: ^text.Context) -> bool {
	if !layout.abi_ok() {
		fmt.eprintln("myod: layout/layout.odin does not match libmyod_ffi (rebuild third_party/prebuilt)")
		return false
	}
	ctx.text = txt
	ctx.layout = layout.create()
	ctx.scale = 0
	ctx.a11y_log = a11y_log_enabled()
	return true
}

destroy :: proc(ctx: ^Context) {
	for &s in ctx.slots {
		delete(s.kept)
		if s.state != nil {
			free(s.state)
		}
	}
	for &t in ctx.trees {
		delete(t.nodes)
		delete(t.lnodes)
		delete(t.children)
		delete(t.tracks)
	}
	delete(ctx.stack)
	delete(ctx.scopes)
	delete(ctx.slots)
	delete(ctx.slot_of)
	delete(ctx.free_slots)
	delete(ctx.reads)
	delete(ctx.warned)
	delete(ctx.names)
	delete(ctx.a11y)
	a11y_prev_destroy(ctx)
	input_destroy(&ctx.input)
	layout.destroy(ctx.layout)
	ctx^ = {}
}

// The context of the frame being declared. Widgets call this; calling one outside a frame is a bug.
current :: proc(loc := #caller_location) -> ^Context {
	assert(current_ctx != nil, "myod: a widget was declared outside a frame", loc)
	return current_ctx
}

// Runs one frame: `view` (more than once if a ghost pass is needed), layout, then draw commands
// into `list`. `size` is the logical size of the window; `scroll` offsets the visible area.
// The frame loop of ui/ drives the same phases one by one (frame_begin, pass_begin, pass_end,
// frame_end), with the input phase before them.
frame :: proc(ctx: ^Context, view: View_Proc, data: rawptr, size: [2]f32, scale: f32, t: theme.Theme, list: ^render.Command_List, scroll := [2]f32{}) {
	outer := frame_begin(ctx, size, scale, t, scroll)
	for pass in 0 ..< MAX_PASSES {
		pass_begin(ctx)
		view(data)
		if pass_end(ctx) {
			break
		}
		if pass == MAX_PASSES - 1 {
			fmt.eprintln("myod: layout did not settle after", MAX_PASSES, "passes; presenting the last one")
		}
	}
	consume(ctx)
	frame_end(ctx, list, outer)
}

// Starts a frame: makes `ctx` current (until frame_end) and returns the context that was current.
frame_begin :: proc(ctx: ^Context, size: [2]f32, scale: f32, t: theme.Theme, scroll := [2]f32{}) -> (outer: ^Context) {
	ctx.frame_start = time.tick_now()
	ctx.frame += 1
	ctx.theme = t
	ctx.odin = context
	ctx.size = size
	if scale != ctx.scale {
		// Text measures differently at another scale: no cached layout is valid any more.
		for &s in ctx.slots {
			s.layout_hash = 0
		}
		ctx.scale = scale
	}
	ctx.viewport = {scroll.x, scroll.y, size.x, size.y}
	outer = current_ctx
	current_ctx = ctx
	ctx.stats = {}
	return
}

// Starts a pass: `view` declares into a fresh node array.
pass_begin :: proc(ctx: ^Context) {
	begin_pass(ctx, ctx.size)
	ctx.pass_start = time.tick_now()
}

// Ends a pass: lays it out. Returns whether it can be presented; if not (a size `view` read
// changed, or a culled container became visible), `view` must run again.
pass_end :: proc(ctx: ^Context) -> bool {
	ctx.stats.view_time += time.tick_since(ctx.pass_start)
	end_pass(ctx)
	t1 := time.tick_now()
	run_layout(ctx, ctx.size)
	resolve(ctx)
	ctx.stats.layout_time += time.tick_since(t1)
	ctx.stats.passes += 1
	a11y_build(ctx)
	return stable(ctx)
}

// Generates the draw commands of the last pass and restores the context that was current before
// frame_begin.
frame_end :: proc(ctx: ^Context, list: ^render.Command_List, outer: ^Context) {
	t2 := time.tick_now()
	draw(ctx, list)
	ctx.stats.draw_time = time.tick_since(t2)
	if ctx.frame % 16 == 0 {
		reclaim(ctx)
	}
	ctx.stats.frame_time = time.tick_since(ctx.frame_start)
	a11y_log_frame(ctx)
	current_ctx = outer
}

// Lays the last pass out again at another window size and draws it, without running `view`: for
// redraws from inside the platform's event callback while a window edge is being dragged, when the
// app's loop cannot run.
relayout :: proc(ctx: ^Context, size: [2]f32, scale: f32, t: theme.Theme, list: ^render.Command_List) {
	tr := &ctx.trees[ctx.cur]
	if len(tr.nodes) == 0 {
		return
	}
	outer := current_ctx
	current_ctx = ctx
	defer current_ctx = outer
	ctx.odin = context
	ctx.theme = t
	if scale != ctx.scale {
		for &s in ctx.slots {
			s.layout_hash = 0
		}
		ctx.scale = scale
	}
	ctx.size = size
	ctx.viewport.w, ctx.viewport.h = size.x, size.y
	root := &tr.lnodes[0]
	root.size = {{size.x, .Px}, {}}
	root.min_size = {{}, {size.y, .Px}}
	tr.nodes[0].hash = mix(tr.nodes[0].hash, u64(transmute(u32)size.x) << 32 | u64(transmute(u32)size.y))
	run_layout(ctx, size)
	resolve(ctx)
	draw(ctx, list)
}

// Makes `ctx` the current context (for the ui/ window stack); returns the previous one.
set_current :: proc(ctx: ^Context) -> ^Context {
	outer := current_ctx
	current_ctx = ctx
	return outer
}

// ---- Declaration ----

// The ID scope children are declared in: the innermost open container or push_id.
scope :: proc(ctx: ^Context) -> Id {
	return ctx.scopes[len(ctx.scopes) - 1]
}

// An ID from a key within the current scope.
key_id :: proc(ctx: ^Context, key: string) -> Id {
	return Id(hash_string(mix(u64(scope(ctx)), 0x6b6579), key))
}

// The ID of a labeled widget, and the part of the label to display: "Save##toolbar" displays
// "Save", but the whole label goes into the ID, so it differs from another "Save" in the same scope.
label_id :: proc(ctx: ^Context, label: string) -> (id: Id, display: string) {
	display = label
	for i in 0 ..< len(label) - 1 {
		if label[i] == '#' && label[i + 1] == '#' {
			display = label[:i]
			break
		}
	}
	return key_id(ctx, label), display
}

key_id_int :: proc(ctx: ^Context, key: int) -> Id {
	return Id(mix(mix(u64(scope(ctx)), 0x696e74), u64(key)))
}

// Remembers a widget's globally unique name for this pass, so an effect can focus it.
register_name :: proc(ctx: ^Context, name: string, id: Id) {
	if name != "" {
		ctx.names[name] = id
	}
}

// The ID that declared `name` in the last pass, if any.
name_id :: proc(ctx: ^Context, name: string) -> (Id, bool) {
	id, ok := ctx.names[name]
	return id, ok
}

// An ID for an unnamed node: its position among its parent's children.
auto_id :: proc(ctx: ^Context) -> Id {
	t := &ctx.trees[ctx.cur]
	parent := ctx.stack[len(ctx.stack) - 1]
	return Id(mix(mix(u64(scope(ctx)), 0x6175746f), u64(t.nodes[parent].child_count)))
}

push_id :: proc(ctx: ^Context, id: Id) {
	append(&ctx.scopes, id)
}

pop_id :: proc(ctx: ^Context) {
	assert(len(ctx.scopes) > len(ctx.stack), "myod: pop_id without a matching push_id")
	pop(&ctx.scopes)
}

// The parent's layout direction, for widgets whose style depends on it.
parent_direction :: proc(ctx: ^Context) -> (dir: layout.Direction, grid: bool) {
	t := &ctx.trees[ctx.cur]
	ln := &t.lnodes[ctx.stack[len(ctx.stack) - 1]]
	return ln.flex_direction, ln.display == .Grid
}

// Opens a container. Returns false when it is culled: its content must not be declared, but
// `close` must still be called.
open :: proc(ctx: ^Context, id: Id, style: layout.Node, paint: Paint = nil, grid: Grid_Tracks = {}, clip := false, cull := true, label := "", flags: Node_Flags = {}) -> bool {
	index := add_node(ctx, id, style, paint, grid, label)
	t := &ctx.trees[ctx.cur]
	n := &t.nodes[index]
	n.flags = flags
	if clip {
		n.flags += {.Clip}
	}
	a11y_declare(n, label)
	append(&ctx.stack, index)
	append(&ctx.scopes, n.id)
	s := &ctx.slots[n.slot]
	if cull && !ctx.no_culling && s.seen == ctx.stamp - 1 && s.rect.w > 0 && s.rect.h > 0 && !intersects(s.rect, ctx.viewport) {
		// A placeholder of the previous size: no children, no paint, nothing to lay out inside.
		ln := &t.lnodes[index]
		ln.display = .Flex
		ln.size = {{s.rect.w, .Px}, {s.rect.h, .Px}}
		ln.min_size = {}
		ln.max_size = {}
		ln.flex_grow = 0
		ln.flex_shrink = 0
		ln.flex_basis = {}
		ln.grid_columns, ln.grid_rows, ln.grid_auto_columns, ln.grid_auto_rows = {}, {}, {}, {}
		n.paint = nil
		n.flags += {.Culled}
		n.hash = mix(mix(n.hash, 0x63756c6c), u64(transmute(u32)s.rect.w) << 32 | u64(transmute(u32)s.rect.h))
		keep_alive(ctx, n.slot)
		ctx.stats.culled += 1
		return false
	}
	if s.kept != nil {
		delete(s.kept)
		s.kept = nil
	}
	return true
}

close :: proc(ctx: ^Context) {
	assert(len(ctx.stack) > 1, "myod: close without a matching open")
	index := pop(&ctx.stack)
	pop(&ctx.scopes)
	finish(ctx, index)
}

// Declares a node without children. `measured` leaves are sized by the text measure callback.
leaf :: proc(ctx: ^Context, id: Id, style: layout.Node, paint: Paint = nil, measured := false, label := "", flags: Node_Flags = {}) -> i32 {
	s := style
	s.measure = 1 if measured else 0
	index := add_node(ctx, id, s, paint, {}, label)
	ctx.trees[ctx.cur].nodes[index].flags = flags
	a11y_declare(&ctx.trees[ctx.cur].nodes[index], label)
	finish(ctx, index)
	return index
}

// The last laid-out size of a node, in logical pixels. The read is recorded: if this pass's layout
// gives the node another size, the pass reruns with the new one.
measured :: proc(ctx: ^Context, id: Id) -> [2]f32 {
	size: [2]f32
	if slot, ok := ctx.slot_of[id]; ok && ctx.slots[slot].has_rect {
		r := ctx.slots[slot].rect
		size = {r.w, r.h}
	}
	append(&ctx.reads, Read{id = id, size = size})
	return size
}

// The size of the whole page laid out in the last pass (the root), in logical pixels.
content_size :: proc(ctx: ^Context) -> [2]f32 {
	t := &ctx.trees[ctx.cur]
	if len(t.nodes) == 0 {
		return {}
	}
	return {t.nodes[0].rect.w, t.nodes[0].rect.h}
}

// The last laid-out rect of a node (absolute, logical pixels), without recording a read.
last_rect :: proc(ctx: ^Context, id: Id) -> (Rect, bool) {
	slot, ok := ctx.slot_of[id]
	if !ok || !ctx.slots[slot].has_rect {
		return {}, false
	}
	return ctx.slots[slot].rect, true
}

// The library's state for a widget ID, created zeroed on first use (`created` is true then) and
// freed when the ID's slot is reclaimed. Not for app data: that goes into the app's State.
state :: proc(ctx: ^Context, id: Id, $T: typeid) -> (s: ^T, created: bool) {
	slot := &ctx.slots[slot_for(ctx, id)]
	if slot.state == nil {
		slot.state = new(T)
		slot.state_type = T
		return (^T)(slot.state), true
	}
	assert(slot.state_type == T, "myod: widget state of another type under the same ID")
	return (^T)(slot.state), false
}

@(private)
add_node :: proc(ctx: ^Context, id: Id, style: layout.Node, paint: Paint, grid: Grid_Tracks, label: string) -> i32 {
	t := &ctx.trees[ctx.cur]
	index := i32(len(t.nodes))
	id := id
	slot := slot_for(ctx, id)
	if ctx.slots[slot].declared == ctx.stamp {
		// Two widgets with one ID would silently share state; warn, and keep going with a unique ID.
		if !ctx.warned[id] {
			ctx.warned[id] = true
			fmt.eprintfln("myod: duplicate widget ID %016x%s%s: give one of them an id or a ##suffix", u64(id), " for " if label != "" else "", label)
		}
		id = Id(mix(u64(id), u64(index)))
		slot = slot_for(ctx, id)
	}
	s := &ctx.slots[slot]
	s.declared = ctx.stamp
	s.last_frame = ctx.frame

	ln := style
	ln.first_child, ln.child_count, ln.slot = 0, 0, 0
	ln.grid_columns, ln.grid_rows, ln.grid_auto_columns, ln.grid_auto_rows = {}, {}, {}, {}
	h := hash_words(mix(0x6d796f64, u64(id)), &ln, size_of(ln))
	h = hash_tracks(h, grid.columns)
	h = hash_tracks(h, grid.rows)
	h = hash_tracks(h, grid.auto_columns)
	h = hash_tracks(h, grid.auto_rows)
	h = hash_paint(h, paint)

	ln.slot = u32(slot)
	ln.grid_columns = add_tracks(t, grid.columns)
	ln.grid_rows = add_tracks(t, grid.rows)
	ln.grid_auto_columns = add_tracks(t, grid.auto_columns)
	ln.grid_auto_rows = add_tracks(t, grid.auto_rows)

	parent := ctx.stack[len(ctx.stack) - 1] if len(ctx.stack) > 0 else -1
	append(&t.lnodes, ln)
	append(&t.nodes, Node{id = id, hash = h, paint = paint, slot = slot, parent = parent, end = index + 1, first_child = -1, last_child = -1, next_sibling = -1})
	if parent >= 0 {
		p := &t.nodes[parent]
		if p.last_child >= 0 {
			t.nodes[p.last_child].next_sibling = index
		} else {
			p.first_child = index
		}
		p.last_child = index
		p.child_count += 1
	}
	ctx.stats.declared += 1
	return index
}

// Closes a node: lists its children for Taffy and folds their hashes into its own.
@(private)
finish :: proc(ctx: ^Context, index: i32) {
	t := &ctx.trees[ctx.cur]
	n := &t.nodes[index]
	n.end = i32(len(t.nodes))
	ln := &t.lnodes[index]
	ln.first_child = u32(len(t.children))
	ln.child_count = u32(n.child_count)
	for c := n.first_child; c >= 0; c = t.nodes[c].next_sibling {
		append(&t.children, u32(c))
		n.hash = mix(n.hash, t.nodes[c].hash)
	}
}

@(private)
add_tracks :: proc(t: ^Tree, tracks: []layout.Track) -> layout.Tracks {
	if len(tracks) == 0 {
		return {}
	}
	first := u32(len(t.tracks))
	append(&t.tracks, ..tracks)
	return {first, u32(len(tracks))}
}

@(private)
slot_for :: proc(ctx: ^Context, id: Id) -> i32 {
	if slot, ok := ctx.slot_of[id]; ok {
		return slot
	}
	slot: i32
	if len(ctx.free_slots) > 0 {
		slot = pop(&ctx.free_slots)
	} else {
		slot = i32(len(ctx.slots))
		append(&ctx.slots, Slot{})
	}
	ctx.slots[slot] = Slot{id = id, in_use = true, last_frame = ctx.frame, index = -1}
	ctx.slot_of[id] = slot
	return slot
}

// Keeps the slots inside a culled container alive. The first time, they are collected from the
// previous pass's tree, where the container was still open.
@(private)
keep_alive :: proc(ctx: ^Context, slot: i32) {
	s := &ctx.slots[slot]
	if s.kept == nil {
		s.kept = make([dynamic]i32)
		prev := &ctx.trees[1 - ctx.cur]
		if s.index >= 0 && int(s.index) < len(prev.nodes) && prev.nodes[s.index].slot == slot {
			for i in s.index + 1 ..< prev.nodes[s.index].end {
				inner := prev.nodes[i].slot
				append(&s.kept, inner)
				append(&s.kept, ..ctx.slots[inner].kept[:])
			}
		}
	}
	for k in s.kept {
		ctx.slots[k].last_frame = ctx.frame
	}
}

// ---- Passes ----

@(private)
begin_pass :: proc(ctx: ^Context, size: [2]f32) {
	ctx.stamp += 1
	ctx.cur = 1 - ctx.cur
	t := &ctx.trees[ctx.cur]
	clear(&t.nodes)
	clear(&t.lnodes)
	clear(&t.children)
	clear(&t.tracks)
	clear(&ctx.stack)
	clear(&ctx.scopes)
	clear(&ctx.reads)
	clear(&ctx.names)
	ctx.stats.declared, ctx.stats.culled, ctx.stats.reused, ctx.stats.reused_roots = 0, 0, 0, 0

	// The root: the window's width, and at least its height, so content can grow to fill it.
	root := layout.Node {
		flex_direction = .Column,
		size           = {{size.x, .Px}, {}},
		min_size       = {{}, {size.y, .Px}},
	}
	append(&ctx.scopes, ROOT_ID)
	index := add_node(ctx, ROOT_ID, root, nil, {}, "root")
	append(&ctx.stack, index)
}

@(private)
end_pass :: proc(ctx: ^Context) {
	assert(len(ctx.stack) == 1, "myod: a container was opened in view but never closed")
	finish(ctx, pop(&ctx.stack))
	pop(&ctx.scopes)
}

@(private)
run_layout :: proc(ctx: ^Context, size: [2]f32) {
	t := &ctx.trees[ctx.cur]
	layout.reserve(ctx.layout, u32(len(ctx.slots)))
	// A slot keeps its cache only if the subtree hash is the one the cache was built for.
	unchanged := make([]bool, len(t.nodes), context.temp_allocator)
	for &n, i in t.nodes {
		s := &ctx.slots[n.slot]
		if s.layout_hash == n.hash {
			unchanged[i] = true
			ctx.stats.reused += 1
			if n.child_count > 0 && (n.parent < 0 || !unchanged[n.parent]) {
				ctx.stats.reused_roots += 1
			}
		} else {
			layout.clear_slot(ctx.layout, u32(n.slot))
			s.layout_hash = n.hash
		}
	}
	input := layout.Input {
		nodes          = raw_data(t.lnodes),
		children       = raw_data(t.children),
		tracks         = raw_data(t.tracks),
		user           = ctx,
		measure        = measure_text,
		node_count     = u32(len(t.lnodes)),
		children_count = u32(len(t.children)),
		track_count    = u32(len(t.tracks)),
		root           = 0,
		width          = size.x,
		height         = math.nan_f32(),
	}
	st: layout.Stats
	layout.compute(ctx.layout, &input, &st)
	ctx.stats.layout.computed += st.computed
	ctx.stats.layout.passes += st.passes
	ctx.stats.layout.cache_hits += st.cache_hits
	ctx.stats.layout.measured += st.measured
}

// Absolute rects, with edges rounded to physical pixels: rounding absolute edges (not sizes) keeps
// rounding error from accumulating down the tree.
@(private)
resolve :: proc(ctx: ^Context) {
	t := &ctx.trees[ctx.cur]
	results := layout.results(ctx.layout)
	origin := make([][2]f32, len(t.nodes), context.temp_allocator)
	s := ctx.scale
	for &n, i in t.nodes {
		l := results[n.slot]
		o := [2]f32{l.x, l.y}
		if n.parent >= 0 {
			o += origin[n.parent]
		}
		origin[i] = o
		x0 := math.round(o.x * s) / s
		y0 := math.round(o.y * s) / s
		x1 := math.round((o.x + l.w) * s) / s
		y1 := math.round((o.y + l.h) * s) / s
		n.rect = {x0, y0, x1 - x0, y1 - y0}
		slot := &ctx.slots[n.slot]
		slot.rect = n.rect
		slot.has_rect = true
		slot.seen = ctx.stamp
		slot.index = i32(i)
	}
}

// Whether this pass can be presented: every size `view` read is still right, and no culled
// container became visible.
@(private)
stable :: proc(ctx: ^Context) -> bool {
	for r in ctx.reads {
		slot, ok := ctx.slot_of[r.id]
		if !ok || !ctx.slots[slot].has_rect {
			continue // never laid out: still unknown
		}
		rect := ctx.slots[slot].rect
		if rect.w != r.size.x || rect.h != r.size.y {
			return false
		}
	}
	t := &ctx.trees[ctx.cur]
	if ctx.stats.culled > 0 {
		for &n in t.nodes {
			if .Culled in n.flags && intersects(n.rect, ctx.viewport) {
				return false
			}
		}
	}
	return true
}

@(private)
reclaim :: proc(ctx: ^Context) {
	for &s, i in ctx.slots {
		if !s.in_use || ctx.frame - s.last_frame <= RECLAIM_FRAMES {
			continue
		}
		delete_key(&ctx.slot_of, s.id)
		delete(s.kept)
		if s.state != nil {
			free(s.state)
		}
		layout.clear_slot(ctx.layout, u32(i))
		s = {}
		append(&ctx.free_slots, i32(i))
	}
}

// ---- Measuring text for Taffy ----

@(private)
measure_text :: proc "c" (user: rawptr, node: u32, known_w, known_h, avail_w, avail_h: f32, out: [^]f32) {
	ctx := (^Context)(user)
	context = ctx.odin
	t := &ctx.trees[ctx.cur]
	p, ok := t.nodes[node].paint.(Paint_Text)
	if !ok {
		out[0] = 0 if math.is_nan(known_w) else known_w
		out[1] = 0 if math.is_nan(known_h) else known_h
		return
	}
	limit: f32
	switch {
	case !math.is_nan(known_w):
		limit = known_w
	case math.is_inf(avail_w, 1) || !p.wrap:
		limit = math.inf_f32(1)
	case math.is_inf(avail_w, -1):
		limit = 0 // min-content: every break opportunity taken
	case:
		limit = avail_w
	}
	size := text.measure_wrapped(ctx.text, p.s, p.style, limit, ctx.scale)
	// Whole physical pixels, so rounding the laid-out rect never makes it narrower than the text.
	w := math.ceil(size.x * ctx.scale) / ctx.scale
	h := max(size.y, p.style.line_height)
	out[0] = w if math.is_nan(known_w) else known_w
	out[1] = h if math.is_nan(known_h) else known_h
	when #config(MYOD_DEBUG_MEASURE, false) {
		fmt.eprintfln("measure %d %q known %v %v avail %v %v -> %v %v", node, p.s[:min(len(p.s), 12)], known_w, known_h, avail_w, avail_h, out[0], out[1])
	}
}

// ---- Drawing ----

@(private)
draw :: proc(ctx: ^Context, list: ^render.Command_List) {
	t := &ctx.trees[ctx.cur]
	n := len(t.nodes)
	if n == 0 {
		return
	}
	scroll := [2]f32{ctx.viewport.x, ctx.viewport.y}
	// The surface each node sits on, for translucent tokens, and the opacity it is drawn at.
	on_solid := make([]bool, n, context.temp_allocator)
	alpha := make([]f32, n, context.temp_allocator)
	clips := make([dynamic]i32, 0, 16, context.temp_allocator) // end index of each open clip
	for i := 0; i < n; i += 1 {
		for len(clips) > 0 && clips[len(clips) - 1] <= i32(i) {
			pop(&clips)
			render.clip_pop(list)
		}
		node := &t.nodes[i]
		solid := on_solid[node.parent] if node.parent >= 0 else false
		a := alpha[node.parent] if node.parent >= 0 else 1
		if .Disabled in node.flags {
			a *= ctx.theme.disabled_alpha
		}
		alpha[i] = a
		visible := intersects(node.rect, ctx.viewport)
		if !visible && .Clip in node.flags {
			i = int(node.end) - 1 // nothing inside can show
			continue
		}
		r := Rect{node.rect.x - scroll.x, node.rect.y - scroll.y, node.rect.w, node.rect.h}
		if visible {
			solid = paint(ctx, list, node.paint, r, solid, a)
			if node.id == ctx.input.focus && ctx.input.focus_visible {
				// The focus ring: 2px of fg, 1px outside the widget (DESIGN.md, "Focus ring").
				ring := Rect{r.x - 3, r.y - 3, r.w + 6, r.h + 6}
				render.bordered(list, ring, color(ctx, .Fg, solid), 2)
			}
		}
		on_solid[i] = solid
		if .Clip in node.flags {
			render.clip_push(list, r)
			append(&clips, node.end)
		}
	}
	for _ in clips {
		render.clip_pop(list)
	}
}

// Draws one node's paint at opacity `a`; returns the surface its children sit on.
@(private)
paint :: proc(ctx: ^Context, list: ^render.Command_List, p: Paint, r: Rect, on_solid: bool, a: f32 = 1) -> bool {
	switch v in p {
	case Paint_Box:
		solid := on_solid
		if v.fill == .Bg_Solid {
			solid = true
		} else if v.fill == .Bg {
			solid = false
		}
		fill := fade(color(ctx, v.fill, on_solid), a)
		if v.border != .None && v.border_width > 0 {
			render.bordered(list, r, fade(color(ctx, v.border, on_solid), a), v.border_width, fill)
		} else if v.fill != .None {
			render.fill(list, r, fill)
		}
		return solid
	case Paint_Text:
		style := v.style
		style.color = fade(color(ctx, v.color, on_solid), a)
		if v.wrap {
			text.draw_wrapped(list, ctx.text, v.s, {r.x, r.y}, style, r.w + 0.5 / ctx.scale, ctx.scale)
		} else {
			text.draw(list, ctx.text, v.s, {r.x, r.y}, style, ctx.scale)
		}
	case Paint_Line:
		line := r
		if v.vertical {
			line.w = v.thickness
		} else {
			line.h = v.thickness
		}
		render.line(list, line, fade(color(ctx, v.color, on_solid), a))
	case Paint_Icon:
		text.draw_icon(list, ctx.text, v.icon, v.weight, {r.x, r.y}, min(r.w, r.h), fade(color(ctx, v.color, on_solid), a), ctx.scale)
	}
	return on_solid
}

@(private)
fade :: proc(c: theme.Color, a: f32) -> theme.Color {
	if a >= 1 {
		return c
	}
	return {c.r, c.g, c.b, u8(f32(c.a) * a + 0.5)}
}

color :: proc(ctx: ^Context, token: Token, on_solid: bool) -> theme.Color {
	p := ctx.theme.on_solid if on_solid else ctx.theme.on_bg
	switch token {
	case .None:
		return {}
	case .Bg:
		return p.bg
	case .Bg_Solid:
		return p.bg_solid
	case .Fg:
		return p.fg
	case .Muted:
		return p.muted
	case .Faint:
		return p.faint
	case .Border:
		return p.border
	case .Border_Strong:
		return p.border_strong
	case .Overlay:
		return p.overlay
	case .Overlay_Hover:
		return p.overlay_hover
	case .Error:
		return p.error
	case .Warning:
		return p.warning
	case .Success:
		return p.success
	case .Info:
		return p.info
	}
	return {}
}

intersects :: proc(a, b: Rect) -> bool {
	return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

// ---- Hashing ----

mix :: #force_inline proc "contextless" (h, v: u64) -> u64 {
	x := (h ~ v) * 0x9e3779b97f4a7c15
	return x ~ (x >> 29)
}

hash_words :: proc "contextless" (h: u64, data: rawptr, size: int) -> u64 {
	h := h
	words := ([^]u64)(data)
	n := size / 8
	for i in 0 ..< n {
		h = mix(h, words[i])
	}
	if rest := size - n * 8; rest > 0 {
		tail: u64
		bytes := ([^]u8)(data)
		for i in 0 ..< rest {
			tail |= u64(bytes[n * 8 + i]) << uint(8 * i)
		}
		h = mix(h, tail)
	}
	return h
}

hash_string :: proc "contextless" (h: u64, s: string) -> u64 {
	return mix(hash_words(h, raw_data(s), len(s)), u64(len(s)))
}

@(private)
hash_tracks :: proc "contextless" (h: u64, tracks: []layout.Track) -> u64 {
	if len(tracks) == 0 {
		return h
	}
	return hash_words(h, raw_data(tracks), len(tracks) * size_of(layout.Track))
}

@(private)
hash_paint :: proc "contextless" (h: u64, p: Paint) -> u64 {
	switch v in p {
	case Paint_Box:
		return mix(mix(mix(h, 1), u64(v.fill) | u64(v.border) << 8), u64(transmute(u32)v.border_width))
	case Paint_Text:
		t := hash_string(mix(h, 2), v.s)
		st := v.style
		t = mix(t, u64(transmute(u32)st.size) | u64(transmute(u32)st.line_height) << 32)
		t = mix(t, u64(st.weight) | u64(st.font) << 8 | u64(v.color) << 40 | u64(st.underline) << 48 | u64(st.uppercase) << 49 | u64(v.wrap) << 50)
		t = mix(t, u64(transmute(u32)st.letter_spacing))
		t = hash_string(t, st.features)
		return hash_string(t, st.variations)
	case Paint_Line:
		return mix(mix(mix(h, 3), u64(v.color) | u64(v.vertical) << 8), u64(transmute(u32)v.thickness))
	case Paint_Icon:
		return mix(hash_string(mix(h, 4), v.icon.name), u64(v.weight) | u64(v.color) << 8)
	}
	return h
}
