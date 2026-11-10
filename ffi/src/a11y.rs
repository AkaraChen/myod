//! AccessKit behind a C ABI (ARCHITECTURE.md, "API design → 17").
//!
//! Odin hands over the semantic tree each presented frame as a flat array of nodes (ids are widget
//! ids). The adapter turns it into an AccessKit tree, exposes it through the window's NSView with
//! `accesskit_macos::SubclassingAdapter`, and sends actions from assistive technologies back through
//! a callback, where they enter the input phase as synthetic events.
//!
//! Only the macOS adapter exists so far; Linux (AT-SPI) joins with the Linux port.

#[cfg(target_os = "macos")]
pub use macos::*;

#[cfg(target_os = "macos")]
mod macos {
    use accesskit::{
        Action, ActionHandler, ActionRequest, ActivationHandler, Live, Node, NodeId, Role, Toggled,
        TextDirection, TextPosition, TextSelection, TreeId, TreeInfo, TreeUpdate,
    };
    use accesskit_macos::SubclassingAdapter;
    use std::ffi::c_void;
    use std::sync::{Arc, Mutex};

    /// Mirrors `core.A11y_Node` in Odin (ffi/a11y.odin). `parent` indexes the same array, -1 for a
    /// root. Text is UTF-8 and not NUL-terminated.
    #[repr(C)]
    pub struct MyodAxNode {
        pub id: u64,
        pub parent: i64,
        pub role: u32,
        pub flags: u32,
        pub actions: u32,
        pub row_count: i32,
        pub row_index: i32,
        pub column_count: i32,
        pub column_index: i32,
        pub x: f64,
        pub y: f64,
        pub w: f64,
        pub h: f64,
        pub name: *const u8,
        pub name_len: usize,
        pub value: *const u8,
        pub value_len: usize,
        /// The text run this node exposes (screen readers read it by character, word and line):
        /// the text, the UTF-8 byte length of each character, the character indices where words
        /// start, and each character's x and advance width in logical pixels relative to the
        /// node's rect. `sel_a` and `sel_b` are byte offsets into `text`, or -1.
        pub text: *const u8,
        pub text_len: usize,
        pub char_lengths: *const u8,
        pub char_lengths_len: usize,
        pub word_starts: *const u8,
        pub word_starts_len: usize,
        pub char_positions: *const f32,
        pub char_positions_len: usize,
        pub char_widths: *const f32,
        pub char_widths_len: usize,
        pub sel_a: i32,
        pub sel_b: i32,
    }

    /// What the adapter needs to build an update: owned copies, made when Odin calls
    /// `myod_a11y_update`.
    #[derive(Clone, Default)]
    struct Snapshot {
        nodes: Vec<Owned>,
        focus: u64,
        width: f64,
        height: f64,
    }

    #[derive(Clone)]
    struct Owned {
        id: u64,
        parent: i64,
        role: u32,
        flags: u32,
        actions: u32,
        row_count: i32,
        row_index: i32,
        column_count: i32,
        column_index: i32,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        name: String,
        value: String,
        text: String,
        char_lengths: Vec<u8>,
        word_starts: Vec<u8>,
        char_positions: Vec<f32>,
        char_widths: Vec<f32>,
        sel_a: i32,
        sel_b: i32,
    }

    // AccessKit's root: not a widget id, so it cannot collide with one.
    const ROOT: NodeId = NodeId(u64::MAX);

    const ACTION_CLICK: u32 = 1;
    const ACTION_FOCUS: u32 = 2;

    type ActionFn = extern "C" fn(u64, u32);

    struct Handler {
        cb: ActionFn,
    }

    impl ActionHandler for Handler {
        fn do_action(&mut self, request: ActionRequest) {
            let action = match request.action {
                Action::Click => ACTION_CLICK,
                Action::Focus => ACTION_FOCUS,
                _ => return,
            };
            (self.cb)(request.target_node.0, action);
        }
    }

    struct Activation {
        shared: Arc<Mutex<Snapshot>>,
    }

    impl ActivationHandler for Activation {
        fn request_initial_tree(&mut self) -> Option<TreeUpdate> {
            let snapshot = self.shared.lock().unwrap().clone();
            Some(build(snapshot))
        }
    }

    pub struct A11y {
        adapter: SubclassingAdapter,
        shared: Arc<Mutex<Snapshot>>,
    }

    fn role_of(r: u32) -> Role {
        // Mirrors core.Role.
        match r {
            1 => Role::GenericContainer,
            2 => Role::Button,
            3 => Role::Label,
            4 => Role::Image,
            5 => Role::TextInput,
            6 => Role::CheckBox,
            7 => Role::RadioButton,
            8 => Role::Slider,
            9 => Role::ProgressIndicator,
            10 => Role::Tab,
            11 => Role::TabPanel,
            12 => Role::List,
            13 => Role::ListItem,
            14 => Role::Menu,
            15 => Role::MenuItem,
            16 => Role::Dialog,
            17 => Role::Table,
            18 => Role::Row,
            19 => Role::Cell,
            20 => Role::MenuBar,
            21 => Role::ListBox,
            22 => Role::ListBoxOption,
            23 => Role::AlertDialog,
            24 => Role::Navigation,
            25 => Role::Status,
            _ => Role::Unknown,
        }
    }

    /// Copies a text run's per-character byte lengths or word starts out of the call's arrays.
    fn copy_bytes(p: *const u8, len: usize) -> Vec<u8> {
        if len == 0 || p.is_null() {
            return Vec::new();
        }
        unsafe { std::slice::from_raw_parts(p, len) }.to_vec()
    }

    /// Copies a text run's per-character positions or widths.
    fn copy_floats(p: *const f32, len: usize) -> Vec<f32> {
        if len == 0 || p.is_null() {
            return Vec::new();
        }
        unsafe { std::slice::from_raw_parts(p, len) }.to_vec()
    }

    /// A text run's NodeId: derived from its widget's id, so it is stable across frames. Widget ids
    /// are 64-bit hashes already, so a mixed value collides with one with negligible probability.
    fn run_id(parent: u64) -> u64 {
        let mut z = parent ^ 0x9E37_79B9_7F4A_7C15;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// The character index of a byte offset in a text run (AccessKit counts characters, not bytes).
    fn char_index(text: &str, byte: i32) -> usize {
        if byte <= 0 {
            return 0;
        }
        let mut b = (byte as usize).min(text.len());
        while b > 0 && !text.is_char_boundary(b) {
            b -= 1;
        }
        text[..b].chars().count()
    }

    /// Builds a full TreeUpdate. Sending every node on every frame is cheap at our sizes, and the
    /// adapter computes the differences before notifying the platform.
    fn build(s: Snapshot) -> TreeUpdate {
        let mut children: Vec<Vec<NodeId>> = vec![Vec::new(); s.nodes.len()];
        let mut roots: Vec<NodeId> = Vec::new();
        for n in &s.nodes {
            if n.parent >= 0 && (n.parent as usize) < s.nodes.len() {
                children[n.parent as usize].push(NodeId(n.id));
            } else {
                roots.push(NodeId(n.id));
            }
        }

        let mut nodes: Vec<(NodeId, Node)> = Vec::with_capacity(s.nodes.len() + 1);
        for (i, n) in s.nodes.iter().enumerate() {
            let mut node = Node::new(role_of(n.role));
            if !n.name.is_empty() {
                node.set_label(n.name.clone());
            }
            if !n.value.is_empty() {
                node.set_value(n.value.clone());
            }
            node.set_bounds(accesskit::Rect {
                x0: n.x,
                y0: n.y,
                x1: n.x + n.w,
                y1: n.y + n.h,
            });
            if n.row_count >= 0 {
                node.set_row_count(n.row_count as usize);
            }
            if n.row_index >= 0 {
                node.set_row_index(n.row_index as usize);
            }
            if n.column_count >= 0 {
                node.set_column_count(n.column_count as usize);
            }
            if n.column_index >= 0 {
                node.set_column_index(n.column_index as usize);
            }
            // A11y_Flag: Disabled, Focused, Focus_Visible, Selected, Checked, Expanded, Pressed,
            // Read_Only, Live.
            let disabled = n.flags & 1 != 0;
            if disabled {
                node.set_disabled();
            }
            if n.flags & 8 != 0 {
                node.set_selected(true);
            }
            if n.flags & 16 != 0 {
                node.set_toggled(Toggled::True);
            }
            if n.flags & 32 != 0 {
                node.set_expanded(true);
            }
            if n.flags & 64 != 0 {
                node.set_toggled(Toggled::True);
            }
            if n.flags & 128 != 0 {
                node.set_read_only();
            }
            if n.flags & 256 != 0 {
                node.set_live(Live::Polite);
            }
            if n.actions & ACTION_CLICK != 0 {
                node.add_action(Action::Click);
            }
            if n.actions & ACTION_FOCUS != 0 {
                node.add_action(Action::Focus);
            }
            // A text run, so screen readers can read this node's text by character, word and line,
            // and follow the caret and the selection. Its node id is derived from the widget's.
            let mut run = None;
            if !n.char_lengths.is_empty() && !n.text.is_empty() {
                let rid = NodeId(run_id(n.id));
                let mut text_run = Node::new(Role::TextRun);
                text_run.set_value(n.text.clone());
                text_run.set_bounds(accesskit::Rect {
                    x0: n.x,
                    y0: n.y,
                    x1: n.x + n.w,
                    y1: n.y + n.h,
                });
                // The layout is horizontal and left to right; AccessKit needs it to turn a point
                // inside the run into a character index.
                text_run.set_text_direction(TextDirection::LeftToRight);
                text_run.set_character_lengths(n.char_lengths.clone());
                if !n.word_starts.is_empty() {
                    text_run.set_word_starts(n.word_starts.clone());
                }
                if n.char_positions.len() == n.char_lengths.len() {
                    text_run.set_character_positions(n.char_positions.clone());
                }
                if n.char_widths.len() == n.char_lengths.len() {
                    text_run.set_character_widths(n.char_widths.clone());
                }
                if n.sel_a >= 0 && n.sel_b >= 0 {
                    node.set_text_selection(TextSelection {
                        anchor: TextPosition {
                            node: rid,
                            character_index: char_index(&n.text, n.sel_a),
                        },
                        focus: TextPosition {
                            node: rid,
                            character_index: char_index(&n.text, n.sel_b),
                        },
                    });
                }
                children[i].push(rid);
                run = Some((rid, text_run));
            }
            if !children[i].is_empty() {
                node.set_children(children[i].clone());
            }
            nodes.push((NodeId(n.id), node));
            if let Some(run) = run {
                nodes.push(run);
            }
        }

        let mut root = Node::new(Role::Window);
        root.set_label("myod");
        root.set_bounds(accesskit::Rect {
            x0: 0.0,
            y0: 0.0,
            x1: s.width,
            y1: s.height,
        });
        root.set_children(roots);
        nodes.push((ROOT, root));

        let focus = if s.focus != 0 {
            NodeId(s.focus)
        } else {
            ROOT
        };
        let mut info = TreeInfo::new(ROOT);
        info.toolkit_name = Some("myod".into());
        TreeUpdate {
            nodes,
            tree: Some(info),
            tree_id: TreeId::ROOT,
            focus,
        }
    }

    /// Creates the adapter on an NSWindow and starts accepting updates. Must be called on the main
    /// thread, before anything observes the view.
    ///
    /// # Safety
    /// `ns_window` must be a valid `NSWindow*`.
    #[no_mangle]
    pub unsafe extern "C" fn myod_a11y_init(
        ns_window: *mut c_void,
        cb: Option<ActionFn>,
    ) -> *mut A11y {
        let Some(cb) = cb else {
            return std::ptr::null_mut();
        };
        let shared = Arc::new(Mutex::new(Snapshot::default()));
        let adapter = SubclassingAdapter::for_window(
            ns_window,
            Activation { shared: shared.clone() },
            Handler { cb },
        );
        Box::into_raw(Box::new(A11y { adapter, shared }))
    }

    /// Publishes this frame's tree. `nodes` are in physical pixels, y down from the view's top-left.
    ///
    /// # Safety
    /// `a` must come from `myod_a11y_init`; `nodes` must point at `count` valid entries.
    #[no_mangle]
    pub unsafe extern "C" fn myod_a11y_update(
        a: *mut A11y,
        nodes: *const MyodAxNode,
        count: usize,
        focus: u64,
        width: f64,
        height: f64,
    ) {
        if a.is_null() {
            return;
        }
        let a = unsafe { &mut *a };
        let entries = unsafe { std::slice::from_raw_parts(nodes, count) };
        let mut owned = Vec::with_capacity(count);
        for n in entries {
            let name = if n.name_len > 0 && !n.name.is_null() {
                let bytes = unsafe { std::slice::from_raw_parts(n.name, n.name_len) };
                String::from_utf8_lossy(bytes).into_owned()
            } else {
                String::new()
            };
            let value = if n.value_len > 0 && !n.value.is_null() {
                let bytes = unsafe { std::slice::from_raw_parts(n.value, n.value_len) };
                String::from_utf8_lossy(bytes).into_owned()
            } else {
                String::new()
            };
            let text = if n.text_len > 0 && !n.text.is_null() {
                let bytes = unsafe { std::slice::from_raw_parts(n.text, n.text_len) };
                String::from_utf8_lossy(bytes).into_owned()
            } else {
                String::new()
            };
            let char_lengths = copy_bytes(n.char_lengths, n.char_lengths_len);
            let word_starts = copy_bytes(n.word_starts, n.word_starts_len);
            let char_positions = copy_floats(n.char_positions, n.char_positions_len);
            let char_widths = copy_floats(n.char_widths, n.char_widths_len);
            owned.push(Owned {
                id: n.id,
                parent: n.parent,
                role: n.role,
                flags: n.flags,
                actions: n.actions,
                row_count: n.row_count,
                row_index: n.row_index,
                column_count: n.column_count,
                column_index: n.column_index,
                x: n.x,
                y: n.y,
                w: n.w,
                h: n.h,
                name,
                value,
                text,
                char_lengths,
                word_starts,
                char_positions,
                char_widths,
                sel_a: n.sel_a,
                sel_b: n.sel_b,
            });
        }
        let snapshot = Snapshot {
            nodes: owned,
            focus,
            width,
            height,
        };
        *a.shared.lock().unwrap() = snapshot;
        let shared = a.shared.clone();
        let adapter = &mut a.adapter;
        if let Some(events) = adapter.update_if_active(|| build(shared.lock().unwrap().clone())) {
            events.raise();
        }
    }

    /// Tells the adapter whether the window has keyboard focus, which decides which AX element gets
    /// the focus notifications.
    ///
    /// # Safety
    /// `a` must come from `myod_a11y_init`.
    #[no_mangle]
    pub unsafe extern "C" fn myod_a11y_set_focus(a: *mut A11y, focused: bool) {
        if a.is_null() {
            return;
        }
        let a = unsafe { &mut *a };
        if let Some(events) = a.adapter.update_view_focus_state(focused) {
            events.raise();
        }
    }

    /// # Safety
    /// `a` must come from `myod_a11y_init` and not be used afterwards.
    #[no_mangle]
    pub unsafe extern "C" fn myod_a11y_destroy(a: *mut A11y) {
        if !a.is_null() {
            drop(unsafe { Box::from_raw(a) });
        }
    }

    // ---- Tests ----
    //
    // Read back the tree the way a screen reader does: through AccessKit's consumer, which is what
    // the macOS adapter answers AXNumberOfCharacters, AXStringForRange, AXSelectedTextRange and the
    // word and line navigation with.
    #[cfg(test)]
    mod tests {
        use super::*;
        use accesskit::Point;
        use accesskit_consumer::{NodeRef, Tree};

        /// One widget with a text run and no parent, as Odin publishes a paragraph or a field. Each
        /// character is `step` pixels wide, starting at the run's left edge.
        #[allow(clippy::too_many_arguments)]
        fn node(
            id: u64,
            role: u32,
            value: &str,
            text: &str,
            lengths: &[u8],
            words: &[u8],
            step: f32,
            sel: (i32, i32),
        ) -> Owned {
            Owned {
                id,
                parent: -1,
                role,
                flags: 0,
                actions: 0,
                row_count: -1,
                row_index: -1,
                column_count: -1,
                column_index: -1,
                x: 100.0,
                y: 200.0,
                w: 300.0,
                h: 20.0,
                name: String::new(),
                value: value.into(),
                text: text.into(),
                char_lengths: lengths.to_vec(),
                word_starts: words.to_vec(),
                char_positions: (0..lengths.len()).map(|i| i as f32 * step).collect(),
                char_widths: vec![step; lengths.len()],
                sel_a: sel.0,
                sel_b: sel.1,
            }
        }

        fn tree(nodes: Vec<Owned>) -> Tree {
            Tree::new(
                build(Snapshot {
                    nodes,
                    focus: 0,
                    width: 800.0,
                    height: 600.0,
                }),
                true,
            )
        }

        fn at<'a>(tree: &'a Tree, id: u64) -> NodeRef<'a> {
            tree.state()
                .node_by_tree_local_id(NodeId(id), TreeId::ROOT)
                .unwrap()
        }

        #[test]
        fn a_text_run_is_read_by_character_word_and_line() {
            let t = tree(vec![node(
                1,
                3,
                "",
                "Hello world",
                &[1; 11],
                &[0, 6],
                8.0,
                (-1, -1),
            )]);
            let n = at(&t, 1);
            assert_eq!(n.role(), Role::Label);
            assert!(n.supports_text_ranges());
            assert_eq!(n.document_range().text(), "Hello world");
            assert_eq!(n.document_start().to_global_usv_index(), 0);
            assert_eq!(n.document_end().to_global_usv_index(), 11);
            // Both words start where UAX #29 says they do.
            assert!(n
                .text_position_from_global_usv_index(0)
                .unwrap()
                .is_word_start());
            assert!(!n
                .text_position_from_global_usv_index(3)
                .unwrap()
                .is_word_start());
            assert!(n
                .text_position_from_global_usv_index(6)
                .unwrap()
                .is_word_start());
            // One line, read whole.
            assert_eq!(n.line_range_from_index(0).unwrap().text(), "Hello world");
            assert!(n.line_range_from_index(1).is_none());
            // A point 9 px into the run is inside the second character; that needs the run's
            // direction to be known.
            let run = n.children().find(|c| c.role() == Role::TextRun).unwrap();
            assert_eq!(run.text_direction(), Some(TextDirection::LeftToRight));
            let pos = n.text_position_at_point(Point::new(109.0, 205.0));
            assert_eq!(pos.to_global_usv_index(), 1);
        }

        #[test]
        fn a_selection_is_read_back_in_characters() {
            let t = tree(vec![node(
                7,
                3,
                "",
                "Hello world",
                &[1; 11],
                &[0, 6],
                8.0,
                (0, 5),
            )]);
            let n = at(&t, 7);
            let sel = n.text_selection().unwrap();
            assert_eq!(sel.text(), "Hello");
            assert_eq!(sel.start().to_global_usv_index(), 0);
            assert_eq!(sel.end().to_global_usv_index(), 5);
        }

        #[test]
        fn a_caret_is_exposed_as_a_degenerate_selection() {
            let value = "bad@example.com";
            let t = tree(vec![node(9, 5, value, value, &[1; 15], &[0], 8.0, (3, 3))]);
            let n = at(&t, 9);
            assert!(n.is_text_input());
            assert!(n.supports_text_ranges());
            let sel = n.text_selection().unwrap();
            assert!(sel.is_degenerate());
            assert_eq!(sel.text(), "");
            assert_eq!(sel.start().to_global_usv_index(), 3);
        }

        #[test]
        fn multibyte_text_counts_characters_not_bytes() {
            let s = "中文段落测试";
            let t = tree(vec![node(11, 3, "", s, &[3; 6], &[0], 12.0, (-1, -1))]);
            let n = at(&t, 11);
            assert_eq!(n.document_end().to_global_usv_index(), 6);
            assert_eq!(n.document_range().text(), s);
            assert!(n.text_position_from_global_usv_index(5).is_some());
            // A selection that ends after two characters, given in bytes, reads back as two
            // characters.
            let t2 = tree(vec![node(12, 3, "", s, &[3; 6], &[0], 12.0, (0, 6))]);
            let n2 = at(&t2, 12);
            assert_eq!(n2.text_selection().unwrap().text(), "中文");
        }

        #[test]
        fn a_widget_without_a_run_has_no_text_ranges() {
            let mut n = node(13, 3, "", "plain", &[], &[], 8.0, (-1, -1));
            n.text = String::new();
            let t = tree(vec![n]);
            assert!(!at(&t, 13).supports_text_ranges());
        }
    }
}
