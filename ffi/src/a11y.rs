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
        Action, ActionHandler, ActionRequest, ActivationHandler, Node, NodeId, Role, TreeId,
        TreeInfo, TreeUpdate,
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
        pub x: f64,
        pub y: f64,
        pub w: f64,
        pub h: f64,
        pub name: *const u8,
        pub name_len: usize,
        pub value: *const u8,
        pub value_len: usize,
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
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        name: String,
        value: String,
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
            _ => Role::Unknown,
        }
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
            if !children[i].is_empty() {
                node.set_children(children[i].clone());
            }
            // A11y_Flag: Disabled, Focused, Focus_Visible, Selected, Checked, Expanded, Pressed,
            // Read_Only.
            let disabled = n.flags & 1 != 0;
            if disabled {
                node.set_disabled();
            }
            if n.actions & ACTION_CLICK != 0 {
                node.add_action(Action::Click);
            }
            if n.actions & ACTION_FOCUS != 0 {
                node.add_action(Action::Focus);
            }
            nodes.push((NodeId(n.id), node));
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
            owned.push(Owned {
                id: n.id,
                parent: n.parent,
                role: n.role,
                flags: n.flags,
                actions: n.actions,
                x: n.x,
                y: n.y,
                w: n.w,
                h: n.h,
                name,
                value,
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
}
