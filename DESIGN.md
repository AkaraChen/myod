# myod design spec

The visual style of the official myod component library. For the architecture, see [ARCHITECTURE.md](ARCHITECTURE.md). For goals and milestones, see [ROADMAP.md](ROADMAP.md).

---

## Sources

- Component appearance, type style and color tokens come from [BR1 — Brutalist Renewed](https://br1.lemonhx.moe/)
- Design principles and the **type scale** come from [Vercel design.md](https://vercel.com/design.md): mostly monochrome, color only carries meaning, hierarchy comes from spacing instead of cards
- The typeface is [AKR DWG SC NFM (大弯勾, "DWG")](https://github.com/AkaraChen/font/tree/main/dwg): Cascadia Code × Alibaba PuHuiTi 3.0 (阿里巴巴普惠体), on a strict 2:1 grid
- Icons come from [Phosphor Icons](https://phosphoricons.com/) (MIT license)

Changes made on top of BR1:

1. **Corner radius is always 0** (BR1 already does this)
2. **No shadows at all**: BR1's 4px hard shadow on menus and the inner shadow on pressed primary buttons are removed
3. **No animation**: BR1's 60ms hover transition, 20ms press, release spring and divider snap spring are all removed. The only exception is the Spinner. See "Animation"
4. **State feedback only changes color**: hover, pressed, focus and disabled only change color or opacity. They **never change position, size or shape**. BR1 sinks pressed elements by 2px and thickens the divider to 3px on hover. Both now only change color
5. **Icons are used**: BR1 prefers text over icons. Here, Phosphor icons are used throughout. See "Icons"
6. **Vercel's type sizes**: BR1's 9–11px is too small, and Chinese becomes unreadable. The type scale is Vercel's, with 13px changed to 12px, so every size is even and the half-width of the 2:1 grid lands on whole pixels. Component sizes are adjusted to match
7. **No italics at all**: BR1 uses italics for metadata. Here, color distinguishes it instead

## Principles

- **All icons come from Phosphor**: bold weight by default, fill when selected or active. Icon color follows the surrounding text
- **Mostly monochrome**: saturated color is only for signals (error, pending, done, running), and always paired with text. For example, a tag says ERROR. Color alone is never enough
- **Hierarchy without containers**: use weight × size × underline × color to express hierarchy. No cards inside cards
- **Density is respect, not clutter**: compact layouts, suited to desktop tools
- **Input labels go above the field. Never use placeholders**
- Light and dark themes. Follows the system by default
- 4px spacing scale: 4 / 8 / 12 / 16 / 20 / 24 / 32 / 48

## Animation

**No animation by default**: every state change in the official components is instant.

**Discrete data refresh is not animation**: when a real value changes, the UI jumps to the new value. Examples: a timer updated every second, relative times like "3 minutes ago", live counters. This is allowed.

**Animation** = continuous interpolation between states for visual effect. It is forbidden in official components, with **exactly one exception**:

- **Admission criterion**: motion is only allowed to "show that an ongoing process with unmeasurable progress is still alive". Currently only the Spinner meets this criterion
- **Not exposed**: official components provide no general helper such as `animate()`. The Spinner implements its own motion internally, so there is no ready-made path to "just add an animation"
- Any new exception must first meet the admission criterion above and be written into this section

This rule only applies to official components. User shaders, embedded video and game views are not restricted. The engine can produce frames continuously on demand (see ARCHITECTURE.md, "API design → 2").

## Color tokens (converted from OKLCH to sRGB)

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| bg | `#f8f8f8` | `#020202` | Window background |
| bg-solid | `#ffffff` | `#060606` | Popover and menu background |
| fg | `#020202` | `#f8f8f8` | Primary text, emphasis borders, inverted fills |
| muted | `#5d5d5d` | `#b1b1b1` | Secondary text, labels |
| faint | fg 55% | fg 52% | Tertiary text, annotations |
| border | fg 12% | fg 10% | Dividers, lines between list rows |
| border-strong | fg 30% | fg 28% | Component borders, section borders |
| overlay | fg 5% | fg 5% | Hover background |
| overlay-hover | fg 9% | fg 9% | Pressed background |

Translucent tokens are the fg color with opacity. In the light theme fg is near-black. In the dark theme fg is near-white.

**Signal colors**

| Token | Light | Dark | Meaning |
| --- | --- | --- | --- |
| error | `#d40924` | `#f3625d` | Stopped, failed, destructive action |
| warning | `#bf6700` | `#de9300` | In progress, pending, degraded |
| success | `#007d1e` | `#2ea957` | Done, passed, healthy |
| info | `#0069bd` | `#0099e6` | Neutral fact, running |

## Typography

- **Everything uses AKR DWG SC NFM (大弯勾, "DWG")**:
  - Latin is Cascadia Code (from Nerd Fonts, with Nerd icons). Chinese is Alibaba PuHuiTi 3.0 (阿里巴巴普惠体), covering GB18030 level 1 and level 2 characters
  - **Strict 2:1 grid**: half-width 500, full-width 1000 (UPM 1000). Chinese and Latin align exactly in tables and terminals
  - Chinese stroke weight is matched to Latin by measurement, and mixed Chinese/Latin text has the same line height. No fallback font is needed
  - Three weights: Light / Regular / Bold. The UI only uses Regular (400) and Bold (700)
- Characters outside level 1 and level 2, emoji and other scripts use system font fallback
- Benefits of a monospaced font: digits align naturally without `tnum`, and measurement can be computed directly from the grid
- **No italics at all**: DWG only has an upright style, and Chinese has no italics
- **All type sizes are even**: so the half-width is a whole number of pixels on 1x screens and the grid never drifts
- Sizes and line heights follow Vercel's type scale (13px changed to 12px), **minimum 12px**. Weight, case and letter spacing follow BR1's style

| Role | Size / line height (px) | Weight | Case | Letter spacing | Color | Use |
| --- | --- | --- | --- | --- | --- | --- |
| display | 48 / 56 | 700 | As is | 0 | fg | The single large heading on a page. Use sparingly |
| page-title | 40 / 48 | 700 | As is | 0 | fg | Page title |
| title | 32 / 40 | 700 | As is | 0 | fg | Title |
| section | 24 / 32 | 700 | As is | 0 | fg | Major section heading |
| subsection | 20 / 26 | 700 | As is | 0 | fg | Minor section heading |
| lede | 18 / 28 | 400 | As is | 0 | fg | Lead paragraph |
| body | 16 / 24 | 400 | As is | 0 | fg | Body text |
| compact | 14 / 20 | 400 | As is | 0 | fg / muted | Input text, list rows, secondary text |
| label | 12 / 20 | 700 | Uppercase | 0.12em | Follows component | Buttons, tabs, menu items, tags, table headers, input labels, section labels |
| metadata | 12 / 20 | 400 | As is | 0 | faint | Annotations, timestamps, error messages, tooltips |

- Uppercase and letter spacing only apply to Latin letters. Chinese stays as is
- No negative letter spacing on headings: a tightened monospaced font looks cramped

## Icons

**Source**: [Phosphor Icons](https://phosphoricons.com/), MIT license, used as SVG files (`assets/` in the [phosphor-icons/core](https://github.com/phosphor-icons/core) repository)

**Weights**: all six are supported: thin, light, regular, bold, fill, duotone
- **bold by default**: matches the visual weight of 700 component text, and stays clearest at small sizes
- **fill means selected or active**: for example, the current tab or a starred item
- Other weights can be used, but do not mix them within one interface

**Sizes**: 12 / 16 / 20 / 24 px, 16px by default

| Context | Icon size | Gap to text |
| --- | --- | --- |
| Button (28px tall) | 16 | 6px |
| Icon-only button (28×28) | 16, centered | — |
| Small button (24px tall) | 12 | 4px |
| Menu item, list row, tab | 16 | 8px |
| tag | 12 | 4px |
| Inline icon in body text | Same as type size | One space wide |

**Color**
- Follows the color of the surrounding text by default, and changes color with the text on state changes
- Signal icons (error, warning, done) use the matching signal color, and always have text next to them
- **duotone**: the back layer defaults to the same color at 20% opacity (as in Phosphor). The back layer can also be given its own color

**Alignment**
- Icon size and position snap to whole physical pixels. No subpixel positioning
- In mixed text, icons are vertically centered in the line box, not aligned to the baseline (Phosphor glyphs are centered in a 256×256 canvas)

## Component specs

All states are **instant color changes**. Disabled is always 36% opacity and ignores input.

Components share a height of **28px** (24px for small), so buttons and inputs align side by side.

**Button**: label type, 28px tall (24px for small, 28×28 for icon-only), 12px horizontal padding (8px for small)

| Variant | Rest | Hover | Pressed |
| --- | --- | --- | --- |
| outline (default) | border-strong border, transparent background, fg text | fg border, overlay background | fg background, bg text (inverted) |
| primary | fg background, bg text | Transparent background, fg text, fg border | overlay-hover background, fg text, fg border |
| ghost | No border, muted text | `border`-colored border, overlay background, fg text | overlay-hover background, fg text |
| danger | error border and text | error background, bg text | Same as hover |

**Switch**: 36×20, square. Thumb 14×14, 3px from the top
- Off: border-strong border, transparent background, muted thumb, on the left (x = 3)
- On: success background and border, bg-solid thumb, on the right (x = 19)
- On toggle, the thumb jumps straight to its new position

**Checkbox**: 16×16, border-strong border. When checked, filled with fg, with a 12px `check` icon in bg color in the center (bold weight)

**Radio button**: 16×16 **square**, border-strong border. When selected, an 8×8 fg fill inside (4px inset on all sides)

**Input**
- Label above (label, muted), 4px from the input. **No placeholder**
- Input: compact type, 28px tall, 8px horizontal padding, transparent background, border-strong border
- Focused: border and label turn fg
- Error: border, text and label turn error. The reason is written 4px below in metadata type, error color
- Disabled: 40% opacity, border color changes to the `border` token

**Slider**: 6px track with a hollow border-strong border. Handle is an 8×14 solid fg rectangle

**Progress bar**: 8px tall, border-strong border, fg fill. A 40px-wide percentage number (compact) on the right. Progress changes jump straight to the new value

**Tag**: label type, 20px tall, 6px horizontal padding, 1px border in the current text color. The text color is the signal color. Neutral states use muted

**Menu**
- Minimum width 180px, bg-solid background, **2px** border-strong border, no shadow
- Menu item: 32px tall, 12px horizontal padding, label type, 1px border dividers between items
- Current item: 2px fg bar on the left
- Destructive actions use the error color
- Menu items can have a 16px leading icon. Items with a submenu have a `caret-right` icon on the right
- A button that opens a menu has a `caret-down` icon on the right, replaced by `caret-up` while the menu is open

**Tooltip**: inverted (fg background, bg text), 4 × 8 padding, metadata type, shown 4px above the target. No delay, no fade, no shadow

**Tabs**: label type, 32px tall, 12px horizontal padding, 1px border divider on the right of each tab. Hover: overlay background, fg text. Current tab: fg text plus a 2px fg bar at the bottom. The whole group has a border-strong line at the bottom

**List row**: 28px tall, 8px horizontal padding, 1px border at the bottom, compact type. Key on the left in muted, value on the right in bold, optionally in a signal color

**Section heading**: number (metadata, faint) + title (label) + annotation on the right (metadata, faint), border-strong line at the bottom, 12px space below

**Divider**: visually a 1px border, with a 6px hit area. On hover and drag the color changes to fg, **thickness stays the same**. Dragging follows the mouse 1:1, with no snapping on release

**Scrollbar**: 6px wide, border-strong thumb, no track
- **Overlays the content and takes no layout width**: content width is the same with or without a scrollbar
- Always shown while content is scrollable. Never hidden after scrolling stops
- Thumb turns fg on hover and drag
- The area under the thumb takes mouse input first. Scrollable content keeps at least 8px of right padding so the thumb does not cover text

**Text selection**: inverted (fg background, bg-solid text)

**Focus ring**: 2px solid fg, offset 1px outward (2px for sliders). Monochrome, never blue

**Spinner**: square braille dot matrix
- A 2 × 4 matrix of square dots, lit frame by frame following the braille spinner sequence `⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏`. Discrete frames, about 10 per second, no smooth interpolation
- **Drawn directly with rectangles, not with a font**: square dots match the zero-radius style and stay pixel-aligned at any scale. It is the same module that procedurally draws box-drawing and braille characters in the terminal
- Size: 2 × 2px dots, 2px dot spacing, 6 × 14px overall, vertically centered in a 20px line height. Each dot snaps to physical pixels (exact values to be tuned after real rendering in M6)
- Lit dots use the surrounding text color. Unlit dots use the border color
- Can be used alone or after text (`加载中 ⠹`)
- Only wakes up to refresh while visible: stops when scrolled out of view, covered, or when the window is minimized
- Suited to short waits (a second or two). For longer waits, combine with the "pending state" below

**Pending state**: long waits with unknown progress
- First line: Spinner + what is being done (label type) + stage (for example "Step 2 of 3: extracting")
- Second line (metadata, faint): elapsed time · time since last activity · optional count ("1,284 files processed")
- Elapsed time and "last activity" refresh once per second (discrete refresh, not animation)
- "Last activity" is the information that actually proves the task is alive: when the task is stuck, it keeps growing
- Usually accompanied by a cancel button

**Window title bar**
- macOS and Windows: use the native system title bar
- When the system provides no title bar (for example Wayland under GNOME), draw it ourselves:
  - 32px tall, bg background, 1px border-strong line at the bottom
  - Window title on the left (label, muted; fg when the window has focus)
  - Three icon-only buttons on the right for minimize, maximize and close (ghost, 28×28), with icons `minus`, `square` (`copy` when maximized) and `x`
  - The close button turns to an error background with a bg-colored icon on hover
  - Double-clicking the title bar maximizes / restores

## Implementation implications

- **Much simpler renderer**: no SDF shaders. Everything is an axis-aligned solid or textured rectangle. Put a 1×1 white pixel in the atlas, and rectangles, text and icons share **one pipeline**. With both atlases bound at once, a whole frame often needs only one draw call.
- **Icons go through the glyph pipeline**: SVGs are rasterized once on the CPU with nanosvg, cached in the atlas shared with glyphs, then drawn like glyphs. Icons can appear directly inside text runs and reuse measurement and line-breaking logic.
- **Two atlases, bound at once**: monochrome content (glyphs, Phosphor icons) goes in an R8 atlas. Color content (emoji, multicolor SVG) goes in an RGBA atlas. Each instance carries a mode flag: **mask mode** samples the R8 atlas and multiplies by a given color. **Color mode** samples the RGBA atlas and outputs the original colors. Monochrome content is the vast majority, and R8 uses 4× less VRAM than RGBA.
- **Phosphor uses mask mode**: before rasterizing, `currentColor` is replaced with white. At draw time it is multiplied by the text color, so icons follow theme and state colors. The two duotone layers are rasterized into two separate atlas entries, so each layer can have its own color.
- **Pixel alignment becomes the top priority**: with no corner radius or shadow to "blur" edges, a 1px border that lands on a half pixel looks fuzzy. This is most visible at 125% / 150% scaling on Windows. Every rectangle edge snaps to physical pixels, and border width is `max(1, round(1 × scale))` physical pixels.
- **The frame loop is purely event-driven by default**: the cursor is steady, not blinking, and CPU is 0 with no input. Only two things wake it on a timer: a visible Spinner (about 10 times per second) and the timer in a pending state (once per second). Both only happen while visible.
- **Translucent tokens are pre-resolved to opaque colors**: tokens like border and overlay are "fg plus some opacity", and they are almost always drawn on bg or bg-solid. The composited opaque color is computed when the theme loads. No blending is involved, so the result matches the design exactly on every platform and with any blending method.
- **Disabled state needs whole-component opacity**: multiply all commands of a component by one alpha. Components have almost no internal overlap, so simple multiplication is enough. No offscreen rendering is needed.
- **Text needs case conversion and letter spacing**: both only apply to Latin letters and do not affect Chinese.
- **Minimum type size 12px**: Chinese and Latin are both readable on 1x screens.
- **Type sizes are even in physical pixels**: at non-integer scales (such as 125% or 150%), the type size in physical pixels is rounded to the nearest even number, so the half-width of the 2:1 grid is always a whole number of pixels.
- **Alpha blending differs by platform**, as in Ghostty: macOS blends in gamma space (the native method, matching browsers). Linux and Windows blend in linear space, with text coverage corrected by `linear-corrected` to remove dark edges, which looks close to native. Since translucent tokens are already pre-resolved to opaque colors, rectangle colors are the same under both methods.

---

## References

- [BR1 — Brutalist Renewed](https://br1.lemonhx.moe/): source of component appearance and color tokens
- Vercel — [design.md](https://vercel.com/design.md) and [vercel-brand.css](https://vercel.com/geist/vercel-brand.css): design principles and type scale
- [AKR DWG SC NFM (大弯勾)](https://github.com/AkaraChen/font/tree/main/dwg): the Latin part is OFL 1.1. The Chinese part (Alibaba PuHuiTi 3.0) is not OFL and is covered by Alibaba's own license
- [Phosphor Icons](https://phosphoricons.com/): icon library, SVG sources at [phosphor-icons/core](https://github.com/phosphor-icons/core)
