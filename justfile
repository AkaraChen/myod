set shell := ["bash", "-euo", "pipefail", "-c"]

# Nix is only needed to rebuild third-party libraries; MYOD_NIX can point at the nix binary
nix := env("MYOD_NIX", "nix") + " --extra-experimental-features 'nix-command flakes'"

# Directory name of the current platform under third_party/prebuilt/
platform := if os() == "macos" {
    if arch() == "aarch64" { "macos-arm64" } else { "unsupported" }
} else if os() == "linux" {
    if arch() == "x86_64" { "linux-x86_64" } else if arch() == "aarch64" { "linux-arm64" } else { "unsupported" }
} else { "unsupported" }

odin_flags := "-collection:myod=. -vet -strict-style"

default:
    @just --list

# Build and run an example, e.g. `just run 00_clear`
run example *args:
    mkdir -p build
    odin build examples/{{example}} {{odin_flags}} -out:build/{{example}} {{args}}
    ./build/{{example}}

# Build an example
build example *args:
    mkdir -p build
    odin build examples/{{example}} {{odin_flags}} -out:build/{{example}} {{args}}

# Run the automated self-tests (offscreen rendering with pixel checks)
test:
    mkdir -p build
    odin build examples/01_rects {{odin_flags}} -out:build/01_rects
    ./build/01_rects --selftest
    odin build examples/02_text {{odin_flags}} -out:build/02_text
    ./build/02_text --selftest
    odin build examples/02_text {{odin_flags}} -define:MYOD_TEXT_BACKEND=freetype -out:build/02_text_freetype
    ./build/02_text_freetype --selftest
    odin build examples/02_sprites {{odin_flags}} -out:build/02_sprites
    ./build/02_sprites --selftest
    odin build examples/02_icons {{odin_flags}} -out:build/02_icons
    ./build/02_icons --selftest
    odin test core {{odin_flags}} -out:build/core_test
    odin build examples/03_layout {{odin_flags}} -out:build/03_layout
    ./build/03_layout --selftest
    odin build examples/03_feed {{odin_flags}} -out:build/03_feed
    ./build/03_feed --selftest
    odin build examples/03_long_form {{odin_flags}} -out:build/03_long_form
    ./build/03_long_form --selftest

# Unit tests of the Rust wrapper (needs a Rust toolchain; users never do)
test-ffi:
    cd ffi && cargo test --release

# The M3 performance benchmark, optimized build
bench:
    mkdir -p build
    odin build examples/03_long_form {{odin_flags}} -o:speed -out:build/03_long_form_speed
    ./build/03_long_form_speed --bench

# Type-check every example
check:
    for d in examples/*/; do echo "check $d"; odin check "$d" {{odin_flags}}; done

# Rebuild the third-party static libraries with Nix into third_party/prebuilt/<platform>/
vendor:
    cd third_party && {{nix}} build .#prebuilt -o ../build/prebuilt-{{platform}}
    rm -rf third_party/prebuilt/{{platform}}
    mkdir -p third_party/prebuilt/{{platform}}
    cp build/prebuilt-{{platform}}/* third_party/prebuilt/{{platform}}/
    chmod 644 third_party/prebuilt/{{platform}}/*
    cd third_party && {{nix}} build .#fonts -o ../build/fonts
    rm -rf third_party/fonts && mkdir -p third_party/fonts
    cp build/fonts/* third_party/fonts/ && chmod 644 third_party/fonts/*
    cd third_party && {{nix}} build .#phosphor -o ../build/phosphor
    rm -rf third_party/phosphor && cp -r build/phosphor third_party/phosphor && chmod -R u+w third_party/phosphor
    python3 -I third_party/scripts/gen_phosphor.py third_party/phosphor icons/phosphor/phosphor.odin

# Check that the committed static libraries are byte-for-byte identical to the Nix build
verify:
    cd third_party && {{nix}} build .#prebuilt -o ../build/prebuilt-{{platform}}
    diff -r build/prebuilt-{{platform}} third_party/prebuilt/{{platform}}
    cd third_party/prebuilt/{{platform}} && shasum -a 256 -c SHA256SUMS
    cd third_party && {{nix}} build .#fonts -o ../build/fonts
    diff -r build/fonts third_party/fonts
    cd third_party && {{nix}} build .#phosphor -o ../build/phosphor
    diff -r build/phosphor third_party/phosphor
    @echo "third_party/prebuilt/{{platform}}, fonts and phosphor are byte-for-byte identical to the Nix build"

# Force a rebuild to confirm the build itself is deterministic
verify-rebuild:
    cd third_party && {{nix}} build .#sdl3 .#zlib .#libpng .#freetype .#harfbuzz .#text-shim .#libunibreak .#ffi --rebuild

# Re-sync the SDL3 and wgpu bindings from Odin's vendor directory
bindings:
    python3 -I third_party/scripts/sync_bindings.py "$(odin root)" third_party
