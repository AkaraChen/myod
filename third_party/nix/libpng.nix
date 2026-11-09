# libpng as a static library: FreeType needs it for color emoji stored as PNG (sbix, CBDT).
{ stdenv, fetchurl, cmake, ninja, source, zlib }:

stdenv.mkDerivation {
  pname = "libpng-static";
  version = source.version;
  src = fetchurl { url = source.url; hash = source.hash; };
  nativeBuildInputs = [ cmake ninja ];
  buildInputs = [ zlib ];
  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
    "-DPNG_SHARED=OFF"
    "-DPNG_STATIC=ON"
    "-DPNG_TESTS=OFF"
    "-DPNG_TOOLS=OFF"
    "-DPNG_FRAMEWORK=OFF"
    "-DZLIB_ROOT=${zlib}"
  ];
  postInstall = "rm -rf $out/lib/pkgconfig $out/share $out/bin";
}
