// Hand-written bindings for libunibreak: UAX #14 line breaking, UAX #29 grapheme and word breaking.
package unibreak

when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	@(export) foreign import unibreak "../../prebuilt/macos-arm64/libunibreak.a"
} else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
	@(export) foreign import unibreak "../../prebuilt/linux-x86_64/libunibreak.a"
} else when ODIN_OS == .Linux && ODIN_ARCH == .arm64 {
	@(export) foreign import unibreak "../../prebuilt/linux-arm64/libunibreak.a"
} else {
	#panic("myod does not support this platform yet: only macOS arm64, Linux x86_64 and Linux arm64")
}

// Line break values: brks[i] describes the position after byte i.
LINEBREAK_MUSTBREAK :: 0
LINEBREAK_ALLOWBREAK :: 1
LINEBREAK_NOBREAK :: 2
LINEBREAK_INSIDEACHAR :: 3
LINEBREAK_INDETERMINATE :: 4 // the end of the text

GRAPHEMEBREAK_BREAK :: 0
GRAPHEMEBREAK_NOBREAK :: 1
GRAPHEMEBREAK_INSIDEACHAR :: 2

WORDBREAK_BREAK :: 0
WORDBREAK_NOBREAK :: 1
WORDBREAK_INSIDEACHAR :: 2

@(default_calling_convention = "c")
foreign unibreak {
	init_linebreak :: proc() ---
	set_linebreaks_utf8 :: proc(s: [^]u8, len: uint, lang: cstring, brks: [^]u8) ---
	init_graphemebreak :: proc() ---
	set_graphemebreaks_utf8 :: proc(s: [^]u8, len: uint, lang: cstring, brks: [^]u8) ---
	init_wordbreak :: proc() ---
	set_wordbreaks_utf8 :: proc(s: [^]u8, len: uint, lang: cstring, brks: [^]u8) ---
}
