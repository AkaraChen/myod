# zlib as a static library (for libpng).
{ stdenv, fetchurl, cmake, ninja, source }:

stdenv.mkDerivation {
  pname = "zlib-static";
  version = source.version;
  src = fetchurl { url = source.url; hash = source.hash; };
  nativeBuildInputs = [ cmake ninja ];
  cmakeFlags = [ "-DCMAKE_BUILD_TYPE=Release" "-DZLIB_BUILD_SHARED=OFF" "-DZLIB_BUILD_TESTING=OFF" ];
  postInstall = "rm -rf $out/lib/pkgconfig $out/share";
}
