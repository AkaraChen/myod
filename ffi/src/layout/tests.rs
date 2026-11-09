use super::*;

const PX: u32 = UNIT_PX;

fn px(v: f32) -> Dim {
    Dim { value: v, unit: PX }
}

fn node(slot: u32) -> Node {
    Node { slot, flex_shrink: 1.0, aspect_ratio: f32::NAN, ..Node::default() }
}

struct Built {
    nodes: Vec<Node>,
    children: Vec<u32>,
    tracks: Vec<Track>,
}

impl Built {
    fn new() -> Self {
        Built { nodes: Vec::new(), children: Vec::new(), tracks: Vec::new() }
    }
    fn add(&mut self, n: Node) -> u32 {
        let slot = self.nodes.len() as u32;
        self.nodes.push(Node { slot, ..n });
        slot
    }
    fn set_children(&mut self, parent: u32, kids: &[u32]) {
        self.nodes[parent as usize].first_child = self.children.len() as u32;
        self.nodes[parent as usize].child_count = kids.len() as u32;
        self.children.extend_from_slice(kids);
    }
}

extern "C" fn measure_text(_user: *mut c_void, _node: u32, known_w: f32, known_h: f32, avail_w: f32, _avail_h: f32, out: *mut f32) {
    // A 300px-wide "paragraph" of 20px lines, with 60px words.
    let width = if !known_w.is_nan() {
        known_w
    } else if avail_w == f32::INFINITY {
        300.0
    } else if avail_w == f32::NEG_INFINITY {
        60.0
    } else {
        avail_w.clamp(60.0, 300.0)
    };
    let lines = (300.0 / width).ceil();
    unsafe {
        *out = width;
        *out.add(1) = if known_h.is_nan() { lines * 20.0 } else { known_h };
    }
}

fn run(ctx: *mut Ctx, b: &Built, w: f32, h: f32) -> Stats {
    let input = Input {
        nodes: b.nodes.as_ptr(),
        children: b.children.as_ptr(),
        tracks: b.tracks.as_ptr(),
        user: std::ptr::null_mut(),
        measure: Some(measure_text),
        node_count: b.nodes.len() as u32,
        children_count: b.children.len() as u32,
        track_count: b.tracks.len() as u32,
        root: 0,
        width: w,
        height: h,
    };
    let mut stats = Stats::default();
    unsafe {
        myod_layout_reserve(ctx, b.nodes.len() as u32);
        myod_layout_compute(ctx, &input, &mut stats);
    }
    stats
}

fn layout(ctx: *mut Ctx, slot: u32) -> SlotLayout {
    unsafe { *myod_layout_results(ctx).add(slot as usize) }
}

#[test]
fn row_with_fixed_and_growing_children() {
    let mut b = Built::new();
    let root = b.add(Node { size: [px(1000.0), px(600.0)], ..node(0) });
    let left = b.add(Node { size: [px(200.0), Dim::default()], flex_shrink: 0.0, ..node(0) });
    let mid = b.add(Node { flex_grow: 1.0, flex_basis: px(0.0), ..node(0) });
    let right = b.add(Node { size: [px(100.0), Dim::default()], flex_shrink: 0.0, ..node(0) });
    b.set_children(root, &[left, mid, right]);
    let ctx = myod_layout_new();
    run(ctx, &b, 1000.0, 600.0);
    assert_eq!(layout(ctx, mid), SlotLayout { x: 200.0, y: 0.0, w: 700.0, h: 600.0, content_w: 0.0, content_h: 0.0 });
    assert_eq!(layout(ctx, right).x, 900.0);
    unsafe { myod_layout_free(ctx) };
}

#[test]
fn grid_auto_fill_minmax() {
    let mut b = Built::new();
    b.tracks.push(Track {
        min: TrackSize { value: 240.0, unit: TRACK_PX },
        max: TrackSize { value: 1.0, unit: TRACK_FR },
        repeat: REPEAT_AUTO_FILL,
        count: 0,
    });
    let root = b.add(Node {
        display: DISPLAY_GRID,
        size: [px(1000.0), Dim::default()],
        gap: [16.0, 16.0],
        grid_columns: Tracks { first: 0, count: 1 },
        ..node(0)
    });
    let kids: Vec<u32> = (0..7).map(|_| b.add(Node { size: [Dim::default(), px(50.0)], ..node(0) })).collect();
    b.set_children(root, &kids);
    let ctx = myod_layout_new();
    run(ctx, &b, 1000.0, f32::NAN);
    // floor((1000 + 16) / (240 + 16)) = 3 columns of (1000 - 32) / 3.
    let w = (1000.0 - 32.0) / 3.0;
    assert!((layout(ctx, kids[0]).w - w).abs() < 0.01);
    assert!((layout(ctx, kids[1]).x - (w + 16.0)).abs() < 0.01);
    assert_eq!(layout(ctx, kids[3]).y, 66.0); // second row
    assert_eq!(layout(ctx, root).h, 3.0 * 50.0 + 2.0 * 16.0);
    // Narrower: two columns.
    unsafe { myod_layout_clear(ctx, root) };
    b.nodes[root as usize].size[0] = px(600.0);
    run(ctx, &b, 600.0, f32::NAN);
    assert_eq!(layout(ctx, kids[2]).y, 66.0);
    unsafe { myod_layout_free(ctx) };
}

#[test]
fn measured_text_wraps_and_cache_skips_unchanged_subtrees() {
    let mut b = Built::new();
    let root = b.add(Node { flex_direction: 1, size: [px(1000.0), Dim::default()], ..node(0) });
    let row_a = b.add(node(0));
    let text_a = b.add(Node { measure: 1, ..node(0) });
    let row_b = b.add(Node { size: [px(150.0), Dim::default()], ..node(0) });
    let text_b = b.add(Node { measure: 1, ..node(0) });
    b.set_children(root, &[row_a, row_b]);
    b.set_children(row_a, &[text_a]);
    b.set_children(row_b, &[text_b]);
    let ctx = myod_layout_new();
    let first = run(ctx, &b, 1000.0, f32::NAN);
    assert_eq!(layout(ctx, text_a).w, 300.0);
    assert_eq!(layout(ctx, text_a).h, 20.0);
    assert_eq!(layout(ctx, text_b).w, 150.0); // wraps to the 150px row: two lines
    assert_eq!(layout(ctx, text_b).h, 40.0);
    assert_eq!(layout(ctx, row_b).y, 20.0);
    assert!(first.computed == 5 && first.measured > 0);

    // Nothing changed: the root is answered from its cache.
    let again = run(ctx, &b, 1000.0, f32::NAN);
    assert_eq!(again.computed, 0);
    assert_eq!(again.measured, 0);

    // row_b's subtree changed: only it and its ancestors are laid out again.
    b.nodes[row_b as usize].size[0] = px(100.0);
    unsafe {
        myod_layout_clear(ctx, row_b);
        myod_layout_clear(ctx, text_b);
        myod_layout_clear(ctx, root);
    }
    let changed = run(ctx, &b, 1000.0, f32::NAN);
    assert_eq!(layout(ctx, text_b).h, 60.0);
    assert_eq!(layout(ctx, text_a).w, 300.0);
    assert!(changed.computed <= 4, "computed {}", changed.computed); // root, row_b, text_b (+ row_a re-measured)
    unsafe { myod_layout_free(ctx) };
}
