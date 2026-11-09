# myod's small C shim over FreeType (shim/myod_ft.c): a few flat functions, so the Odin side
# never has to mirror FreeType's struct layouts.
{ stdenv, freetype }:

stdenv.mkDerivation {
  pname = "myod-text-shim";
  version = "1";
  src = ../shim;
  dontConfigure = true;
  buildPhase = ''
    $CC -std=c11 -O2 -fPIC -I${freetype}/include/freetype2 -c myod_ft.c -o myod_ft.o
    $AR rcs libmyod_text_shim.a myod_ft.o
  '';
  installPhase = ''
    mkdir -p $out/lib
    cp libmyod_text_shim.a $out/lib/
  '';
}
