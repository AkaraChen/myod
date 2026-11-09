// Hand-written bindings for the parts of HarfBuzz myod uses. Links third_party/prebuilt/.
package harfbuzz

when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	@(export) foreign import lib {
		"../../prebuilt/macos-arm64/libharfbuzz.a",
		"../../prebuilt/macos-arm64/libfreetype.a",
		"system:c++",
	}
} else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	@(export) foreign import lib {
		"../../prebuilt/linux-x86_64/libharfbuzz.a",
		"../../prebuilt/linux-x86_64/libfreetype.a",
		"system:stdc++",
		"system:m",
	}
} else when ODIN_OS == .Linux && ODIN_ARCH == .arm64 {
	@(export) foreign import lib {
		"../../prebuilt/linux-arm64/libharfbuzz.a",
		"../../prebuilt/linux-arm64/libfreetype.a",
		"system:stdc++",
		"system:m",
	}
} else {
	#panic("myod does not support this platform yet: only macOS arm64, Linux x86_64 and Linux arm64")
}

Font :: struct {}
Buffer :: struct {}

Glyph_Info :: struct {
	codepoint: u32, // the glyph index after shaping
	mask:      u32,
	cluster:   u32, // byte offset into the UTF-8 input
	_:         [2]u32,
}

Glyph_Position :: struct {
	x_advance, y_advance: i32, // 26.6 fixed point when the font comes from hb_ft
	x_offset, y_offset:   i32,
	_:                    u32,
}

Feature :: struct {
	tag:        u32,
	value:      u32,
	start, end: u32, // byte range in the buffer; 0 and FEATURE_GLOBAL_END apply it everywhere
}

FEATURE_GLOBAL_END :: max(u32)

@(default_calling_convention = "c", link_prefix = "hb_")
foreign lib {
	ft_font_create_referenced :: proc(ft_face: rawptr) -> ^Font ---
	ft_font_changed :: proc(font: ^Font) ---
	font_destroy :: proc(font: ^Font) ---

	buffer_create :: proc() -> ^Buffer ---
	buffer_destroy :: proc(buffer: ^Buffer) ---
	buffer_reset :: proc(buffer: ^Buffer) ---
	buffer_add_utf8 :: proc(buffer: ^Buffer, text: [^]u8, text_length: i32, item_offset: u32, item_length: i32) ---
	buffer_guess_segment_properties :: proc(buffer: ^Buffer) ---
	buffer_get_glyph_infos :: proc(buffer: ^Buffer, length: ^u32) -> [^]Glyph_Info ---
	buffer_get_glyph_positions :: proc(buffer: ^Buffer, length: ^u32) -> [^]Glyph_Position ---

	shape :: proc(font: ^Font, buffer: ^Buffer, features: [^]Feature, num_features: u32) ---
}
