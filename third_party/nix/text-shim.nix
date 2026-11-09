# myod's small C shims: over FreeType (shim/myod_ft.c), so the Odin side never mirrors FreeType's
# struct layouts; and over nanosvg (shim/myod_svg.c), which compiles nanosvg's header-only sources.
{ stdenv, fetchzip, freetype, nanosvg }:

let
  nanosvg-src = fetchzip { url = nanosvg.url; hash = nanosvg.hash; };
in

stdenv.mkDerivation {
  pname = "myod-text-shim";
  version = "1";
  src = ../shim;
  dontConfigure = true;
  buildPhase = ''
    $CC -std=c11 -O2 -fPIC -I${freetype}/include/freetype2 -c myod_ft.c -o myod_ft.o
    $CC -std=c11 -O2 -fPIC -I${nanosvg-src}/src -c myod_svg.c -o myod_svg.o
    $AR rcs libmyod_text_shim.a myod_ft.o myod_svg.o
  '';
  installPhase = ''
    mkdir -p $out/lib
    cp libmyod_text_shim.a $out/lib/
  '';
}
