// Hand-written bindings for the parts of Fontconfig myod uses. Linked dynamically from the system:
// Fontconfig reads the system's font configuration, so a vendored copy would not find user fonts
// (see ARCHITECTURE.md, "Build and dependencies").
#+build linux
package fontconfig

foreign import fc "system:fontconfig"

Config :: struct {}
Pattern :: struct {}
CharSet :: struct {}

Bool :: b32

Result :: enum i32 {
	Match,
	NoMatch,
	TypeMismatch,
	NoId,
	OutOfMemory,
}

Match_Kind :: enum i32 {
	Pattern,
	Font,
	Scan,
}

FILE :: cstring("file")
INDEX :: cstring("index")
CHARSET :: cstring("charset")
SCALABLE :: cstring("scalable")

@(default_calling_convention = "c", link_prefix = "Fc")
foreign fc {
	InitLoadConfigAndFonts :: proc() -> ^Config ---
	ConfigDestroy :: proc(config: ^Config) ---
	PatternCreate :: proc() -> ^Pattern ---
	PatternDestroy :: proc(p: ^Pattern) ---
	PatternAddCharSet :: proc(p: ^Pattern, object: cstring, c: ^CharSet) -> Bool ---
	PatternAddBool :: proc(p: ^Pattern, object: cstring, b: Bool) -> Bool ---
	PatternGetString :: proc(p: ^Pattern, object: cstring, n: i32, s: ^cstring) -> Result ---
	PatternGetInteger :: proc(p: ^Pattern, object: cstring, n: i32, i: ^i32) -> Result ---
	CharSetCreate :: proc() -> ^CharSet ---
	CharSetDestroy :: proc(c: ^CharSet) ---
	CharSetAddChar :: proc(c: ^CharSet, ucs4: u32) -> Bool ---
	ConfigSubstitute :: proc(config: ^Config, p: ^Pattern, kind: Match_Kind) -> Bool ---
	DefaultSubstitute :: proc(p: ^Pattern) ---
	FontMatch :: proc(config: ^Config, p: ^Pattern, result: ^Result) -> ^Pattern ---
}
