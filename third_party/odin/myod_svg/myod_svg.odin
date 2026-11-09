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

@(default_calling_convention = "c", link_prefix = "myod_svg_")
foreign shim {
	// Rasterizes into a size×size RGBA8 image (straight alpha). `svg` must be NUL-terminated and is
	// modified. With `mask` set, shapes are drawn opaque white so alpha is pure coverage.
	rasterize :: proc(svg: [^]u8, size: i32, layer: i32, mask: i32, out: [^]u8) -> i32 ---
}
