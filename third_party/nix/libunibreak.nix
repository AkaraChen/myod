# libunibreak (zlib license) as a static library: UAX #14 line breaking, UAX #29 grapheme and
# word breaking.
{ stdenv, fetchzip, source }:

stdenv.mkDerivation {
  pname = "libunibreak-static";
  version = source.version;
  src = fetchzip { url = source.url; hash = source.hash; };
  dontConfigure = true;
  buildPhase = ''
    cd src
    for f in *.c; do
      [ "$f" = tests.c ] && continue
      $CC -std=c99 -O2 -fPIC -c "$f" -o "''${f%.c}.o"
    done
    $AR rcs libunibreak.a *.o
  '';
  installPhase = ''
    mkdir -p $out/lib
    cp libunibreak.a $out/lib/
  '';
}
