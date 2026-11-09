// Icon types. The Phosphor icon set lives in icons/phosphor (generated); rasterization and drawing
// go through the text package, which owns the atlases.
package icons

Weight :: enum u8 {
	Thin,
	Light,
	Regular,
	Bold,
	Fill,
	Duotone,
}

// An SVG icon in every weight. Phosphor icons use a 256×256 view box.
Icon :: struct {
	name: string,
	svg:  [Weight]string,
}
