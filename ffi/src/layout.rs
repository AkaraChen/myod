//! Taffy over myod's own node array (ARCHITECTURE.md, "Frame tree and performance").
//!
//! Odin declares a fresh array of `Node`s every frame (pre-order, children listed in a separate index
//! array) and Taffy runs directly on it through its low-level tree traits: there is no second tree to
//! keep in sync. What has to survive across frames lives in *slots*, one per widget ID, owned here:
//! Taffy's layout cache and the last layout of the node. Odin clears a slot's cache whenever the
//! content hash of the node's subtree changed, which is exactly Taffy's "mark dirty up to the root";
//! unchanged subtrees then hit the cache and Taffy does not descend into them at all.
//!
//! Styles are read straight from the C structs through views that implement Taffy's style traits.
//! Only grid containers are converted into a `taffy::Style` (on first use within a `compute` call),
//! because their track lists are generic iterators that are simplest to borrow from a real `Style`.

use std::cell::UnsafeCell;
use std::ffi::c_void;

use taffy::geometry::Point;
use taffy::prelude::*;
use taffy::style_helpers::{fr, line, span};
use taffy::{
    compute_cached_layout, compute_flexbox_layout, compute_grid_layout, compute_hidden_layout, compute_leaf_layout,
    compute_oof_layout, compute_root_layout, BoxGenerationMode, Cache, CacheTree, CoreStyle, FlexboxContainerStyle,
    FlexboxItemStyle, GridItemStyle, GridPlacement, GridTemplateComponent, GridTemplateRepetition, LayoutInput,
    LayoutOutput, MaxTrackSizingFunction, MinTrackSizingFunction, OofItemStyle, Overflow, RepetitionCount, RunMode,
    TrackSizingFunction,
};

// ---- The C ABI (mirrored in layout/layout.odin) ----

pub const UNIT_AUTO: u32 = 0;
pub const UNIT_PX: u32 = 1;
pub const UNIT_PERCENT: u32 = 2; // value in 0..1

/// A length: auto, logical pixels or a fraction of the parent.
#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct Dim {
    pub value: f32,
    pub unit: u32,
}

pub const TRACK_AUTO: u32 = 0;
pub const TRACK_PX: u32 = 1;
pub const TRACK_PERCENT: u32 = 2;
pub const TRACK_FR: u32 = 3;
pub const TRACK_MIN_CONTENT: u32 = 4;
pub const TRACK_MAX_CONTENT: u32 = 5;
pub const TRACK_FIT_CONTENT: u32 = 6; // fit-content(value px)

#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct TrackSize {
    pub value: f32,
    pub unit: u32,
}

pub const REPEAT_NONE: u32 = 0;
pub const REPEAT_AUTO_FILL: u32 = 1;
pub const REPEAT_AUTO_FIT: u32 = 2;
pub const REPEAT_COUNT: u32 = 3;

/// One grid track, `minmax(min, max)`, optionally repeated on its own: `repeat(count, minmax(min, max))`.
#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct Track {
    pub min: TrackSize,
    pub max: TrackSize,
    pub repeat: u32,
    pub count: u32,
}

pub const PLACE_AUTO: u16 = 0;
pub const PLACE_LINE: u16 = 1;
pub const PLACE_SPAN: u16 = 2;

#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct Placement {
    pub kind: u16,
    pub value: i16,
}

/// A range of `Track`s in `Input::tracks`.
#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct Tracks {
    pub first: u32,
    pub count: u32,
}

pub const DISPLAY_FLEX: u8 = 0;
pub const DISPLAY_GRID: u8 = 1;
pub const DISPLAY_NONE: u8 = 2;

pub const ALIGN_NONE: u8 = 0; // the CSS initial value
pub const ALIGN_START: u8 = 1;
pub const ALIGN_END: u8 = 2;
pub const ALIGN_FLEX_START: u8 = 3;
pub const ALIGN_FLEX_END: u8 = 4;
pub const ALIGN_CENTER: u8 = 5;
pub const ALIGN_BASELINE: u8 = 6;
pub const ALIGN_STRETCH: u8 = 7;
pub const ALIGN_SPACE_BETWEEN: u8 = 8;
pub const ALIGN_SPACE_AROUND: u8 = 9;
pub const ALIGN_SPACE_EVENLY: u8 = 10;

/// One node of the frame's tree: where its children are, its slot, and its style.
/// Edge arrays are ordered left, right, top, bottom.
#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct Node {
    pub first_child: u32, // into Input::children
    pub child_count: u32,
    pub slot: u32,
    pub measure: u32, // nonzero: a leaf sized by the measure callback

    pub display: u8,
    pub flex_direction: u8, // 0 row, 1 column
    pub flex_wrap: u8,      // 0 no wrap, 1 wrap
    pub align_items: u8,
    pub align_self: u8,
    pub align_content: u8,
    pub justify_content: u8,
    pub justify_items: u8,
    pub justify_self: u8,
    pub position: u8,   // 0 relative, 1 absolute
    pub overflow_x: u8, // 0 visible, 1 clip, 2 hidden, 3 scroll
    pub overflow_y: u8,
    pub grid_auto_flow: u8, // 0 row, 1 column, 2 row dense, 3 column dense
    pub _pad: [u8; 3],

    pub size: [Dim; 2],
    pub min_size: [Dim; 2],
    pub max_size: [Dim; 2],
    pub margin: [f32; 4],
    pub inset: [Dim; 4],
    pub padding: [f32; 4],
    pub border: [f32; 4],
    pub gap: [f32; 2], // between columns, between rows
    pub flex_grow: f32,
    pub flex_shrink: f32,
    pub flex_basis: Dim,
    pub aspect_ratio: f32, // width / height; 0 or NaN: none

    pub grid_columns: Tracks,
    pub grid_rows: Tracks,
    pub grid_auto_columns: Tracks,
    pub grid_auto_rows: Tracks,
    pub grid_column: [Placement; 2], // start, end
    pub grid_row: [Placement; 2],
}

/// A slot's last layout, relative to its parent's border box, in logical pixels (unrounded).
#[repr(C)]
#[derive(Clone, Copy, Default, Debug, PartialEq)]
pub struct SlotLayout {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
    pub content_w: f32, // extent of the content (scrollable overflow), from the node's origin
    pub content_h: f32,
}

/// Answers "how big is this leaf": `known` is NaN where not fixed; `avail` is the available space,
/// with +inf meaning max-content and -inf min-content. Writes width and height to `out`.
pub type MeasureFn =
    extern "C" fn(user: *mut c_void, node: u32, known_w: f32, known_h: f32, avail_w: f32, avail_h: f32, out: *mut f32);

#[repr(C)]
pub struct Input {
    pub nodes: *const Node,
    pub children: *const u32,
    pub tracks: *const Track,
    pub user: *mut c_void,
    pub measure: Option<MeasureFn>,
    pub node_count: u32,
    pub children_count: u32,
    pub track_count: u32,
    pub root: u32,
    pub width: f32, // available size of the root; NaN: max-content
    pub height: f32,
}

#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct Stats {
    pub computed: u32,   // distinct nodes laid out (not answered from the cache)
    pub passes: u32,     // layout computations, counting each node once per pass over it
    pub cache_hits: u32, // lookups answered by the cache
    pub measured: u32,   // measure callbacks
}

pub struct Ctx {
    caches: Vec<Cache>,
    layouts: Vec<SlotLayout>,
    // Per slot: the compute call that last laid it out, to count distinct nodes.
    stamps: Vec<u32>,
    stamp: u32,
}

// ---- Exported functions ----

#[no_mangle]
pub extern "C" fn myod_layout_new() -> *mut Ctx {
    Box::into_raw(Box::new(Ctx { caches: Vec::new(), layouts: Vec::new(), stamps: Vec::new(), stamp: 0 }))
}

/// # Safety
/// `ctx` must come from `myod_layout_new` and not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn myod_layout_free(ctx: *mut Ctx) {
    if !ctx.is_null() {
        drop(Box::from_raw(ctx));
    }
}

/// Makes room for `slots` slots. New slots start with an empty cache. Invalidates `myod_layout_results`.
///
/// # Safety
/// `ctx` must be valid.
#[no_mangle]
pub unsafe extern "C" fn myod_layout_reserve(ctx: *mut Ctx, slots: u32) {
    let ctx = &mut *ctx;
    let n = slots as usize;
    if ctx.caches.len() < n {
        ctx.caches.resize_with(n, Cache::new);
        ctx.layouts.resize(n, SlotLayout::default());
        ctx.stamps.resize(n, 0);
    }
}

/// Empties a slot's layout cache (its subtree changed, or the slot is reused for another ID).
///
/// # Safety
/// `ctx` must be valid and `slot` reserved.
#[no_mangle]
pub unsafe extern "C" fn myod_layout_clear(ctx: *mut Ctx, slot: u32) {
    let ctx = &mut *ctx;
    ctx.caches[slot as usize].clear();
}

/// The per-slot layouts, valid until the next `myod_layout_reserve`.
///
/// # Safety
/// `ctx` must be valid.
#[no_mangle]
pub unsafe extern "C" fn myod_layout_results(ctx: *const Ctx) -> *const SlotLayout {
    let ctx = &*ctx;
    ctx.layouts.as_ptr()
}

/// Lays out the tree in `input` from its root.
///
/// # Safety
/// `ctx` must be valid; the arrays in `input` must be valid for their counts, every slot reserved,
/// and every child and track index in range.
#[no_mangle]
pub unsafe extern "C" fn myod_layout_compute(ctx: *mut Ctx, input: *const Input, stats: *mut Stats) {
    let ctx = &mut *ctx;
    let input = &*input;
    let nodes = if input.node_count == 0 { &[][..] } else { std::slice::from_raw_parts(input.nodes, input.node_count as usize) };
    let children =
        if input.children_count == 0 { &[][..] } else { std::slice::from_raw_parts(input.children, input.children_count as usize) };
    let tracks = if input.track_count == 0 { &[][..] } else { std::slice::from_raw_parts(input.tracks, input.track_count as usize) };
    if nodes.is_empty() {
        return;
    }
    ctx.stamp = ctx.stamp.wrapping_add(1);
    let mut tree = Tree {
        caches: &mut ctx.caches,
        layouts: &mut ctx.layouts,
        stamps: &mut ctx.stamps,
        stamp: ctx.stamp,
        nodes,
        children,
        tracks,
        measure: input.measure,
        user: input.user,
        grids: UnsafeCell::new(Vec::new()),
        hoisted: Vec::new(),
        stats: Stats::default(),
    };
    let space = |v: f32| if v.is_nan() { AvailableSpace::MaxContent } else { AvailableSpace::Definite(v) };
    compute_root_layout(&mut tree, NodeId::from(input.root as usize), Size { width: space(input.width), height: space(input.height) });
    if !stats.is_null() {
        *stats = tree.stats;
    }
}

/// Struct sizes, so the Odin side can check its mirror: Node, Track, SlotLayout, Input, Stats.
///
/// # Safety
/// `out` must have room for 5 values.
#[no_mangle]
pub unsafe extern "C" fn myod_layout_abi(out: *mut u32) {
    let sizes = [
        std::mem::size_of::<Node>(),
        std::mem::size_of::<Track>(),
        std::mem::size_of::<SlotLayout>(),
        std::mem::size_of::<Input>(),
        std::mem::size_of::<Stats>(),
    ];
    for (i, s) in sizes.iter().enumerate() {
        *out.add(i) = *s as u32;
    }
}

// ---- The tree ----

struct Tree<'a> {
    caches: &'a mut [Cache],
    layouts: &'a mut [SlotLayout],
    stamps: &'a mut [u32],
    stamp: u32,
    nodes: &'a [Node],
    children: &'a [u32],
    tracks: &'a [Track],
    measure: Option<MeasureFn>,
    user: *mut c_void,
    // Grid containers converted on first use. Boxed, so references stay valid while the Vec grows.
    grids: UnsafeCell<Vec<(u32, Box<Style<String>>)>>,
    hoisted: Vec<(u32, Vec<NodeId>)>,
    stats: Stats,
}

impl Tree<'_> {
    #[inline]
    fn node(&self, id: NodeId) -> &Node {
        &self.nodes[usize::from(id)]
    }

    fn grid_style(&self, id: NodeId) -> &Style<String> {
        let index = usize::from(id) as u32;
        // SAFETY: entries are only ever appended, and each is a Box whose contents never move; the
        // returned reference borrows `self`, which outlives no mutation of an existing entry.
        let grids = unsafe { &mut *self.grids.get() };
        if let Some((_, style)) = grids.iter().find(|(i, _)| *i == index) {
            return unsafe { &*(style.as_ref() as *const Style<String>) };
        }
        grids.push((index, Box::new(to_grid_style(self.node(id), self.tracks))));
        let style = &grids.last().unwrap().1;
        unsafe { &*(style.as_ref() as *const Style<String>) }
    }

    fn measure_leaf(&mut self, node: usize, known: Size<Option<f32>>, avail: Size<AvailableSpace>) -> Size<f32> {
        let Some(measure) = self.measure else { return Size::ZERO };
        self.stats.measured += 1;
        let space = |a: AvailableSpace| match a {
            AvailableSpace::Definite(v) => v,
            AvailableSpace::MaxContent => f32::INFINITY,
            AvailableSpace::MinContent => f32::NEG_INFINITY,
        };
        let mut out = [0.0f32; 2];
        measure(
            self.user,
            node as u32,
            known.width.unwrap_or(f32::NAN),
            known.height.unwrap_or(f32::NAN),
            space(avail.width),
            space(avail.height),
            out.as_mut_ptr(),
        );
        Size { width: out[0], height: out[1] }
    }
}

pub struct ChildIter<'a>(std::slice::Iter<'a, u32>);

impl Iterator for ChildIter<'_> {
    type Item = NodeId;
    #[inline]
    fn next(&mut self) -> Option<NodeId> {
        self.0.next().map(|&i| NodeId::from(i as usize))
    }
}

impl taffy::TraversePartialTree for Tree<'_> {
    type ChildIter<'b>
        = ChildIter<'b>
    where
        Self: 'b;

    fn child_ids(&self, parent: NodeId) -> ChildIter<'_> {
        let n = self.node(parent);
        ChildIter(self.children[n.first_child as usize..(n.first_child + n.child_count) as usize].iter())
    }

    fn child_count(&self, parent: NodeId) -> usize {
        self.node(parent).child_count as usize
    }

    fn get_child_id(&self, parent: NodeId, index: usize) -> NodeId {
        NodeId::from(self.children[self.node(parent).first_child as usize + index] as usize)
    }
}

impl taffy::TraverseTree for Tree<'_> {}

impl taffy::LayoutPartialTree for Tree<'_> {
    type CoreContainerStyle<'b>
        = NodeStyle<'b>
    where
        Self: 'b;
    type CustomIdent = String;

    fn get_core_container_style(&self, id: NodeId) -> NodeStyle<'_> {
        NodeStyle(self.node(id))
    }

    fn set_unrounded_layout(&mut self, id: NodeId, layout: &Layout) {
        let slot = self.node(id).slot as usize;
        self.layouts[slot] = SlotLayout {
            x: layout.location.x,
            y: layout.location.y,
            w: layout.size.width,
            h: layout.size.height,
            content_w: layout.scrollable_overflow_rect.right,
            content_h: layout.scrollable_overflow_rect.bottom,
        };
    }

    fn compute_child_layout(&mut self, id: NodeId, inputs: LayoutInput) -> LayoutOutput {
        compute_cached_layout(self, id, inputs, |tree, id, inputs| {
            tree.stats.passes += 1;
            let slot = tree.node(id).slot as usize;
            if tree.stamps[slot] != tree.stamp {
                tree.stamps[slot] = tree.stamp;
                tree.stats.computed += 1;
            }
            let nodes = tree.nodes;
            let node = &nodes[usize::from(id)];
            let mut output = if node.display == DISPLAY_NONE {
                compute_hidden_layout(tree, id)
            } else if node.measure != 0 {
                compute_leaf_layout(inputs, &NodeStyle(node), |_, _| 0.0, |known, avail| {
                    tree.measure_leaf(usize::from(id), known, avail)
                })
            } else if node.display == DISPLAY_GRID {
                compute_grid_layout(tree, id, inputs)
            } else {
                compute_flexbox_layout(tree, id, inputs)
            };
            if inputs.run_mode == RunMode::PerformLayout {
                compute_oof_layout(tree, id, &mut output);
            }
            output
        })
    }
}

impl taffy::LayoutContainingBlock for Tree<'_> {
    type OofItemStyle<'b>
        = NodeStyle<'b>
    where
        Self: 'b;

    fn get_oof_item_style(&self, id: NodeId) -> NodeStyle<'_> {
        NodeStyle(self.node(id))
    }

    fn clear_hoisted_children(&mut self, id: NodeId) {
        let index = usize::from(id) as u32;
        self.hoisted.retain(|(i, _)| *i != index);
    }

    fn add_hoisted_children(&mut self, id: NodeId, hoisted: &[NodeId]) {
        let index = usize::from(id) as u32;
        match self.hoisted.iter_mut().find(|(i, _)| *i == index) {
            Some((_, list)) => list.extend_from_slice(hoisted),
            None => self.hoisted.push((index, hoisted.to_vec())),
        }
    }
}

impl CacheTree for Tree<'_> {
    fn cache_get(&mut self, id: NodeId, inputs: &LayoutInput) -> Option<LayoutOutput> {
        let slot = self.node(id).slot as usize;
        let hit = self.caches[slot].get(inputs);
        if hit.is_some() {
            self.stats.cache_hits += 1;
        }
        hit
    }

    fn cache_store(&mut self, id: NodeId, inputs: &LayoutInput, output: LayoutOutput) {
        let slot = self.node(id).slot as usize;
        self.caches[slot].store(inputs, output)
    }

    fn cache_clear(&mut self, id: NodeId) {
        let slot = self.node(id).slot as usize;
        self.caches[slot].clear();
    }
}

impl taffy::LayoutFlexboxContainer for Tree<'_> {
    type FlexboxContainerStyle<'b>
        = NodeStyle<'b>
    where
        Self: 'b;
    type FlexboxItemStyle<'b>
        = NodeStyle<'b>
    where
        Self: 'b;

    fn get_flexbox_container_style(&self, id: NodeId) -> NodeStyle<'_> {
        NodeStyle(self.node(id))
    }

    fn get_flexbox_child_style(&self, id: NodeId) -> NodeStyle<'_> {
        NodeStyle(self.node(id))
    }
}

impl taffy::LayoutGridContainer for Tree<'_> {
    type GridContainerStyle<'b>
        = &'b Style<String>
    where
        Self: 'b;
    type GridItemStyle<'b>
        = NodeStyle<'b>
    where
        Self: 'b;

    fn get_grid_container_style(&self, id: NodeId) -> &Style<String> {
        self.grid_style(id)
    }

    fn get_grid_child_style(&self, id: NodeId) -> NodeStyle<'_> {
        NodeStyle(self.node(id))
    }
}

// ---- Styles ----

impl Dim {
    fn dimension(self) -> Dimension {
        match self.unit {
            UNIT_PX => Dimension::length(self.value),
            UNIT_PERCENT => Dimension::percent(self.value),
            _ => Dimension::auto(),
        }
    }

    fn lpa(self) -> LengthPercentageAuto {
        match self.unit {
            UNIT_PX => LengthPercentageAuto::length(self.value),
            UNIT_PERCENT => LengthPercentageAuto::percent(self.value),
            _ => LengthPercentageAuto::auto(),
        }
    }
}

fn align_items(v: u8) -> Option<AlignItems> {
    Some(match v {
        ALIGN_START => AlignItems::START,
        ALIGN_END => AlignItems::END,
        ALIGN_FLEX_START => AlignItems::FLEX_START,
        ALIGN_FLEX_END => AlignItems::FLEX_END,
        ALIGN_CENTER => AlignItems::CENTER,
        ALIGN_BASELINE => AlignItems::BASELINE,
        ALIGN_STRETCH => AlignItems::STRETCH,
        _ => return None,
    })
}

fn align_content(v: u8) -> Option<AlignContent> {
    Some(match v {
        ALIGN_START => AlignContent::START,
        ALIGN_END => AlignContent::END,
        ALIGN_FLEX_START => AlignContent::FLEX_START,
        ALIGN_FLEX_END => AlignContent::FLEX_END,
        ALIGN_CENTER => AlignContent::CENTER,
        ALIGN_STRETCH => AlignContent::STRETCH,
        ALIGN_SPACE_BETWEEN => AlignContent::SPACE_BETWEEN,
        ALIGN_SPACE_AROUND => AlignContent::SPACE_AROUND,
        ALIGN_SPACE_EVENLY => AlignContent::SPACE_EVENLY,
        _ => return None,
    })
}

fn overflow(v: u8) -> Overflow {
    match v {
        1 => Overflow::Clip,
        2 => Overflow::Hidden,
        3 => Overflow::Scroll,
        _ => Overflow::Visible,
    }
}

fn placement(p: Placement) -> GridPlacement<String> {
    match p.kind {
        PLACE_LINE => line(p.value),
        PLACE_SPAN => span(p.value.max(1) as u16),
        _ => GridPlacement::Auto,
    }
}

fn min_track(t: TrackSize) -> MinTrackSizingFunction {
    match t.unit {
        TRACK_PX => MinTrackSizingFunction::length(t.value),
        TRACK_PERCENT => MinTrackSizingFunction::percent(t.value),
        TRACK_MIN_CONTENT => MinTrackSizingFunction::min_content(),
        TRACK_MAX_CONTENT => MinTrackSizingFunction::max_content(),
        _ => MinTrackSizingFunction::auto(), // fr and fit-content are not valid minimums
    }
}

fn max_track(t: TrackSize) -> MaxTrackSizingFunction {
    match t.unit {
        TRACK_PX => MaxTrackSizingFunction::length(t.value),
        TRACK_PERCENT => MaxTrackSizingFunction::percent(t.value),
        TRACK_FR => fr(t.value),
        TRACK_MIN_CONTENT => MaxTrackSizingFunction::min_content(),
        TRACK_MAX_CONTENT => MaxTrackSizingFunction::max_content(),
        TRACK_FIT_CONTENT => MaxTrackSizingFunction::fit_content_px(t.value),
        _ => MaxTrackSizingFunction::auto(),
    }
}

fn track_fn(t: &Track) -> TrackSizingFunction {
    TrackSizingFunction { min: min_track(t.min), max: max_track(t.max) }
}

fn track_range(tracks: &[Track], r: Tracks) -> &[Track] {
    if r.count == 0 {
        &[]
    } else {
        &tracks[r.first as usize..(r.first + r.count) as usize]
    }
}

fn template(tracks: &[Track], r: Tracks) -> Vec<GridTemplateComponent<String>> {
    track_range(tracks, r)
        .iter()
        .map(|t| {
            let count = match t.repeat {
                REPEAT_AUTO_FILL => RepetitionCount::AutoFill,
                REPEAT_AUTO_FIT => RepetitionCount::AutoFit,
                REPEAT_COUNT => RepetitionCount::Count(t.count.clamp(1, u16::MAX as u32) as u16),
                _ => return GridTemplateComponent::Single(track_fn(t)),
            };
            GridTemplateComponent::Repeat(GridTemplateRepetition {
                count,
                tracks: vec![track_fn(t)],
                line_names: Vec::new(),
            })
        })
        .collect()
}

fn to_grid_style(n: &Node, tracks: &[Track]) -> Style<String> {
    let s = NodeStyle(n);
    Style {
        display: Display::Grid,
        overflow: s.overflow(),
        position: s.position(),
        inset: s.inset(),
        size: s.size(),
        min_size: s.min_size(),
        max_size: s.max_size(),
        aspect_ratio: s.aspect_ratio(),
        margin: s.margin(),
        padding: s.padding(),
        border: s.border(),
        gap: FlexboxContainerStyle::gap(&s),
        align_items: align_items(n.align_items).unwrap_or(AlignItems::NORMAL),
        align_self: align_items(n.align_self),
        justify_items: align_items(n.justify_items).unwrap_or(AlignItems::NORMAL),
        justify_self: align_items(n.justify_self),
        align_content: align_content(n.align_content).unwrap_or(AlignContent::NORMAL),
        justify_content: align_content(n.justify_content).unwrap_or(AlignContent::NORMAL),
        grid_template_columns: template(tracks, n.grid_columns),
        grid_template_rows: template(tracks, n.grid_rows),
        grid_auto_columns: track_range(tracks, n.grid_auto_columns).iter().map(track_fn).collect(),
        grid_auto_rows: track_range(tracks, n.grid_auto_rows).iter().map(track_fn).collect(),
        grid_auto_flow: match n.grid_auto_flow {
            1 => GridAutoFlow::Column,
            2 => GridAutoFlow::RowDense,
            3 => GridAutoFlow::ColumnDense,
            _ => GridAutoFlow::Row,
        },
        grid_row: Line { start: placement(n.grid_row[0]), end: placement(n.grid_row[1]) },
        grid_column: Line { start: placement(n.grid_column[0]), end: placement(n.grid_column[1]) },
        flex_grow: n.flex_grow,
        flex_shrink: n.flex_shrink,
        flex_basis: n.flex_basis.dimension(),
        ..Style::default()
    }
}

/// A node's style, read in place.
#[derive(Clone, Copy)]
pub struct NodeStyle<'a>(&'a Node);

impl CoreStyle for NodeStyle<'_> {
    type CustomIdent = String;

    fn box_generation_mode(&self) -> BoxGenerationMode {
        if self.0.display == DISPLAY_NONE {
            BoxGenerationMode::None
        } else {
            BoxGenerationMode::Normal
        }
    }
    fn is_block(&self) -> bool {
        false
    }
    fn overflow(&self) -> Point<Overflow> {
        Point { x: overflow(self.0.overflow_x), y: overflow(self.0.overflow_y) }
    }
    fn position(&self) -> Position {
        if self.0.position == 1 {
            Position::Absolute
        } else {
            Position::Relative
        }
    }
    fn inset(&self) -> Rect<LengthPercentageAuto> {
        let e = &self.0.inset;
        Rect { left: e[0].lpa(), right: e[1].lpa(), top: e[2].lpa(), bottom: e[3].lpa() }
    }
    fn size(&self) -> Size<Dimension> {
        Size { width: self.0.size[0].dimension(), height: self.0.size[1].dimension() }
    }
    fn min_size(&self) -> Size<LengthPercentageAuto> {
        Size { width: self.0.min_size[0].lpa(), height: self.0.min_size[1].lpa() }
    }
    fn max_size(&self) -> Size<LengthPercentageAuto> {
        Size { width: self.0.max_size[0].lpa(), height: self.0.max_size[1].lpa() }
    }
    fn aspect_ratio(&self) -> Option<f32> {
        if self.0.aspect_ratio > 0.0 {
            Some(self.0.aspect_ratio)
        } else {
            None
        }
    }
    fn margin(&self) -> Rect<LengthPercentageAuto> {
        let e = &self.0.margin;
        Rect {
            left: LengthPercentageAuto::length(e[0]),
            right: LengthPercentageAuto::length(e[1]),
            top: LengthPercentageAuto::length(e[2]),
            bottom: LengthPercentageAuto::length(e[3]),
        }
    }
    fn padding(&self) -> Rect<LengthPercentage> {
        let e = &self.0.padding;
        Rect {
            left: LengthPercentage::length(e[0]),
            right: LengthPercentage::length(e[1]),
            top: LengthPercentage::length(e[2]),
            bottom: LengthPercentage::length(e[3]),
        }
    }
    fn border(&self) -> Rect<LengthPercentage> {
        let e = &self.0.border;
        Rect {
            left: LengthPercentage::length(e[0]),
            right: LengthPercentage::length(e[1]),
            top: LengthPercentage::length(e[2]),
            bottom: LengthPercentage::length(e[3]),
        }
    }
}

impl FlexboxContainerStyle for NodeStyle<'_> {
    fn flex_direction(&self) -> FlexDirection {
        if self.0.flex_direction == 1 {
            FlexDirection::Column
        } else {
            FlexDirection::Row
        }
    }
    fn flex_wrap(&self) -> FlexWrap {
        if self.0.flex_wrap == 1 {
            FlexWrap::Wrap
        } else {
            FlexWrap::NoWrap
        }
    }
    fn gap(&self) -> Size<LengthPercentage> {
        Size { width: LengthPercentage::length(self.0.gap[0]), height: LengthPercentage::length(self.0.gap[1]) }
    }
    fn align_content(&self) -> AlignContent {
        align_content(self.0.align_content).unwrap_or(AlignContent::NORMAL)
    }
    fn align_items(&self) -> AlignItems {
        align_items(self.0.align_items).unwrap_or(AlignItems::NORMAL)
    }
    fn justify_content(&self) -> JustifyContent {
        align_content(self.0.justify_content).unwrap_or(AlignContent::NORMAL)
    }
}

impl FlexboxItemStyle for NodeStyle<'_> {
    fn flex_basis(&self) -> Dimension {
        self.0.flex_basis.dimension()
    }
    fn flex_grow(&self) -> f32 {
        self.0.flex_grow
    }
    fn flex_shrink(&self) -> f32 {
        self.0.flex_shrink
    }
    fn align_self(&self) -> Option<AlignSelf> {
        align_items(self.0.align_self)
    }
}

impl GridItemStyle for NodeStyle<'_> {
    fn grid_row(&self) -> Line<GridPlacement<String>> {
        Line { start: placement(self.0.grid_row[0]), end: placement(self.0.grid_row[1]) }
    }
    fn grid_column(&self) -> Line<GridPlacement<String>> {
        Line { start: placement(self.0.grid_column[0]), end: placement(self.0.grid_column[1]) }
    }
    fn align_self(&self) -> Option<AlignSelf> {
        align_items(self.0.align_self)
    }
    fn justify_self(&self) -> Option<AlignSelf> {
        align_items(self.0.justify_self)
    }
}

impl OofItemStyle for NodeStyle<'_> {
    fn align_self(&self) -> Option<AlignSelf> {
        align_items(self.0.align_self)
    }
    fn justify_self(&self) -> Option<AlignSelf> {
        align_items(self.0.justify_self)
    }
    fn grid_row(&self) -> Line<GridPlacement<String>> {
        GridItemStyle::grid_row(self)
    }
    fn grid_column(&self) -> Line<GridPlacement<String>> {
        GridItemStyle::grid_column(self)
    }
}

#[cfg(test)]
mod tests;
