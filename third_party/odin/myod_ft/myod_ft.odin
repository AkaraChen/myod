// Bindings for third_party/shim/myod_ft.c, myod's flat C API over FreeType.
package myod_ft

when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	@(export) foreign import shim {
		"../../prebuilt/macos-arm64/libmyod_text_shim.a",
		"../../prebuilt/macos-arm64/libfreetype.a",
	}
} else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	@(export) foreign import shim {
		"../../prebuilt/linux-x86_64/libmyod_text_shim.a",
		"../../prebuilt/linux-x86_64/libfreetype.a",
	}
} else when ODIN_OS == .Linux && ODIN_ARCH == .arm64 {
	@(export) foreign import shim {
		"../../prebuilt/linux-arm64/libmyod_text_shim.a",
		"../../prebuilt/linux-arm64/libfreetype.a",
	}
} else {
	#panic("myod does not support this platform yet: only macOS arm64, Linux x86_64 and Linux arm64")
}

Library :: distinct rawptr
Face :: distinct rawptr // an FT_Face; also accepted by harfbuzz.ft_font_create_referenced

PIXEL_MODE_GRAY :: 2
PIXEL_MODE_BGRA :: 7

Bitmap :: struct {
	width, rows, pitch: i32,
	left, top:          i32, // offset from the pen position; top is measured upward
	pixel_mode:         i32,
	buffer:             [^]u8,
}

@(default_calling_convention = "c", link_prefix = "myod_ft_")
foreign shim {
	init :: proc(out: ^Library) -> i32 ---
	done :: proc(library: Library) ---
	new_face :: proc(library: Library, data: [^]u8, size: i64, out: ^Face) -> i32 ---
	done_face :: proc(face: Face) ---
	set_pixel_size :: proc(face: Face, px: u32) -> i32 ---
	metrics :: proc(face: Face, ascender, descender, height: ^f64) ---
	render :: proc(face: Face, glyph: u32, subpixel_64: i32, color: i32, out: ^Bitmap) -> i32 ---
	has_color :: proc(face: Face) -> i32 ---
}
