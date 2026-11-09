# HarfBuzz as a static library, built from its single-file amalgamation (src/harfbuzz.cc)
# with FreeType support (hb-ft).
{ stdenv, fetchurl, source, freetype }:

stdenv.mkDerivation {
  pname = "harfbuzz-static";
  version = source.version;
  src = fetchurl { url = source.url; hash = source.hash; };
  dontConfigure = true;
  buildPhase = ''
    $CXX -std=c++17 -O2 -fPIC -fno-exceptions -fno-rtti -fno-threadsafe-statics \
      -DHAVE_FREETYPE=1 -I${freetype}/include/freetype2 \
      -c src/harfbuzz.cc -o harfbuzz.o
    $AR rcs libharfbuzz.a harfbuzz.o
  '';
  installPhase = ''
    mkdir -p $out/lib $out/include/harfbuzz
    cp libharfbuzz.a $out/lib/
    cp src/hb*.h $out/include/harfbuzz/
  '';
}
