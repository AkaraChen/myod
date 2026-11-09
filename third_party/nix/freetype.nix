# FreeType as a static library, built from source.
#
# Optional dependencies (zlib, bzip2, PNG, Brotli, HarfBuzz) are off for now: the fonts myod
# ships are plain TrueType. PNG (for CBDT color emoji) comes with color glyph support on Linux.
{ stdenv, fetchurl, cmake, ninja, source }:

stdenv.mkDerivation {
  pname = "freetype-static";
  version = source.version;
  src = fetchurl { url = source.url; hash = source.hash; };
  nativeBuildInputs = [ cmake ninja ];
  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
    "-DBUILD_SHARED_LIBS=OFF"
    "-DFT_DISABLE_ZLIB=ON"
    "-DFT_DISABLE_BZIP2=ON"
    "-DFT_DISABLE_PNG=ON"
    "-DFT_DISABLE_HARFBUZZ=ON"
    "-DFT_DISABLE_BROTLI=ON"
  ];
  # The generated freetype2.pc has malformed paths and nothing here uses pkg-config.
  postInstall = "rm -rf $out/lib/pkgconfig";
}
