// Picks the text backend at compile time.
//
// macOS uses CoreText by default; `-define:MYOD_TEXT_BACKEND=freetype` switches it to FreeType +
// HarfBuzz, the backend Linux always uses. Tests use FreeType + HarfBuzz on every platform, so their
// layouts match everywhere (see ARCHITECTURE.md, "Testing").
package text

TEXT_BACKEND :: #config(MYOD_TEXT_BACKEND, "native")

when ODIN_OS == .Darwin && TEXT_BACKEND == "native" {
	Backend :: CoreText_Backend
	backend_init :: coretext_init
	backend_destroy :: coretext_destroy
	backend_load_font :: coretext_load_font
	backend_face :: coretext_face
	backend_shape :: coretext_shape
	backend_rasterize :: coretext_rasterize
	BACKEND_NAME :: "CoreText"
} else {
	Backend :: FreeType_Backend
	backend_init :: freetype_init
	backend_destroy :: freetype_destroy
	backend_load_font :: freetype_load_font
	backend_face :: freetype_face
	backend_shape :: freetype_shape
	backend_rasterize :: freetype_rasterize
	BACKEND_NAME :: "FreeType + HarfBuzz"
}
