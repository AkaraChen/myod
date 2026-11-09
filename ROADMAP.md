# myod roadmap

An immediate mode UI library for Odin, rendered on the GPU, aimed mainly at desktop applications. License: zlib.

---

## Goals and non-goals

**Goals**

- Immediate mode API: describe the UI every frame, in the style of `if button("OK") { ... }`
- Built for desktop applications: power-efficient (no redraw without input), high DPI, Chinese input methods, clipboard
- **Platforms**: macOS arm64, Linux x86_64 and arm64 (glibc), Windows x86_64. **macOS and Linux come first; Windows comes last**
- **Full accessibility support, early**: from M4 on, connect to the system accessibility APIs; after that, every component ships with full accessibility semantics. This doubles as a debugging tool: the system accessibility tools can inspect the running UI and operate widgets
- Rendering backend decoupled from UI logic: the backend only consumes a plain-data list of draw commands
- An official component library on top of the core: **at 1.0, cover all general-purpose components of shadcn/ui** (excluding purely business-specific components such as chat bubbles). What we match is the set of components and their behavior (which components exist, what each is responsible for, how they compose); the look follows DESIGN.md
- Positioned as **data-driven software**: data-centric desktop applications such as tables, lists, charts, and feeds; a million rows of data must scroll smoothly

**Non-goals (at least before 1.0)**

- Real-time rendering of arbitrary vector paths on the GPU (the Vello / Slug kind). Icons and charts are rasterized on the CPU with nanosvg and cached as textures
- A retained-mode widget tree
- Fine-grained reactive state management such as signals / observables; see [ARCHITECTURE.md](ARCHITECTURE.md), “API design → 6”, for why
- `useState`-style component-local state: all application state lives in `State`
- The web platform
- **Right-to-left languages**: no RTL mirrored layout and no bidirectional text (Arabic, Hebrew); shadcn's Direction component is not provided
- Game UI is a nice to have: we only guarantee the `Cmd_Custom` hook is in place, with no dedicated optimization
- **Rounded corners, shadows (including hard shadows without blur), gradients, blur / frosted glass**: explicitly excluded by the visual style; see [DESIGN.md](DESIGN.md)
- **Animations, transitions, and motion feedback in official components**: including hover fades, press-down sinking, pop-up animations, springs, smooth scrolling, cursor blinking, and chart animations. The only exception is Spinner; the admission criteria are in DESIGN.md, “Animation”. Users' own shaders are not restricted

---

## Visual style

The full specification is in [DESIGN.md](DESIGN.md). The points with the most impact on implementation:

- Corner radius 0, no shadows, no animation (the only exception is Spinner), state feedback changes color only → the renderer needs no SDF, and the frame loop is purely event-driven by default
- 1px borders must align to physical pixels, otherwise they blur at non-integer scale factors
- Semi-transparent tokens are pre-resolved to opaque colors; blending differs by platform (macOS blends in gamma space; Linux and Windows blend in linear space with text correction)
- Everything uses AKR DWG SC NFM (大弯勾, "DWG"): a strict 2:1 grid, with Chinese built into the font; all font sizes are even
- Icons use Phosphor (SVG) and go through the same pipeline and the same single-channel atlas as glyphs

---

## Architecture

Technology choices, API design, build and dependencies, rendering backend, testing, and module layout are all in [ARCHITECTURE.md](ARCHITECTURE.md). References in the milestones below such as “API design → N” or “Technology choices” refer to sections of that document.

---

## Milestones

Each milestone uses **a runnable demo** as its acceptance criterion, placed under `examples/`.

### M0: Skeleton — window and clear

- [x] **Build infrastructure**: the `third_party/` directory layout, `sources.toml`, `flake.nix`, `just vendor` / `just verify` / `just verify-rebuild` / `just bindings`; SDL3 (built from source) and wgpu-native (upstream prebuilt package) committed to the repo; working on macOS arm64
- [ ] Get the same workflow working on Linux x86_64
- [x] Copy the Odin bindings for SDL3 and wgpu into `third_party/odin/`, linking against our own static libraries
- [x] Create a window with SDL3 (`platform/`)
- [x] Create the wgpu instance / adapter / device / surface (`backend/`): surface creation is our own code (`CAMetalLayer` on macOS, Wayland / X11 window handles on Linux), not the SDL3 glue in `vendor:wgpu`, because that pulls in the system SDL3
- [x] Clear every frame and draw a test pattern: a window border 1 logical pixel wide, a center cross, and a grid line every 32 logical pixels
- [x] Handle window resizing: reconfigure the surface when the size changes
- [x] Handle high DPI: distinguish logical pixels from physical pixels and draw according to the scale factor
- [x] **The frame pipeline can be driven both by the main loop and from SDL3's event callback**: while a window edge is being dragged, macOS takes over the event loop, and frames are drawn directly in SDL's event callback
- [x] Follow the system light/dark mode

**Acceptance:** `examples/00_clear`: on macOS (Retina) and Linux, **hold and keep dragging a window edge**; the content follows the new size in real time, with no flicker, no stretching, and no getting stuck at the old size. On a machine without Nix, `odin build` works directly after clone.

- [x] macOS arm64: accepted on 2026-11-09 (static image, continuous edge dragging, and light/dark switching all behave as expected); the built program depends only on system frameworks
- [ ] Linux x86_64

**Reading:** the basic wgpu object model (Instance → Adapter → Device → Queue → Surface), the SDL3 event loop. See the first chapters of *Learn Wgpu* (sotrh); the concepts map one-to-one onto the Odin bindings.

---

### M1: Rectangle renderer

- [x] Define the first version of the `Draw_Command` union in `render/`: `Cmd_Rect`, `Cmd_Clip_Push`, `Cmd_Clip_Pop`
- [x] Instanced rendering: one quad, one instance per rectangle, drawn in a single draw call
- [x] A single pipeline only: each instance = position + UV + color + mode flag; solid rectangles sample a white pixel in the atlas
- [x] **Two atlas textures bound at once**: R8 (mask mode: sampled value × color) and RGBA8 (color mode: output the texture color directly), selected by the instance's mode flag. For now both are 256×256 and hold only the white texel; M2 makes them paged
- [x] Borders: a bordered rectangle becomes up to five non-overlapping quads (fill + four edges), so translucent fills and borders never blend over each other; 1px and 2px both supported
- [x] **Pixel alignment**: logical coordinates × scale factor, rounded to physical pixels; border width at least 1 physical pixel. Two snapping modes (`render.Snap`): `Edges` for layout boxes (each edge snapped independently) and `Size` for hairlines (origin snapped, thickness rounded separately, so equal logical lines get equal physical thickness)
- [x] **Choose the surface format per platform**: non-`*Srgb` on macOS (gamma-space blending), `*Srgb` on Linux (linear-space blending)
- [x] **Semi-transparent tokens pre-resolved to opaque colors**: `theme/` resolves every token over bg and over bg-solid
- [x] Label all wgpu objects
- [ ] `MYOD_DEBUG_RENDER=1` debug overlay: needs text, moved to M2. Until then, `01_rects` shows the render stats in the window title
- [x] Implement clipping with scissor rects
- [x] Split batches when the clip changes
- [x] Allocate the command array each frame with Odin's `context.temp_allocator`
- [x] Put the color tokens from DESIGN.md into `theme` (light and dark sets)
- [x] Device loss: recreate the device and all GPU resources, and draw normally on the next frame (see ARCHITECTURE.md, “Rendering backend” for how wgpu-native reports losses)
- [x] Offscreen capture with CPU readback (`backend.capture`), used by the pixel self-test

**Acceptance:** `examples/01_rects`: draw the static look of buttons, toggles, checkboxes, and progress bars with token colors (no text yet); borders are sharp, not blurry, at 1x and 2x and at simulated 1.25x and 1.5x scale. On macOS and Linux, color-picked values match the DESIGN.md tokens exactly. 10,000 rectangles stay at 60fps+.

- [x] macOS arm64, automated (`just test`), 2026-11-09: both themes at 1x / 1.25x / 1.5x / 2x — all probes exact, no in-between colors, uniform hairlines; device loss detected and recovered
- [x] macOS arm64, 10,000 rectangles: 60fps (capped by the 60Hz display); renderer CPU time 2.4ms per frame in a debug build, 0.9ms with `-o:speed`
- [x] macOS arm64, visual check of the interactive page (2026-11-09)
- [ ] Linux x86_64

**Reading:** wgpu instanced drawing and vertex buffer layout; WGSL basics

---

### M2: Text and icons

This is the hardest part. The earlier it starts, the better.

- [ ] **Text backends** (per the table in ARCHITECTURE.md, “Technology choices”, following Ghostty):
  - [x] macOS: CoreText (via Odin's `core:sys/darwin/CoreText`), handling font loading, shaping, rasterization and fallback (`text/backend_darwin.odin`). System font discovery by name is still to do
  - [ ] Linux: Fontconfig + FreeType + HarfBuzz
  - [ ] The three backends expose the same interface to the layer above: font lookup, shaping, rasterization, metrics
  - [ ] FreeType load flags: hinting + auto-hinter + light
- [ ] **DWG**:
  - [x] The default font, in two weights, Regular and Bold; loaded at runtime from `third_party/fonts/` (or `$MYOD_FONT_DIR`), not compiled into the program (about 17MB per weight). Pinned in `sources.toml` and checked by `just verify`
  - License confirmed: it may be distributed with the library. Releases include the license file for each part (OFL 1.1 for the Latin part, the Alibaba license for Alibaba PuHuiTi 3.0 (阿里巴巴普惠体))
  - [ ] Fast measurement on the 2:1 grid: programming ligatures do not change character width, so width is computed directly as “half-width count × 0.5em + full-width count × 1em”, with no shaping
- [ ] **Font features**: OpenType features (`calt`, `liga`, `ss01`–`ss20`, `cv01`…, `zero`, `frac`…) and variable font axes (`wght`, `wdth`…), all configurable in the theme's text roles
- [x] **Shaping cache**: cache shaping results by `(string, face)`, evicting entries unused for 120 frames; features and variation axes join the key when they land. Immediate mode redeclares all text every frame; without a cache, Data Table cannot keep up
- [ ] **Font fallback**: characters outside DWG (Chinese characters outside the Level 1 and Level 2 sets, emoji, other scripts) go through system fallback: CoreText's fallback list, Fontconfig. Fallback glyphs are vertically centered in the line box; line height uses the primary font's metrics
- [ ] **Color glyphs**: Apple Color Emoji (sbix, handled directly by CoreText) — done on macOS; Noto Color Emoji (CBDT bitmaps) with the FreeType backend. Drawn in color mode
- [ ] **Sprite glyphs** (`sprite/`): box drawing (U+2500–257F), block elements (U+2580–259F), Braille patterns (U+2800–28FF), Powerline separators. Drawn directly with rectangles, with no gaps between adjacent cells. Spinner also uses this module
- [ ] **Alpha blending for text**: native on macOS; on Linux, correct coverage with `linear-corrected`
- [ ] Text styles: size, weight, color, letter spacing, uppercase transform (Latin letters only), underline
- [ ] **Dynamic atlas** (`atlas/`):
  - [x] shelf packing (`atlas/`), with dirty-region uploads; single page for now
  - [ ] Cache key: `(source, id, size_px, subpixel_x)`; the source can be a glyph or an SVG; `subpixel_x` is always 0 for SVG
  - [ ] Grows by page; when full, evict the least recently used page as a whole; respect the GPU memory budget
  - [ ] `MYOD_DEBUG_ATLAS=1`: draw the atlas on screen
- [ ] `MYOD_DEBUG_RENDER=1` debug overlay (moved from M1, now that text exists): draw calls, instances, atlas pages, frame time
- [x] Add `Cmd_Glyph_Run`; the backend draws glyph quads with the same instanced pipeline (sampling the atlas texture). Glyphs land on whole physical pixels with 4 horizontal subpixel bins
- [ ] **SVG icons** (`svg/`, `icons/`):
  - [ ] Write Odin bindings for nanosvg (parsing + rasterization)
  - [ ] Replace `currentColor` with white before parsing, and draw the rasterized result in mask mode so it follows the text color
  - [ ] Split by layer: the two layers of duotone are rasterized into two atlas entries, and the two layers can use different colors
  - [ ] Multi-color SVGs (with hard-coded colors) are drawn in color mode
  - [ ] Rasterize at an integer physical pixel size of `round(size × scale)`, and align the draw position to integer physical pixels too
  - [ ] An icon can be an element in a text run, taking part in measurement and wrapping, vertically centered in the line box
  - [ ] `icons/` provides name constants for Phosphor icons and uses `#load` to embed only the SVGs actually used
  - [ ] Support six weights: thin, light, regular, bold, fill, duotone
- [x] Text measurement API: `measure(text, style) -> [2]f32` (single line for now; wrapping comes with libunibreak)
- [ ] Line breaking and grapheme clusters: integrate libunibreak (UAX #14, UAX #29)
- [ ] Uppercase transform and letter spacing apply only to Latin letters, not to Chinese
- [ ] Rasterize according to the DPI scale factor; after converting the font size to physical pixels, round to the nearest even number so the half-width advance is always an integer number of pixels; the smallest size, 12px, needs a dedicated check on 1x screens

**Acceptance:**
- [x] Step a (2026-11-09, macOS arm64): `examples/02_text` renders the DESIGN.md type scale in DWG with mixed Chinese and English, Cascadia ligatures, the 2:1 grid, fallback characters and color emoji; `--selftest` checks the 2:1 grid at every scale and size, fallback, and color emoji; visual check passed
- `examples/02_text`: render a page of mixed Chinese and English content following the type scale in DESIGN.md; sharp at 1x, 2x, and 1.5x, aligned to the 2:1 grid, wrapping automatically with window width. The same page includes Cascadia programming ligatures, a variable font (any variable font, demonstrating continuous change on the `wght` axis), emoji, and Chinese characters outside the Level 1 and Level 2 sets (through fallback)
- `examples/02_sprites`: patterns built from box drawing, block, Braille, and Powerline characters, with no gaps between adjacent cells at any scale
- `examples/02_icons`: the same set of Phosphor icons laid out as a matrix of six weights × 12 / 16 / 20 / 24px, sharp on both 1x and 2x screens; the two duotone layers use different colors; a line mixing icons and text aligns correctly. In particular, confirm whether the default bold weight is sharp at 12px and 16px.

**Reading:**
- Aria Beingessner — *Text Rendering Hates You*
- **Ghostty's `src/font/`**: per-platform backends, shaping, sprite glyphs (`sprite/`), cell metrics. This is the most direct reference
- Read `vendor:fontstash` (written in Odin) to see how its atlas is managed
- Read the nanosvg source to learn which SVG features it supports (Phosphor only uses filled paths and opacity)

---

### M3: Declaration and layout (Taffy)

Layout needs something to lay out, so this milestone also builds the declaration layer: widget IDs, containers, and the per-frame declared tree. The examples drive it with a minimal frame loop on top of M0–M2; the Store, input phase and interaction arrive in M4.

- [ ] **Declaration layer**:
  - [ ] **Widget ID system**: label hash + parent ID stack (`push_id` / `pop_id`), with disambiguation syntax such as `"Label##id"`
  - [ ] **Cheap declaration** (ARCHITECTURE.md, “Frame tree and performance”): declaring a widget only appends a record to the per-frame arena and computes its ID and content hash; target tens to around a hundred nanoseconds per widget, measured with a micro-benchmark
  - [ ] Debug check: two widgets with the same ID in one frame trigger an immediate warning (ID instability silently mixes up state)
  - [ ] Containers close automatically via `@(deferred_out)` and return bool
  - [ ] **Persistent state storage by ID**: entries not accessed this frame are reclaimed after N frames
- [ ] **Rust wrapper layer** (`ffi/taffy/`):
  - [ ] Validate the approach first: implement Taffy's low-level layout tree traits directly on the resolved tree's node array (ARCHITECTURE.md, “Frame tree and performance”), with the layout cache stored in each node and carried across frames. The external API stays immediate mode, and there is no second tree to keep in sync. **This validation matters a lot**: if it fails, a real second tree comes back with its sync costs
  - [ ] Fallback if validation fails: use Taffy's own node tree, reuse nodes by widget ID, diff every frame, and mark only the changed parts
  - [ ] Export a C ABI; build static libraries for macOS arm64, Linux x86_64 and arm64 following the process in ARCHITECTURE.md, “Build and dependencies”, and commit them to the repo
- [ ] Text measurement callback: during layout, Taffy calls back into Odin's `text/`
- [ ] **flex**: row / column, padding, gap, alignment, fit / grow / fixed sizing, min / max, wrapping
- [ ] **grid**: fixed tracks, `fr`, `auto`, `minmax`, `repeat(auto-fill, minmax(…))`, gap, row and column spans
- [ ] flex and grid nest within each other arbitrarily
- [ ] Layout results are stored by widget ID, for the next frame's input phase and for `ui.size_of`
- [ ] **Pixel alignment**: round to physical pixels uniformly when converting layout results into `Draw_Command`s, without accumulating rounding error
- [ ] Draw commands are generated after layout: during `view`, only record what to draw; once layout is computed, generate `Draw_Command`s with the final coordinates
- [ ] Layout change detection: compare against the sizes `view` read, triggering ghost rendering
- [ ] **Resolved tree** (ARCHITECTURE.md, “Frame tree and performance”): one record per node holding the declared parameters, layout, text layout, draw commands and semantic information; double-buffered across frames
- [ ] **Automatic subtree reuse**: Merkle content hash per container; reuse when root ID, hash and parent constraints match; draw commands and semantic bounds stored relative to the subtree origin
- [ ] **Automatic culling**: a container entirely outside the visible area in the previous frame returns false and leaves a placeholder with its previous size; culled subtrees keep their presentation state
- [ ] Debug overlay counters: widgets declared, containers culled, subtrees reused, time per stage

**Acceptance:**
- `examples/03_layout`: sidebar + main area + right info panel, separated by 1px dividers, reflowing correctly when the window resizes
- `examples/03_feed`: a card feed using `repeat(auto-fill, minmax(240px, 1fr))`, with flex layout and wrapping text inside the cards; each row's height is set by its tallest card; the number of cards per row changes as the window resizes
- **Performance benchmark** `examples/03_long_form`: a long, non-virtualized form page (thousands of widgets). The example changes one field's value programmatically every frame; the whole frame (`view` + layout + draw generation) must stay within a fixed budget on an M3 MacBook Air (exact number set once the first measurements are in), and the debug overlay shows that almost everything off screen is culled and almost everything on screen is reused. The interactive version (typing into a field) is part of M7's acceptance

**Reading:** the Taffy source (especially the grid track sizing algorithm and the low-level trait API); the track sizing part of the CSS Grid spec

---

### M4: Core — the first clickable button

- [ ] Input state: mouse position and buttons, wheel, keyboard, modifiers, unified into one snapshot per frame
- [ ] hot / active state (hover / pressed)
- [ ] **Input phase**: before `view`, hit-test against the layout currently on screen, dispatch events, update presentation state, and record interaction results by ID; widgets only read the results in `view`
- [ ] **On-demand ghost rendering**: when the layout disagrees with what `view` read, discard this pass's messages and rerun, at most 3 passes; interaction results are consumed only once
- [ ] **Event-driven frame loop**:
  - [ ] Block and wait when there are no events (`SDL_WaitEvent`)
  - [ ] Compare against the previous frame's command list (hash); if nothing changed, do not submit to the GPU
  - [ ] Only events, messages, due timers, and `request_redraw` trigger a new frame; the wait timeout is the earliest of these
- [ ] **Store** (implemented per ARCHITECTURE.md, “API design”):
  - [ ] `ui.Store(State, Msg)`, `store_init` / `store_destroy`, `Dispatch(Msg)`, `dispatch`
  - [ ] `next_frame` processes messages and runs effects in order; when messages remain unprocessed, rerun immediately without submitting intermediate frames
  - [ ] Message arena: freed as a whole after each round of message processing
- [ ] **Tasks and effects**:
  - [ ] `start_task` / `cancel_task` / `emit` / `cancelled`; tasks run on threads managed by the library
  - [ ] A task's `emit` and return value enter the store through a thread-safe queue and wake the UI thread (`SDL_PushEvent`)
  - [ ] `store_destroy` first cancels and joins all tasks, then calls `destroy`
  - [ ] The `focus` effect and the widget `key`
  - [ ] Each task automatically records its start time and the time of its most recent `emit`, for the pending state component
  - [ ] `after` timers: the earliest of all pending timers becomes the timeout for `SDL_WaitEventTimeout`
- [ ] **API skeleton**:
  - [ ] A `Response` struct returned uniformly by all widgets; widgets with a value return the new value as the second return value
  - [ ] Current window stack: thread-local, modifiable only by `next_frame` and `window_scope`
  - [ ] Debug assertions: calls from other threads, calls outside a frame, window already closed
- [ ] **Low-level primitives**: `ui.Inbox($T)` and `ui.wake`; Store and Task are built on them too
- [ ] First widget: the outline button; the idle, hover, and pressed states change color only
- [ ] **Semantic tree**: built each frame after view and layout; node IDs are widget IDs; contains role, name, value, state, position, actions
- [ ] **Integrate AccessKit** (per ARCHITECTURE.md, “API design → 17”): macOS and Linux adapters; incremental updates; screen reader actions enter the input phase as synthetic events
- [ ] **Debug tools**: `just a11y-dump`, `just a11y-press`, `MYOD_A11Y_LOG=1`
- [ ] **Test tools** (`testing/`): `test_harness`, lookup by role and name, simulated clicks and input that go through the real input phase; all tests use the FreeType + HarfBuzz backend

**Acceptance:**
- `examples/counter` actually runs: clicking + / − changes the number; CPU usage is near 0% when idle
- A test: after a task `emit`s a message, the blocked UI thread wakes within one frame and calls `update`
- A test: after `view` sends a message, no frame is submitted until `update` has processed it
- A test for `examples/counter`: use `test_harness` to click “加一” (“+1”) three times and “重置” (“Reset”) once, and assert the state is correct; results are identical on macOS and Linux
- While `examples/counter` runs, `just a11y-dump` shows the buttons and the number; after `just a11y-press 加一` clicks, the number changes; VoiceOver on macOS and Orca on Linux read it correctly

**Reading:**
- Casey Muratori — *Immediate-Mode Graphical User Interfaces* (video)
- Ryan Fleury — *UI, Part 1–3* (rfleury.com): widget keys, the build process, caching

---

### M5: Virtual lists and large data

- [ ] `ui.virtual_list`: returns only the visible range; supports both fixed-height and variable-height rows
- [ ] Variable-height rows: cache measured heights by row key, with an estimate as fallback; keep the scroll anchor when heights change
- [ ] Scroll to a given row (the `ui.scroll_to_index` effect)
- [ ] When focus or arrow keys move the selected row, scroll it into view automatically
- [ ] Horizontal virtualization: for Data Tables with many columns
- [ ] Accessibility: report the total row count, total column count, and current position to screen readers; when a screen reader moves to a row outside the viewport, scroll to it automatically
- [ ] Stick-to-bottom mode: stay at the bottom as new content is appended (log and event-stream lists)
- [ ] Ownership transfer of task results (see ARCHITECTURE.md, “API design → 5”)
- [ ] An example pattern that caches sort and filter results by version number

**Acceptance:** `examples/05_million`: a list of one million variable-height rows; data is loaded by a background task, and sorting and filtering run in a task; scrolling stays at 60fps, and CPU is 0 when idle

---

### M6: Basic components and theming

Implemented per DESIGN.md, “Component specs”; all states change color only. **Every component ships with a full accessibility contract** (role, name, state, actions), verified with the test tools:

- [ ] `label`, section heading
- [ ] `button`: four variants, outline / primary / ghost / danger; three sizes, default, small, and icon-only; can carry a leading icon
- [ ] `toggle`, `checkbox`, `radio` (square)
- [ ] `slider`, `progress`
- [ ] `tag`
- [ ] `tabs`
- [ ] List row
- [ ] **Splitter**: 6px hit area, drag follows 1:1, resizes panel widths
- [ ] **Scroll container** (implemented per ARCHITECTURE.md, “API design → 15”):
  - [ ] Clipping + a 6px square scrollbar overlaid on the content, taking no layout width; only the thumb can be dragged
  - [ ] Scroll latching and per-axis dispatch; first investigate whether SDL3 exposes trackpad gesture phases; if not, use native events on macOS, or approximate with a timeout
  - [ ] Inertia: system events on macOS and Windows; not done on Linux
  - [ ] Keyboard scrolling, scrolling focus into view
  - [ ] The `scroll_to` effect, the `on_end` message
  - [ ] Scroll anchoring; containers with a `key` keep their scroll position
  - [ ] sticky: implemented in the positioning phase after layout
- [ ] **Layer system** (implemented per ARCHITECTURE.md, “API design → 14”): layer stack, Toast layer, Tooltip layer; controlled open state and a unified close message; the input phase dispatches from the top of the stack down, and a click outside does not pass through; pointer capture; Esc, focus trap, focus restoration. Visually separated from lower layers by a 2px border and a bg-solid background, not by shadows
- [ ] **Popover positioning**: done in the positioning phase after layout; anchored via `anchor` to a node's position in the current frame; flips to the other side when it does not fit, and adjusts automatically against window edges (the equivalent of floating-ui)
- [ ] `menu` (controlled open state; menu items with icons and submenu arrows), `tooltip` (owned by the library; the hover delay is timed inside the library)
- [ ] `spinner`: a square Braille dot pattern, drawn with the `sprite/` module, about 10 frames per second, requesting redraws only while visible
- [ ] `pending`: pending state; `ui.pending_task(s.job, "下载中")` reads the task's recorded start time and most recent activity directly
- [ ] Disabled state: 36% opacity for the whole widget
- [ ] Focus ring: 2px fg, 1px offset
- [ ] Add `Cmd_Image` and image texture management
- [ ] Theme: all components read only the tokens in `Theme`, with no hard-coded colors or sizes; light and dark sets, following the system by default; can be replaced wholesale by a user-defined theme, but per-widget style overrides are not supported before 1.0

**Acceptance:**
- `examples/06_widgets`: modeled on BR1's “full state matrix”, all states of every widget laid out on one page at once, with switchable light/dark themes
- `examples/download` actually runs with no code changes: the progress bar updates with the task; cancellation and simulated failure both display the correct state; the UI keeps updating during the download without any mouse input

---

### M7: Text input

- [ ] Input field look: label above, no placeholder; focused, error, and disabled states
- [ ] Controlled: the value comes from `State`, and every edit returns the new text; the cursor, selection, and input method preedit text are kept by the library per widget ID. When the application changes the value (e.g., clears it), the cursor position must converge correctly
- [ ] Single-line input: cursor (steady, no blinking), selection (inverted colors), word-wise movement (Option / Ctrl + arrow keys), Home / End
- [ ] Clipboard: copy, cut, paste (SDL3 clipboard API)
- [ ] Undo / redo
- [ ] **Input methods**:
  - [ ] `SDL_StartTextInput` / `SDL_StopTextInput` toggled with focus
  - [ ] Handle `SDL_EVENT_TEXT_EDITING` and show the preedit text (underlined)
  - [ ] `SDL_SetTextInputArea`, so the candidate window follows the cursor
- [ ] Multi-line input (a simple implementation first; large-document performance can be optimized later)
- [ ] **Text selection** (per ARCHITECTURE.md, “API design → 16”): drag-select across widgets in document order, double-click to select a word, triple-click to select a paragraph, copy; interactive widgets and text with `interactive = true` are not selectable
- [ ] **Text accessibility**: screen readers read body text and text fields by character, word, and line, and get the cursor and selection positions

**Acceptance:**
- `examples/07_input`: type Chinese with the system Pinyin input method; the candidate window is positioned correctly; select, copy, and paste work; the error state shows an error message; VoiceOver and Orca read the input field and body text character by character
- On a page of body text, drag-selecting from one paragraph into another copies the text in the correct order
- `examples/todomvc` actually runs with no code changes, fully functional
- `examples/03_long_form` with real typing: typing into a field stays within the frame budget set in M3

---

### M8: Full shadcn/ui component set

Match the general-purpose components of [shadcn/ui](https://ui.shadcn.com/docs/components) (list taken on 2026-11-09). What we match is the components and their behavior; the look follows DESIGN.md. Purely business-specific components are not provided.

**Already done in earlier milestones, or composition only**: Button, Button Group, Checkbox, Radio Group, Switch, Toggle, Toggle Group, Slider, Progress, Tabs, Tooltip, Dropdown Menu, Scroll Area, Resizable, Separator, Label, Badge, Kbd, Input, Input Group, Textarea, Native Select, Typography, Card, Item, Empty, Alert, Aspect Ratio, Skeleton (static placeholder block)

**To be built**:

- [ ] Popup and overlay: Popover, Hover Card, Context Menu, Menubar, Navigation Menu, Select, Combobox, Dialog, Alert Dialog, Sheet, Drawer (appears instantly, no slide-in)
  - [ ] Focus trap, close on Esc, close on click outside
- [ ] Structure: Accordion, Collapsible (expands instantly), Breadcrumb, Pagination, Sidebar, Carousel (switches instantly)
- [ ] Forms: Field, Input OTP, Calendar, Date Picker
- [ ] Data: Table, **Data Table** (built on M5's horizontal and vertical virtualization: sorting, filtering, column resizing, fixed header; cell and row selection, copied as TSV; table accessibility semantics), **Command** (fuzzy search + virtual list)
- [ ] Feedback:
  - [ ] **Toast**: the toast list is application state; auto-dismiss uses a `ui.after` timer with generation token filtering; announced to screen readers as a live region
  - Spinner: done in M6
- [ ] Identity: Avatar (square)
- [ ] **Chart** (`chart/`):
  - [ ] Bar, line, area, pie, and radar charts
  - [ ] Build nanosvg shape structures in code (no SVG string concatenation), rasterize into a separate texture, drawn via `Cmd_Image`
  - [ ] Cache key: `(data version, physical pixel size)`; while the window is being resized, stretch the old texture first, and re-rasterize once resizing stops
  - [ ] Axis labels, values, and legends are drawn by the text system; grid lines use rectangles
  - [ ] The hover crosshair and value tooltip are drawn as an overlay, without re-rasterizing

**Not provided**:
- Purely business-specific components: Message, Message Scroller, Bubble, Attachment, Code Block, Marker, Questionnaire, Trace (shadcn's newly added chat-oriented components)
- Direction: RTL is not supported (see “Non-goals”)

**Acceptance:** `examples/08_shadcn`: one example page per component, in the order of the shadcn docs, with all states interactive; every component can be operated using only the keyboard and a screen reader

---

### M9: Polish and performance (1.0)

- [ ] Profile with `core:prof/spall` and find hot spots
- [ ] Reduce per-frame allocations: all temporary data goes through the arena / temp allocator
- [ ] Tune the default GPU memory budget based on real applications
- [ ] Multiple windows
- [ ] Re-rasterize when a window moves between displays with different DPI
- [ ] Keyboard focus navigation (Tab / Shift+Tab)
- [ ] File dialogs (built into SDL3)
- [ ] **Linux Wayland window decorations**:
  - [ ] When the compositor supports server-side decorations (xdg-decoration, e.g., KDE), use the system title bar
  - [ ] When it does not (e.g., GNOME), use a borderless window + a self-drawn title bar per DESIGN.md, not libdecor's default look
  - [ ] Use `SDL_SetWindowHitTest` for title bar dragging and window edge resizing
  - [ ] First investigate whether SDL3 can tell us if the compositor supports server-side decorations; if not, consider querying the Wayland protocol directly
- [ ] Write API documentation, tidy up the examples
- [ ] **Windows x86_64 (last)**:
  - [ ] Build pipeline: C and C++ compiled with clang targeting MSVC, Rust with `cargo-xwin`, the Windows SDK obtained via xwin; outputs included in `just verify`
  - [ ] Text backend: FreeType + HarfBuzz + scanning the system font directory, as Ghostty does; start with a built-in fallback list
  - [ ] Window, input method, and DPI adaptation on Windows
  - [ ] AccessKit's Windows adapter (UI Automation); `just a11y-dump` supports Windows

**Acceptance:** all examples run with no code changes; `examples/05_million` and `examples/08_shadcn` show no noticeable stutter on macOS, Linux, or Windows, and use no power when idle

---

### M10: After 1.0 (long term)

- [ ] COLRv1 color fonts (FreeType backend)
- [ ] Switch Windows to DirectWrite for font discovery and fallback
- [ ] **Official terminal component**:
  - [ ] Cell grid based on DWG's 2:1 metrics; CJK characters take 2 cells (UAX #11)
  - [ ] Programming ligatures spanning cells
  - [ ] Nerd Font icons: built into DWG; for other fonts, put Symbols Nerd Font Mono in the fallback chain, and scale icons down to fit the cell when they are too wide
  - [ ] Sprite glyphs reuse `sprite/`
  - [ ] Underline styles (curly, dotted, dashed, double) and underline color (SGR 58), strikethrough, overline
  - [ ] Italics: supported when terminal content needs them (the official UI still does not use italics)
  - [ ] VT sequence parsing: consider an existing library such as libghostty
- [ ] Native Mac menu bar
- [ ] `Cmd_Custom`: embed custom wgpu pipelines in the UI (3D viewports, game views, users' own shaders). Each region is drawn into an offscreen texture first and then composited, with `request_redraw` for continuous frames
- [ ] GPU vector rendering for charts (if the cost of CPU rasterization during resizing becomes a problem)
- [ ] Drag and drop
- [ ] Promoting layers to separate system windows: layers such as Dialog can float out of the main window, with the layer stack abstraction unchanged

---

## Open questions

None for now.

---

## References

**UI architecture**
- Casey Muratori — *Immediate-Mode Graphical User Interfaces*
- Ryan Fleury — the *UI* series (rfleury.com)
- Nic Barker — the Clay source and *Introducing Clay* (a reference for an immediate mode layout API)
- The Odin `vendor:microui` source
- The Dear ImGui source (especially the ID stack and input handling)

**Layout**
- The [Taffy](https://github.com/dioxuslabs/taffy) source and docs
- The track sizing algorithm in the CSS Grid spec

**Accessibility**
- The [AccessKit](https://github.com/AccessKit/accesskit) source and docs
- Accessibility Inspector on macOS; Accerciser on Linux (for viewing the AT-SPI tree)

**Rendering**
- *Learn Wgpu* (sotrh)
- The nanosvg source (github.com/memononen/nanosvg)

**Visual style**
- See “References” in [DESIGN.md](DESIGN.md)

**Text**
- Aria Beingessner — *Text Rendering Hates You*
- The Odin `vendor:fontstash` source
- HarfBuzz docs (to read at M10)
