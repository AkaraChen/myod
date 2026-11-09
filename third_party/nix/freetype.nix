# FreeType as a static library, built from source.
#
# PNG is on, for color emoji stored as PNG bitmaps (Apple's sbix, Google's CBDT). The other optional
# dependencies (zlib for gzip fonts, bzip2, Brotli for WOFF2, HarfBuzz autohinting) stay off.
{ stdenv, fetchurl, cmake, ninja, source, libpng, zlib }:

stdenv.mkDerivation {
  pname = "freetype-static";
  version = source.version;
  src = fetchurl { url = source.url; hash = source.hash; };
  nativeBuildInputs = [ cmake ninja ];
  buildInputs = [ libpng zlib ];
  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
    "-DBUILD_SHARED_LIBS=OFF"
    "-DFT_DISABLE_ZLIB=ON"
    "-DFT_DISABLE_BZIP2=ON"
    "-DFT_REQUIRE_PNG=ON"
    "-DPNG_ROOT=${libpng}"
    "-DZLIB_ROOT=${zlib}"
    "-DFT_DISABLE_HARFBUZZ=ON"
    "-DFT_DISABLE_BROTLI=ON"
  ];
  # The generated freetype2.pc has malformed paths and nothing here uses pkg-config.
  postInstall = "rm -rf $out/lib/pkgconfig";
}
