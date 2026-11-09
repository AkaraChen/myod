# myod's Rust code (ffi/: the Taffy wrapper, later AccessKit) as one static library. Dependencies
# are pinned by ffi/Cargo.lock and vendored by Nix; paths are remapped and debug info stripped so
# the archive is reproducible and small.
#
# wgpu-native is a Rust static library too, with its own copy of the Rust standard library, so both
# define symbols like rust_eh_personality. The archive is therefore pre-linked into one object
# (`ld -r`) that exports only the functions in ffi/exports.txt; everything else becomes local.
{ stdenv, lib, rustPlatform, cargo, rustc }:

let
  src = lib.cleanSourceWith {
    src = ../../ffi;
    filter = path: type: !(lib.hasInfix "/target" path);
  };
in

stdenv.mkDerivation {
  pname = "myod-ffi";
  version = "0.1.0";
  inherit src;
  cargoDeps = rustPlatform.importCargoLock { lockFile = ../../ffi/Cargo.lock; };
  nativeBuildInputs = [ rustPlatform.cargoSetupHook cargo rustc ];
  dontConfigure = true;
  buildPhase = ''
    export RUSTFLAGS="--remap-path-prefix=$PWD=/myod/ffi --remap-path-prefix=$NIX_BUILD_TOP=/build --remap-path-prefix=${rustc.unwrapped or rustc}=/rustc"
    cargo build --release --frozen --lib
  '';
  installPhase = ''
    mkdir objs
    (cd objs && $AR x ../target/release/libmyod_ffi.a)
  '' + (if stdenv.hostPlatform.isDarwin then ''
    sed 's/^/_/' exports.txt > exports.darwin
    ld -r -arch arm64 -exported_symbols_list exports.darwin -o myod_ffi.o objs/*.o
    strip -S myod_ffi.o
  '' else ''
    $LD -r -o myod_ffi.o objs/*.o
    $OBJCOPY --keep-global-symbols=exports.txt --strip-debug myod_ffi.o
  '') + ''
    mkdir -p $out/lib
    $AR rcs $out/lib/libmyod_ffi.a myod_ffi.o
  '';
  dontStrip = true;
  dontFixup = true;
}
