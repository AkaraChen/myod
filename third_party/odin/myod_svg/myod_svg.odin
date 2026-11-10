// Bindings for third_party/shim/myod_svg.c, myod's flat C API over nanosvg.
package myod_svg

when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	@(export) foreign import shim "../../prebuilt/macos-arm64/libmyod_text_shim.a"
} else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	@(export) foreign import shim "../../prebuilt/linux-x86_64/libmyod_text_shim.a"
} else when ODIN_OS == .Linux && ODIN_ARCH == .arm64 {
	@(export) foreign import shim "../../prebuilt/linux-arm64/libmyod_text_shim.a"
} else {
	#panic("myod does not support this platform yet: only macOS arm64, Linux x86_64 and Linux arm64")
}

// Which shapes to rasterize.
LAYER_ALL :: -1
LAYER_TRANSLUCENT :: 0 // shapes with opacity < 1 (Phosphor duotone's background)
LAYER_OPAQUE :: 1      // shapes with opacity 1 (duotone's foreground)

// A scene built in code (charts): shapes and subpaths added with the calls below, then rasterized.
// Opaque; free it with `scene_free`.
Scene :: rawptr

@(default_calling_convention = "c", link_prefix = "myod_svg_")
foreign shim {
	// Rasterizes into a size×size RGBA8 image (straight alpha). `svg` must be NUL-terminated and is
	// modified. With `mask` set, shapes are drawn opaque white so alpha is pure coverage.
	rasterize :: proc(svg: [^]u8, size: i32, layer: i32, mask: i32, out: [^]u8) -> i32 ---

	// ---- Scenes ----
	scene_new :: proc(width, height: f32) -> Scene ---
	scene_free :: proc(sc: Scene) ---
	// Starts a shape. Colors are 0xRRGGBBAA; `stroke_width` 0 draws no stroke; `even_odd` picks the
	// even-odd fill rule.
	begin :: proc(sc: Scene, fill, stroke: u32, stroke_width: f32, even_odd: i32, opacity: f32) ---
	// Starts a subpath, and adds a straight or curved segment to it.
	move :: proc(sc: Scene, x, y: f32) ---
	line :: proc(sc: Scene, x, y: f32) ---
	cubic :: proc(sc: Scene, c1x, c1y, c2x, c2y, x, y: f32) ---
	quad :: proc(sc: Scene, cx, cy, x, y: f32) ---
	close :: proc(sc: Scene) ---
	// Rasterizes into a width×height RGBA8 image (straight alpha). Returns 0 on success.
	scene_rasterize :: proc(sc: Scene, width, height: i32, out: [^]u8) -> i32 ---
}
