# myod architecture

myod's technology choices, API design, build, rendering and testing. For visual specs see [DESIGN.md](DESIGN.md); for goals and milestones see [ROADMAP.md](ROADMAP.md).

## Contents

- [Technology choices](#technology-choices)
- [API design](#api-design)
- [Build and dependencies](#build-and-dependencies)
- [Frame tree and performance](#frame-tree-and-performance)
- [Rendering backend](#rendering-backend)
- [Testing](#testing)
- [Module layout](#module-layout)

---

## Technology choices

| Area | Choice | Notes |
| --- | --- | --- |
| Graphics API | wgpu (`vendor:wgpu`) | Metal on Mac, D3D12 on Win, Vulkan on Linux |
| Window / input / IME | SDL3 (`vendor:sdl3`) | IME support is far better than GLFW's |
| Text backend | **Copy Ghostty's default backends** (see the table below) | Best look on each platform; the cost is that the same text may measure slightly differently across platforms |
| Line breaking and grapheme clusters | libunibreak (zlib license) | UAX #14 line breaking, UAX #29 grapheme clusters |
| Accessibility | [AccessKit](https://github.com/AccessKit/accesskit) (Rust, used through its C interface) | Connects to NSAccessibility on macOS and AT-SPI on Linux; UI Automation on Windows later |
| SVG parsing and rasterization | nanosvg (`nanosvg.h` + `nanosvgrast.h`) | Single-header C library; needs a very small Odin binding |
| Icon library | Phosphor Icons (MIT) | `#load` embeds only the SVGs in use, at compile time |
| App architecture | Elm architecture: State / Msg / update / view, driven by the library-provided `ui.Store` | See "API design" |
| Widget API | Controlled widgets, all returning `Response`; containers close automatically via `@(deferred_out)` | See "API design" |
| Theme | Tokens only: one `Theme` struct that is replaced as a whole | No per-widget style overrides before 1.0 |
| Layout | [Taffy](https://github.com/dioxuslabs/taffy) (Rust): one engine implements Flexbox, CSS Grid and Block | The official C binding is not finished yet. Our own thin Rust wrapper (`ffi/`) runs Taffy's low-level tree traits directly on myod's node array and exports a C ABI; it is compiled into a static library per platform (building it needs a Rust toolchain, using it does not). Not Clay: it only has flex, and flex and grid must nest and measure each other within the same engine |
| Charts | Build nanosvg shape structures directly in code, then rasterize them into a separate texture | No SVG string concatenation; text is drawn separately by the text system; no animation for now |

**Text backends** (matching Ghostty's default backend on each platform):

| Platform | Font discovery | Rasterization | Shaping | Text alpha blending |
| --- | --- | --- | --- | --- |
| macOS | CoreText | CoreText | CoreText | Native (Display P3) |
| Linux | Fontconfig | FreeType | HarfBuzz | `linear-corrected` |
| Windows | Scan the system font directory (may switch to DirectWrite later) | FreeType | HarfBuzz | `linear-corrected` |

- FreeType has hinting on by default, using the light mode of the autohinter. The default font, AKR DWG SC NFM (大弯勾, "DWG"), ships with its hinting stripped
- Shared by all platforms: sprite glyphs (box drawing, blocks, braille, Powerline), the shaping cache, and fast measurement on the 2:1 grid
- **Cross-platform measurement differences**: macOS shapes with CoreText while Linux and Windows use HarfBuzz, so the same text may have slightly different widths. Logic tests avoid this by always using the FreeType + HarfBuzz backend (see "Testing"); only visual screenshot tests need per-platform baselines

---

## API design

For full usage see `examples/counter`, `examples/todomvc`, `examples/download`.

### Core idea: put complexity in plain sight on purpose

React's `useState` / `useEffect` are too convenient: it is easy to add one more state or one more side effect on a whim, and complexity quietly scatters across components. Here we go the other way and use the **Elm architecture**:

- **Adding a state**: it must go into `State`
- **Adding a state transition**: you must add a variant to `Msg` and handle it in `update`; `switch` requires exhaustiveness by default, so a missed case is a **compile error**
- **Adding a side effect**: only possible in `update`, through `fx`

The formal verbosity is intentional: it forces people and agents to think about how to break down the state machine.

### 1. The four parts of an app

```odin
State :: struct { count: int }                  // state

Increment :: struct {}                           // messages: every possible state transition
Reset     :: struct {}
Msg :: union { Increment, Reset }

update :: proc(s: ^State, msg: Msg, fx: ^ui.Effects(Msg)) {   // the only place that modifies state
    switch _ in msg {
    case Increment: s.count += 1
    case Reset:     s.count = 0
    }
}

view :: proc(s: State, d: ui.Dispatch(Msg)) {   // receives state by value, read-only
    if ui.button("加一").clicked do ui.dispatch(d, Increment{})
}

main :: proc() {
    window := ui.open_window({title = "计数器", size = {320, 200}})
    defer ui.close_window(&window)

    store: ui.Store(State, Msg)
    ui.store_init(&store, &window, State{}, update)
    defer ui.store_destroy(&store)

    for ui.next_frame(&window) {
        view(store.state, ui.dispatcher(&store))
    }
}
```

- **How to write messages**: one type per variant. A variant with a single value uses `distinct` (`Toggle :: distinct int`, constructed as `Toggle(id)`); one with no value uses an empty struct; one with several fields uses a plain struct
- **`view` receives `State` by value**: writing `s.count = 1` directly is rejected by the compiler. Note that Odin's parameter immutability only covers the first level: `s.todos[0].done = true` still compiles. This part relies on convention
- **`view` only gets a `Dispatch(Msg)`**, with no pointer to the store, so it can only send messages
- **The library provides no equivalent of `useState`**: the UI state the library keeps per widget ID (see item 3) is not open to users for storing custom data. Whatever you want to store goes into `State`

### 2. Frame loop

A frame is split into several phases. **`view` itself is purely declarative**:

```
1. Wait:          block until there is an input event, a message, an expired timer or a request_redraw; next_frame returns false when the window closes
2. Input phase:   hit-test against the layout currently on screen, dispatch events to the matching widget IDs,
                  update the library's presentation state (cursor, scroll, focus, hover), and record interaction results by ID (clicked, changed, ...)
3. Message phase: process messages in order (from view, from tasks, from timers), calling update once per message, then run effects
4. view:          next_frame returns true and the app calls view. Widgets only read the results recorded in step 2 as their Response;
                  they handle no input and modify nothing, and only declare nodes and what to draw
5. Layout:        on the next call to next_frame, Taffy computes layout, then popup positioning runs
6. Check:         a. layout differs from what view read in step 4, or moved a culled container into view → this pass counts as a ghost pass: drop the messages it sent and go back to step 4
                  b. view sent messages → go back to step 3 to process them, then rerun view
                  Neither case presents the frame; view runs at most 3 times per frame; if still unstable, present the last pass and log a warning in debug mode
7. Present:       generate draw commands from the final layout and present the frame; free the message arena, clear context.temp_allocator; go back to step 1
```

- **`view` is a pure function**: its inputs are `State`, the library's presentation state and the layout; its outputs are the node tree and messages. So rerunning it any number of times gives the same result, and ghost rendering needs no special cases
- **Rerun on demand**: in most frames (for example, a hover that only changes a color) the layout does not change and `view` runs once; it runs twice only on window resize or structural changes
- **Hit testing uses the layout on screen**: what the user clicks is the position they see
- **Interaction results are consumed only once**: the results recorded in step 2 are cleared after the `view` pass that consumes them (a ghost pass does not count as consuming). Otherwise a rerun would send a message for the same click again
- A controlled text input never shows an intermediate frame where "a typed character flashes back to the old value"; with no events, CPU usage is 0

**Continuous frames on demand**: an engine-level capability, unrelated to the design system.

- `ui.request_redraw(delay)`: called in `view`, it asks for another frame `delay` after this one (`delay = 0` means the next frame). It must be requested again every frame; without a request, the loop falls back to event-driven automatically
- It is presentation-level scheduling and does not modify state, so it may be called in `view`
- Uses: user shaders and embedded content (`Cmd_Custom`), the official Spinner and waiting states
- Callers must check visibility themselves; official components request it only while visible
- Official components other than Spinner and waiting states do not use it (see the "Animation" section of DESIGN.md)

**Lifetime of data in messages**: a message (including any strings in it) is only guaranteed to live until `update` has processed it. If `update` needs to keep it, it must clone it.

### 3. Controlled widgets: every piece of state has exactly one owner

| State | Owner | Examples |
| --- | --- | --- |
| Values that matter to the app | The app's `State` (controlled) | Text input content, checkbox, switch, slider, current tab, selected item, splitter position, the open/closed state of **layers opened by a click or key press** (Menu, Dropdown, Popover, Dialog, Sheet, ...) |
| Presentation and interaction in progress | The library (stored per widget ID) | Cursor, selection, IME preedit text, hover, press, scroll position, keyboard-highlighted menu item, **layers that appear automatically on hover** (Tooltip, Hover Card) |

- No widget can be both controlled and uncontrolled
- Widgets **take values, not pointers**
- When the app wants to control state on the library side (focus an input, scroll somewhere), it does so through an effect in `update`, e.g. `ui.focus(fx, "new-todo")`; the target widget declares a globally unique name with `key = "new-todo"`
- `autofocus = true` belongs to the presentation layer: the widget gets focus when it first appears

### 4. Containers return bool, widgets return Response

**Containers** are opened with `if` and closed automatically at the end of the scope via `@(deferred_out)`. The argument is a struct literal:

```odin
if ui.row({gap = 8, align_y = .Center}) {
    ...
}
```

**When a container needs to report events to the app** (close request, scrolled to the bottom, ...), it takes `d` and a message as arguments, and the library sends that message when the event happens. The container still returns only a bool:

```odin
if ui.dialog(d, Cancel_Delete{}, open = s.pending_delete != 0, title = "删除这个文件？") { ... }
if ui.scroll(d, on_end = Load_More{}, {height = ui.grow()}) { ... }
```

**Widgets** all return the same `Response` struct and take named parameters. **Widgets that hold a value return the new value as a second return value**:

```odin
Response :: struct {
    id:   Id,
    rect: Rect, // position currently on screen; popup positioning does not use it, see item 13
    hovered, pressed, clicked, double_clicked: bool,
    changed, submitted, cancelled, focused, lost_focus: bool,
}

if ui.button("保存").clicked do ui.dispatch(d, Save{})
if ui.checkbox(todo.done).changed do ui.dispatch(d, Toggle(todo.id))
if r, f := ui.tabs(s.filter, LABELS); r.changed do ui.dispatch(d, Set_Filter(f))

r, text := ui.text_input("新待办", s.draft)
if r.changed do ui.dispatch(d, Set_Draft(text))
if r.submitted do ui.dispatch(d, Add_Todo{})
```

- `Response` only describes interaction and carries no widget-specific data, so all widgets have the same shape
- Fields that make no sense for a widget (e.g. `submitted` on a button) are always false
- Because the shape is uniform, you can write generic functions that work on any widget: `ui.tooltip(r, "说明")`, `ui.context_menu(r)`, anchoring a popup to `r.rect`
- Strings returned by widgets (e.g. `text`) are allocated in the message arena; the rules of item 2 apply

### 5. Side effects and background tasks

Side effects can only be started in `update`, through `fx`:

| effect | Purpose |
| --- | --- |
| `ui.start_task(fx, proc, arg) -> Task_Id` | Run a task on a library-managed thread |
| `ui.cancel_task(fx, id)` | Request cancellation of a task (cooperative) |
| `ui.focus(fx, key)` | Focus the widget with that `key` |
| `ui.after(fx, duration, msg)` | One-shot timer: sends `msg` to `update` when it expires |

A task is just a plain procedure:

```odin
download :: proc(t: ^ui.Task_Context(Msg), args: Download_Args) -> Msg {
    for i in 1 ..= 100 {
        if ui.cancelled(t) do return Cancelled{}
        ui.emit(t, Progress(f32(i) / 100))  // send to update and wake the UI thread
    }
    return Done{}                           // the return value is also sent to update as a message
}

// in update
case Start:
    if s.status == .Running do return       // state machine: ignore while running
    s.status = .Running
    s.job = ui.start_task(fx, download, Download_Args{...})
```

Rules:
- **Tasks cannot read or write `State`**; they can only send messages through `emit` and their return value
- Task arguments are copied by value; any heap data in the arguments, such as strings, must either be constant or be freed by the task
- `Task_Id` lives in `State`: "is a task running" is itself part of the state
- Cancellation is cooperative: the task must check `ui.cancelled(t)` itself
- `store_destroy` first cancels all tasks and waits for them to finish, then calls the `destroy` passed to `store_init` to free the state
- **Ownership transfer of task results**: if a message sent by a task carries heap data (e.g. a loaded snapshot of a million rows), ownership passes directly to `update`, which keeps or frees it. The message arena rules (item 2) apply only to messages produced on the UI thread

**Timers**

- A timer wakes the loop only once, at the moment it expires; between wakeups CPU stays at 0. It is not animation
- **Timers are not cancelled; filter with a generation token instead**: each time a timer starts, put an incrementing generation token into the message, and `update` ignores messages carrying an old token. For example, after a Toast is dismissed manually, its late auto-dismiss message simply has no effect
- **`update` does not read the clock**: where time is needed (e.g. pausing a Toast on hover, recording remaining time), the timestamp is carried by the message. This way a recorded message stream can be replayed deterministically
- Purely presentational delays (e.g. the hover delay of Hover Card and tooltip) are handled inside the library; the app does not take part

### 6. No signals

No fine-grained reactivity such as signals or observables:

- **No need to know "what to update"**: on every event the whole `view` reruns; a few thousand widgets usually take well under 1ms
- **Small-scale derived state is computed on the fly in `view`**, so it can never get out of sync with the data
- **Odin is a poor fit for signals**: it has no closures that capture variables and no GC; the lifetimes of effects and subscriptions would be managed entirely by hand, which easily leads to dangling pointers

The cost is that **`view` must stay light**: read data, compute simple derived values, draw widgets. Heavy work goes to tasks, or to explicit caches in `State` keyed by version numbers. Rules for large data are in item 12. How the library keeps the per-event cost proportional to what is visible and what changed is described in "Frame tree and performance".

### 7. Custom stores (not recommended)

The library only optimizes for the shape of `ui.Store`. When you need a completely different way of managing state, you can build one from low-level primitives:

- `ui.Inbox($T)`: a thread-safe message queue bound to a window; `send` wakes it automatically
- `ui.wake(&window)`: thread-safe; it only wakes a blocked `next_frame`

On this path, the app itself is responsible for message processing, memory and thread safety.

### 8. Current window: implicit, but switchable only by scope

Widgets take no ctx parameter; they draw to the "current window". To keep it from being swapped out unexpectedly, like `this` in JS:

- The current window is a **stack**, stored in a thread-local variable
- Only two things can change it, and both are tied to a scope:
  - `next_frame(&w)`: sets the current window for this frame
  - `if ui.window_scope(&w) { ... }`: temporarily switches to another window, and switches back automatically when the scope ends (including an early return)
- **There is no public setter.** A called function may switch windows within its own scope, but the caller never sees the change
- In debug mode, assertions check this: calling widgets from another thread, calling widgets outside a frame, or a `window_scope` pointing at a closed window all fail immediately

`dispatch` is the exception: the store is generic, so an implicit global cannot carry the message type, and `Dispatch(Msg)` must be passed to `view` explicitly. This also happens to put "which messages this view can send" into the function signature.

### 9. IDs

- By default the widget's text label is hashed, within the ID scope of the parent container
- Widgets with the same label are told apart with `"保存##toolbar"`; the part after `##` only goes into the hash and is not displayed
- List items pass an `id` to the container: `if ui.list_item({id = todo.id}) { ... }`; the widgets inside all live in that ID scope
- Widgets that `update` needs to target (e.g. to focus them) declare a globally unique name with `key`

### 10. Enforcing the design spec through the API

- The first parameter of `text_input` must be a label (spec: labels go above, no placeholders). For cases like inline editing you can set `hide_label = true`, but the label text is still used for accessibility
- `icon_button` must have a text description, used for the tooltip and accessibility
- Color parameters can only be tokens (`.Fg`, `.Muted`, `.Error` ...), not raw RGB
- Text styles can only be roles from DESIGN.md (`.Body`, `.Label`, `.Metadata` ...), not raw font sizes

### 11. Icons

Constants such as `ph.PLUS` are generated by `icons/`. Each constant uses `#load` to embed the SVGs for all six weights of that icon; only referenced constants end up in the program. The weight defaults to the theme setting (bold).

### 12. Large data and virtual lists

In immediate mode, the per-frame cost depends only on the **number of visible widgets**, which makes it a good fit for data-centric apps. Rules:

- **`view` only iterates over the visible range**:

  ```odin
  if r := ui.virtual_list({count = len(s.visible_rows), estimate = 28}); r.open {
      for i in r.first ..< r.last { row_view(s.rows[s.visible_rows[i]], d) }
  }
  ```

- **Large-scale derived data is not computed in `view`**: data such as sorted indices and filter results is computed in `update` when the data changes; if that is slow, it goes to a task. The result is stored in `State`, and `view` only reads it
- **Large data coming in from tasks is handed over by ownership transfer** (item 5), not copied
- **Virtual lists stay out of the layout engine**: the list computes the position of each row itself, and Taffy only lays out the inside of visible rows. A million rows must never become a million layout nodes
- **Variable-height rows**: measured heights are cached by row key, and rows not yet measured use the estimate; when heights change, the scroll anchor is kept so the view does not jump

### 13. Where layout sits in a frame

- **Draw commands are generated after layout**: during `view`, widgets only record "what to draw" on nodes; after Taffy finishes, all `Draw_Command`s are generated from the final coordinates. What gets drawn is always the current frame's layout. Subtrees that did not change are reused from the previous frame instead (see "Frame tree and performance")
- **Popups are positioned in the same frame**: a popup declares "anchored to node X" in the layout. After the main layout, a positioning phase runs: it takes the anchor's position in the current frame and the popup's own size, and decides whether to flip to the other side and whether to shift to stay inside the window edge. Popups do not lag a frame behind when the window resizes
- **Logic that depends on layout results** (responsive switching, the visible height of a virtual list): read sizes with `ui.size_of(id)`; if what was read differs from the final layout, rerun as a ghost pass per item 2
- **Scrollbars take no layout width**: they overlay the content, so content width does not depend on whether a scrollbar is present. This avoids the oscillation "scrollbar appears → content gets narrower → scrollbar no longer needed"
- **The root** is as wide as the window and at least as tall, so `height = ui.grow()` fills the window while longer content extends below it
- **Text measures to whole physical pixels**, so rounding the laid-out rect never makes it narrower than the text it was measured for
- **Hairlines keep their own thickness**: a divider is drawn from its logical thickness (1px), not from its rounded rect, so every divider has the same physical thickness wherever it lands
- **Taffy handles the circular dependency of text wrapping**: the measure callback only has to answer "given this available width, how big is this text"

### 14. Layers and input routing

**Layer stack**: layer order is determined by opening order, not by z-index numbers.

```
[base content] → [popovers / modals, stacked in opening order] → [Toast layer] → [Tooltip layer]
```

- Each layer **sits on top of the layer that opened it**: a menu opened inside a Dialog is above the Dialog; closing a layer also closes the layers on top of it
- Toasts stay above all popover and modal layers: while a modal is open, notifications remain visible and clickable
- Tooltips are always on the topmost layer and receive no input
- Layers are declared in place, where they are triggered; after layout, the library draws them all in stack order

**Open/closed state**:

- **Layers opened by a click or key press have controlled open state**: Menu, Dropdown, Select, Combobox, Popover, Context Menu, Menubar, Dialog, Alert Dialog, Sheet, Drawer. The open state lives in `State`
- **Layers that appear automatically on hover are managed by the library**: Tooltip, Hover Card. They are part of hover state, and hover belongs to the library
- **All close reasons collapse into one message**: for a click outside, Esc, choosing a menu item or tabbing out, the library sends only the close message specified at the call site, and `update` decides how to handle it
- The trigger widget and the layer are written separately; the layer anchors to any widget's `Response` through `anchor`:

```odin
r := ui.icon_button(ph.DOTS_THREE, "更多")
if r.clicked do ui.dispatch(d, Open_Menu(Row_Menu{row.id}))

if ui.menu(d, Close_Menu{}, open = s.menu == Row_Menu{row.id}, anchor = r) {
    if ui.menu_item("重命名").clicked do ui.dispatch(d, Start_Rename(row.id))
}

if ui.dialog(d, Cancel_Delete{}, open = s.pending_delete != 0, title = "删除这个文件？") {
    if ui.button("删除", variant = .Danger).clicked do ui.dispatch(d, Confirm_Delete{})
}
```

- Usually only one popover chain is open at a time, so a single field in `State` (e.g. `menu: Menu_Id`) is generally enough

**Input routing** (done in the input phase):

- **Mouse**: hit-test from the top of the stack down; the first layer that contains the mouse position receives the event
- **Modal layers** block all input below them, including areas outside their own bounds
- **Click outside a non-modal layer**: sends the close message, and **the click does not pass through to the layer below**
- **Scroll wheel**: nothing below a modal layer responds; while a non-modal layer is open, the wheel still scrolls the content below, and the layer follows its anchor within the same frame
- **Pointer capture while dragging**: when dragging a slider, splitter or scrollbar, events go to the dragged widget until release, whichever layer the mouse moves over

**Keyboard and focus**:

- **Esc acts only on the topmost layer each time**: it sends that layer's close message
- **Focus trap**: while a modal layer is open, Tab cycles only within the topmost modal layer
- **Focus restoration**: each layer remembers the widget that opened it, and focus returns to that widget on close
- **Focus on open**: focus the widget with `autofocus`; if there is none, focus the first focusable widget
- **Menu-like layers** (Dropdown, Context Menu, Menubar, Select): arrow keys move, Enter selects, Tab sends the close message and returns focus to the trigger widget
- **Popover**: focus moves into it when it opens; tabbing out sends the close message, and focus continues in the order of the layer below

### 15. Scrolling

**Ownership and control**

- Scroll position belongs to the library (presentation state)
- The app controls scrolling through effects: `ui.scroll_to(fx, key, align = .Nearest)` (`.Nearest` means scroll the minimum distance needed to make the target fully visible); for virtual lists, `ui.scroll_to_index(fx, list_key, index)`. The target position takes effect after layout in the same frame; thanks to ghost rendering, the view does not jump
- When scrolling needs to notify the app, pass a message following the rules of item 4, e.g. `on_end = Load_More{}`
- **Preserving scroll position**: scroll containers with a `key` keep their scroll position for the whole lifetime of the window (the count is capped, with least-recently-used eviction), so for example switching to another tab and back keeps the position; containers without a `key` are reclaimed when the widget disappears

**Routing wheel events**

- **Latching**: when a scroll gesture starts, it goes to the first container under the mouse that can still scroll in that direction, and stays latched to it for the whole gesture. Within one gesture, when the inner container reaches its end, scrolling does not switch to the outer one
- **Per-axis routing**: horizontal and vertical scrolling each find their own container; Shift + wheel becomes horizontal
- Gesture start and end use the gesture phases provided by the system when available; when they are not, approximate with "about 150ms without a new wheel event means the gesture has ended"
- Each mouse wheel notch scrolls 3 lines, computed with the 24px body line height, i.e. 72px; precise touchpad deltas are used as-is, in pixels
- **No smooth scrolling.** Momentum: on macOS (and Windows precision touchpads) the system generates momentum-phase events, which are handled as-is; **there is no momentum on Linux**, and scrolling follows the finger strictly 1:1, because implementing momentum ourselves means time-driven position interpolation, which is a form of animation

**Keyboard scrolling**

- Keys go to the focused widget first; scroll keys it does not handle (arrow keys, PageUp / PageDown, Home / End, Space) go to the nearest scrollable ancestor container; with nothing focused, they go to the scroll container under the mouse
- When Tab or arrow keys move focus out of view, it scrolls automatically by the minimum distance to make the focused widget visible (virtual lists included)

**When content changes**

- **Scroll anchoring**: when content above the viewport changes height (an image loads, a virtual list measures real row heights, data is inserted at the top), record the ID and offset of the first visible element in the viewport, and after layout adjust the scroll position so it stays put. No anchoring when already at the very top
- **Stick-to-bottom mode**: when already at the bottom, stay at the bottom (logs, event streams)

**Other**

- **Sticky**: the fixed header and first column of Data Table, group headings in lists. Taffy does not handle sticky; the positioning phase after layout offsets these nodes by the scroll position, and clipping and hit testing are adjusted to match
- Parts scrolled out of view or clipped do not take part in hit testing
- Scrollbars have no track: clicking the empty area does not jump a page; only dragging the thumb works

### 16. Text selection

- **All text is selectable by default**: body text, labels, table cells, metadata. As on a web page, **drag-selection works across widgets in document order**; the declaration order in `view` is the document order
- **Text inside interactive widgets is not selectable**: pressing on text in a button, menu item, tab or tag operates the widget
- **Text that must respond to clicks is declared explicitly** with `interactive = true`: it is then not selectable, and reports clicks and double clicks through `Response`. For example, in TodoMVC double-clicking a title enters edit mode
- **Selection belongs to the library** (presentation state): one selection per window, copied with Cmd / Ctrl + C; a selection does not span layers (you cannot select from a Dialog into the content below it)
- Double click selects a word (by UAX #29 word boundaries), triple click selects a paragraph
- **Virtual lists and Data Table do not support drag-selecting text across rows**: rows scrolled out of view are no longer declared, so the library has no access to their text. Instead they use **cell or row selection**, copied as TSV that can be pasted directly into a spreadsheet. Text inside a single cell is still selectable

### 17. Accessibility

**Accessibility is wired in starting at M4 (see [ROADMAP.md](ROADMAP.md)), and every component must fully support it from then on.** It is also infrastructure for debugging and testing.

- **Semantic tree**: generated every frame, after view and layout. Each node contains its role, name, description, value, state (disabled, selected, expanded, checked, ...), position, supported actions, and relations between nodes (label and input, trigger button and menu, ...)
- **Node IDs are widget IDs**; only changed nodes are sent to AccessKit, incrementally
- **Actions initiated by screen readers** (click, focus, set value, scroll) are dispatched as synthetic events in the input phase of the next frame, along the same path as real mouse and keyboard input; `view` does not need to tell them apart
- **Every component has an accessibility contract**: its role, where its name comes from, which states and actions it exposes. Both the implementation and the acceptance of a component include this
- API constraints guarantee that every widget has a name: `icon_button` must have a description, `text_input` must have a label (with `hide_label`, the label is still the accessible name)
- **Layers**: modal layers map to "modal dialog" semantics, so screen readers cannot reach the content below them; the focus model maps directly to screen reader focus
- **Text**: full support for screen readers reading body text and text inputs by character, word and line, including cursor and selection positions. This requires providing text layout information (each glyph's position, grapheme clusters and word boundaries) to AccessKit
- **Virtual lists and Data Table**: tell the screen reader the total row and column counts and the current row and column position, not just the few dozen rows on screen
- **Live regions**: notifications such as Toasts are read aloud by screen readers as live regions

**Debugging through the accessibility interface**:

- `just a11y-dump`: lists the semantic tree of a running app. Via AXUIElement on macOS, via AT-SPI on Linux
- `just a11y-press <name>`: clicks a widget through an accessibility action
- Environment variable `MYOD_A11Y_LOG=1`: whenever the semantic tree changes, the app prints the changes as text
- This makes it possible to confirm, without screenshots, what state a running UI is in and what happens after a click. Agents can use it directly while writing and debugging code

---

## Frame tree and performance

Immediate mode's performance cliff is not that `view` reruns; it is that **every event redoes everything at the size of the whole UI**: every declared widget, plus all of its downstream work (layout, text, draw commands, semantic tree). Asking users to annotate what can be skipped (React's `memo`, Elm's `Html.lazy`) only moves the burden onto whoever writes the code. myod attacks the cliff structurally instead, with no user annotations.

### One node array per pass, one slot per ID

`view` declares into a **flat, pre-order node array** (`core/`): one record per node with its ID, its content hash, its style as Taffy reads it, and what it draws. The arrays are double-buffered: the previous pass's array stays readable while the next one is built.

Everything that must outlive a pass lives in a **slot**, one per widget ID: the last laid-out rect, Taffy's layout cache and last layout for the node, the hash that cache belongs to, and the library's per-ID state (caret, scroll offset, …). Slots not declared for 120 frames are reclaimed.

- **Taffy runs directly on the node array** (validated in M3): `ffi/` implements Taffy's low-level tree traits over the C structs Odin fills in, and keeps the cache and last layout per slot. There is no second tree to keep in sync
- Styles are read in place through views that implement Taffy's style traits; only grid containers are converted to a `taffy::Style` (their track lists are generic iterators)
- Matching against the previous frame is by ID, through the slot: no per-table lookups
- Text layout and draw commands are not stored: draw commands are generated after layout for the visible nodes, from the shaping cache (measured below; storing them is not worth it yet)

### Automatic subtree reuse

While a node is declared, it computes a **content hash** from its ID, its style and what it draws; when it closes, it folds in the hashes of all its children (a Merkle tree). Before layout, every node whose hash differs from the one its slot's layout cache was built for gets its cache cleared. That is exactly Taffy's "mark dirty up to the root": a change anywhere changes the hashes of all its ancestors and nothing else.

- **Unchanged subtrees are answered from Taffy's cache**: Taffy does not descend into them at all, and their children keep the layouts stored in their slots
- **Constraints are part of Taffy's cache key**: unchanged content under a narrower parent is laid out again, with no extra bookkeeping
- A subtree that only moved (a row inserted above it) keeps its cache: positions are relative to the parent, and absolute rects are recomputed in one cheap pass
- Hover, pressed and focus will join the hash with M4, so presentation changes invalidate exactly the widgets they affect

Correctness does not rely on anyone remembering dependencies: the hash covers everything that was actually declared, so if the output changes, the hash changes.

### Automatic culling

Containers already return bool (`if ui.column(...) { ... }`). A container whose last rect lies entirely outside the visible area **returns false**: the code inside does not run, and the library inserts a placeholder node with the container's previous size. Long forms, long documents and long settings pages become effectively virtualized with no API change.

- The decision uses the container's previous rect against the **current** visible area, so scrolling never shows a missing container. If layout moves a placeholder into view anyway, the pass reruns as a ghost pass (API design → 2)
- If content changes while culled, the placeholder size can be wrong; scroll anchoring (API design → 15) keeps the visible content from jumping
- The slots inside a culled container are kept alive (their list is collected once, when culling starts), so the presentation state of widgets inside it (e.g. a caret position) is not collected just because they were not declared for a while
- Screen readers and text selection treat culled regions like virtual lists: placeholder nodes, scrolled into view on demand

### Cheap declaration

Declaring a widget does the minimum: append a record to the node array, compute its ID and hash, find its slot. The target is tens to around a hundred nanoseconds per widget, so even 10,000 visible widgets declare in about 1ms. Measured (M3, M3 MacBook Air, optimized build): about 95 ns per text widget.

### Resulting cost model

The cost of one event is roughly:

> **visible widgets × a small declaration cost** + **changed subtrees × the full cost**

This is the same order of complexity as fine-grained reactive frameworks (Solid, Svelte), without signals and without user annotations. The only remaining O(N) term is the user's own computation for visible widgets inside `view`, which is what the rule "`view` must stay light" covers.

A compile-time approach (compiling `view` into create and fine-grained update code, as Svelte does) would change the complexity class too, but it needs a DSL or restrictions on Odin code, adds a build step and loses "control flow is plain code". With the runtime approach reaching the same order of complexity, it is not worth it.

### Measuring it

- The debug overlay (`MYOD_DEBUG_RENDER=1`) shows, per frame: widgets declared, containers culled, widgets whose layout was reused, nodes Taffy laid out, measure calls, passes, and time spent in `view`, layout and draw generation
- `just bench` runs the M3 benchmark (`examples/03_long_form`): a 5,885-widget settings form, one field changing every frame. Optimized build on an M3 MacBook Air: 0.08 ms per frame on average (view 0.02, layout 0.05, draw commands 0.01), 0.11 ms at p99; about 180 widgets declared, 120 containers culled, 7 nodes laid out per frame. Real typing joins in M7

---

## Build and dependencies

**Users clone and run `odin build` directly**: no Nix, no Rust, C or C++ toolchain needed. All third-party dependencies are prebuilt static libraries committed to the repo; the steps that build these static libraries are also fully archived in the repo and can be reproduced with Nix at any time.

```
third_party/
  sources.toml        versions, URLs and sha256 of all upstreams, all pinned
  flake.nix           build recipes (Nix-pinned toolchain)
  prebuilt/<platform>/ static libraries for each platform, plus the sha256 of each file
  fingerprints/       baselines for reproducibility checks
```

- `just vendor`: rebuild all third-party libraries with Nix
- `just verify`: check that the rebuilt output is byte-for-byte identical to the artifacts in the repo; also runs in CI
- On the Odin side, `when ODIN_OS` selects the `foreign import` path per platform
- **No Git LFS**: the project is open source on GitHub and not sensitive to repo size. Binary artifacts and the DWG font are committed to the repo directly

**How dependencies are handled**:

| Dependency | Approach | Reason |
| --- | --- | --- |
| HarfBuzz, FreeType, nanosvg, libunibreak | Prebuilt static libraries, committed to the repo | |
| Taffy Rust wrapper (`ffi/`) | Prebuilt static library, committed to the repo | Built with `panic = "abort"`, `opt-level = "s"`, LTO and stripped debug info. wgpu-native carries its own copy of the Rust standard library, so the archive is pre-linked into one object (`ld -r`) that exports only the functions in `ffi/exports.txt`; everything else becomes local and cannot clash |
| AccessKit | Prebuilt static library, committed to the repo | Goes into the same Rust static library as the Taffy wrapper, so only one copy of the Rust standard library is included |
| SDL3 | Built from source into a static library, committed to the repo | Only the subsystems the UI needs (video, events, etc.) are enabled; audio, gamepad, SDL's own render API and so on are turned off |
| wgpu-native | For now, upstream's prebuilt static library release, hash-pinned and committed to the repo | Odin's `vendor:wgpu` only ships the Windows library; for macOS and Linux we have to supply our own. Will switch to building from source later |
| Odin bindings for SDL3 and wgpu | Copied from Odin's `vendor:sdl3` and `vendor:wgpu` into `third_party/odin/`, rewriting only the library linking part | The original bindings link the system SDL3 and the wgpu in the vendor directory; only a copy can point at our static libraries. `just bindings` re-syncs them |
| Fontconfig (Linux) | **Dynamically linked against the system version** | It has to read the system font configuration; bundled statically, it would fail to find the fonts the user has installed |
| CoreText, Metal, AppKit (macOS) | System frameworks, dynamically linked | |
| DWG font | Font files committed to the repo, loaded on demand at runtime | |

**Platforms**:

| Platform | Priority | Build method |
| --- | --- | --- |
| macOS arm64 | First batch | Native Nix build on macOS |
| Linux x86_64, arm64 (glibc) | First batch | Native Nix build; the minimum glibc version must be pinned and documented |
| Windows x86_64 | **Last** | Odin on Windows uses the MSVC linker, so static libraries must use the MSVC ABI: C and C++ are compiled with clang targeting MSVC, Rust uses `cargo-xwin`, and the Windows SDK is obtained via xwin. This is the most troublesome link in the whole build chain |

---

## Rendering backend

**Flow of a frame**: `Draw_Command` list → packed into instance data (position, UV, color, mode) → uploaded to the GPU → one render pass → several draw calls → present.

**Batching**: there is only one pipeline, with both atlases bound at the same time. Only the following cases split a batch:
- A change of clip region (scroll containers, etc.)
- Content that uses its own texture (charts, user images)
- User custom drawing (`Cmd_Custom`)

Layers are drawn in layer stack order, and within a layer in declaration order (painter's algorithm).

**Color blending** (same as Ghostty):

| Platform | Surface format | Blending space | Text |
| --- | --- | --- | --- |
| macOS | Non-`*Srgb` | Gamma space (native, same as browsers) | Native |
| Linux, Windows | `*Srgb` | Linear space | `linear-corrected`: corrects coverage to avoid darkened edges |

- Blending is determined by the surface format; the two methods cannot be mixed within one render pass, and shaders cannot read the colors already on the canvas. So **semi-transparent tokens are pre-resolved to opaque colors when the theme loads** (e.g. "fg at 12% over bg"). They skip blending and match the design mockups under both methods
- The only things that still need blending: the overall opacity of the disabled state, and the edges of glyphs and icons

**Atlases**:

- **R8 atlas**: glyphs, Phosphor icons (single-color, mask mode). After an SVG is rasterized, only the alpha channel is kept
- **RGBA atlas**: emoji, multicolor SVGs (color mode)
- Both are bound at the same time, and a mode flag on each instance decides which one to sample; there is still only one pipeline
- Each atlas is a set of square pages; on the GPU it is one `texture_2d_array` with a layer per page, and each instance carries its page index. Every page keeps a white texel at (0, 0) for solid rectangles
- They grow by pages; when full, **evict a whole page, the least recently used one**, and re-rasterize when needed. Eviction bumps the page's generation; cache entries store the generation they were written with, so a stale entry is detected on lookup and rasterized again
- A page drawn from in the current frame is never evicted (that would corrupt quads already emitted): a frame that needs more than the budget grows the atlas past it instead

**GPU memory budget** (defaults, configurable):

| Use | Unit size | Cap |
| --- | --- | --- |
| R8 atlas (2048²) | 4MB / page | 4 pages = 16MB |
| RGBA atlas (2048²) | 16MB / page | 2 pages = 32MB |
| Charts, user images (each its own texture) | About 5MB for one 1600×800 chart | 256MB total; least-recently-used eviction, with textures invisible for many consecutive frames evicted first |

**Device loss**: when a driver updates, the GPU resets or an external GPU is unplugged, all GPU resources become invalid. **No data lives only on the GPU**: glyphs can be re-rasterized, charts can be regenerated, and images keep their source data on the CPU side. After the device is recreated, the next frame draws as usual.

wgpu-native reports a loss only when an operation on the lost device fails, and surface calls on a lost device abort the process. So each frame touches the device first (it creates the command encoder before acquiring the surface texture): the frame that hits the loss is dropped, and the next frame recovers. `examples/01_rects --selftest` exercises this path by destroying the device on purpose.

**Presentation**:

- Present mode is FIFO (vsync): no tearing, lowest power use. Rendering is event-driven: with no input, nothing is drawn at all
- If the hash of the command list has not changed, nothing is submitted to the GPU
- Multiple windows share one GPU device and one set of atlases, and each window has its own surface; the glyph cache key includes the size in physical pixels, so windows with different DPI can share the cache
- **Live relayout while dragging a window edge**: on macOS, while a window edge is being dragged, the system takes over the event loop and the main loop is blocked. The frame pipeline must be **drivable both from the main loop and from SDL3's event callback**; otherwise, during a resize the content freezes at the old size or gets stretched

**User custom drawing (`Cmd_Custom`, after 1.0)**: each region is first drawn into an offscreen texture, then composited into the UI as an image. User shaders do not need to care about our clipping, layering or blending, and problems in them do not affect the rest of the UI.

**Debug tools**:

- All wgpu objects are labeled, so when capturing a frame with Xcode's GPU frame capture (macOS) or RenderDoc (Linux) you can see what each draw call is drawing
- `MYOD_DEBUG_RENDER=1`: shows the draw call count, instance count, atlas pages and evictions, and per-frame time in a corner (`devtools/`)
- `MYOD_DEBUG_ATLAS=1`: draws the atlas pages on screen, to see which glyphs are loaded and which page was evicted
- `--dump <prefix>` on the M2 examples writes offscreen captures (both themes, 1x and 2x) as raw RGBA; `tools/rgba2png.py in.rgba out.png [x y w h zoom]` turns them into PNGs, optionally cropped and enlarged

---

## Testing

**Pixel self-tests.** The renderer can draw into an offscreen texture and read it back (`backend.capture`). `examples/01_rects --selftest` (`just test`) renders the component page in both themes at 1x, 1.25x, 1.5x and 2x and checks:

- **Probes**: known pixels match the DESIGN.md tokens exactly
- **No in-between colors**: every pixel is a color the page can produce (tokens, plus disabled composites). Any other color means an edge was blended, i.e. it is blurry
- **Uniform hairlines**: every separator has the expected physical thickness. Without anti-aliasing, a missing pixel snap does not create in-between colors, it creates lines that are 1px in one place and 2px in another, so thickness is checked directly
- **Device loss**: destroy the device, detect the loss, recover, and render correctly again

The M2 examples follow the same pattern (`devtools/demo` holds the shared window, capture and `--dump` scaffolding):

- `02_text`: the 2:1 grid at every scale and size, wrapping, uppercasing and letter spacing, features and variation axes, fallback, color emoji, unbroken underlines, and identical rendering after atlas pages were evicted (with a tiny 256² atlas). Runs on both text backends
- `02_sprites`: grids of ┼ have unbroken lines across cells and line boxes at every scale
- `02_icons`: every Phosphor weight at 12 / 16 / 20 / 24px draws inside its box, duotone shows both colors, inline icons stay inside the line box
- `03_layout`: the app shell's panel and divider rects at three window sizes and four scales; dividers are equally thick hairlines running the full height
- `03_feed`: `repeat(auto-fill, minmax(240px, 1fr))` gives the right number of columns at five widths; rows are as tall as their tallest card; text stays inside its card
- `03_long_form`: off-screen sections are culled, unchanged subtrees come from the layout cache, and culling moves nothing (visible sections land where they would with culling off)
- `odin test core`: IDs (stable, scoped, `"Label##id"`), duplicate IDs, per-ID state and its reclamation, ghost passes after a changed `size_of`, subtree reuse, culled containers keeping their slots alive
- `just test-ffi` (needs Rust): the Taffy wrapper's own tests


Modeled on React Testing Library: **test the way users actually use the app**. The ghost rendering pipeline is itself a test environment that needs no window: input, messages, view and layout need no GPU; only the final present does.

```odin
t := ui.test_harness(State{}, update, view)
ui.test_click(&t, role = .Button, name = "加一")              // find by semantics, simulate a click
ui.test_type(&t, role = .Textbox, name = "新待办", text = "买牛奶\n")
testing.expect(tt, t.state.count == 1)
testing.expect(tt, ui.test_find(&t, role = .Checkbox, name = "买牛奶") != nil)
```

- **Find by role and name, not by coordinates**: this uses the semantic tree generated every frame, the same tree that is handed to the system accessibility API
- **Tests always use the FreeType + HarfBuzz backend**, on macOS too. This way logic tests get exactly the same layout on every platform and need no per-platform baselines
- Simulated input goes through the real input phase: clicks do real hit testing, and widgets that are covered or disabled cannot be clicked
- `update` can be unit-tested on its own as pure code; message streams can be recorded and replayed as action sequences that reproduce bugs
- Visual screenshot tests (which need a GPU) come later, with per-platform baselines

---

## Module layout

```
platform/  windows, events, DPI, system theme (built on SDL3); calls the redraw callback directly while a window edge is dragged
core/      the declaration layer and frame tree: widget IDs, slots (per-ID state, layout cache, last rect),
           Merkle hashes, culling, ghost passes, layout, draw command generation; later input state, layers
atlas/     two atlases: R8 (glyphs, icons) and RGBA (emoji, multicolor SVG); packing, paging, whole-page eviction
text/      font loading, measurement, line wrapping, glyph and icon rasterization into the atlases (both layout and rendering depend on it);
           backend_coretext.odin and backend_freetype.odin (FreeType + HarfBuzz, with Fontconfig on Linux), picked at compile time
sprite/    sprite glyphs: box drawing, blocks, braille, Powerline, Spinner
icons/     the Icon type (an SVG per weight); icons/phosphor is the generated Phosphor name table, embedding SVGs with #load
devtools/  debug overlays (MYOD_DEBUG_RENDER, MYOD_DEBUG_ATLAS); devtools/demo is the shared scaffolding of the examples
layout/    Odin binding for ffi/: the C structs and functions of the Taffy wrapper
ffi/       Rust wrapper (one crate, later also AccessKit): implements Taffy's layout tree traits on the
           node array passed from Odin, exports a C ABI
ui/        the public API: containers and layout options (layout.odin), display widgets (widgets.odin),
           and the draft of what later milestones implement (draft.odin)
render/    Draw_Command definitions, plain data, no dependency on any GPU code
backend/   wgpu implementation: consumes Draw_Command and submits to the GPU
widgets/   official component library (aligned with the shadcn/ui component set)
chart/     charts: build nanosvg shapes, rasterize into textures, cache by data version and size
testing/   test tools: test_harness, finding by role and name, simulated input
third_party/  prebuilt third-party static libraries, Nix build recipes, reproducibility checks, Odin bindings
           (third_party/odin), the C shims for FreeType and nanosvg (third_party/shim), fonts and Phosphor
tools/     developer scripts (rgba2png.py for --dump captures)
examples/  one runnable demo per milestone, plus three API examples: counter, todomvc, download
```

Dependency direction: `ui → core → layout + text`, `layout → ffi`, `chart → nanosvg (third_party/shim)`, `text → atlas`, `icons/phosphor → icons`, `text → icons + sprite`, `core → render`, `backend → render + atlas`.
`render/` must not depend on `backend/`.
