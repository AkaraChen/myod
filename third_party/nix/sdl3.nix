# SDL3 as a static library, built from source.
#
# Only the subsystems a UI library needs are kept: video, events, clipboard, file dialogs, etc.
# Audio, camera, joystick, haptics, sensors, and SDL's own GPU and 2D render APIs are disabled,
# which cuts dependencies and the number of system frameworks to link.
{ lib
, stdenv
, fetchurl
, cmake
, ninja
, pkg-config
, source
  # Linux: SDL loads X11 / Wayland with dlopen at runtime; the build only needs headers and wayland-scanner
, wayland
, wayland-scanner
, wayland-protocols
, libxkbcommon
, libdecor
, xorg
, dbus
}:

stdenv.mkDerivation {
  pname = "sdl3-static";
  version = source.version;

  src = fetchurl {
    url = source.url;
    hash = source.hash;
  };

  nativeBuildInputs = [ cmake ninja ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [ pkg-config wayland-scanner ];

  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    wayland
    wayland-protocols
    libxkbcommon
    libdecor
    dbus
    xorg.libX11
    xorg.libXext
    xorg.libXcursor
    xorg.libXi
    xorg.libXfixes
    xorg.libXrandr
    xorg.libXScrnSaver
  ];

  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
    "-DSDL_SHARED=OFF"
    "-DSDL_STATIC=ON"
    "-DSDL_TEST_LIBRARY=OFF"
    "-DSDL_TESTS=OFF"
    "-DSDL_EXAMPLES=OFF"
    "-DSDL_INSTALL_DOCS=OFF"

    "-DSDL_AUDIO=OFF"
    "-DSDL_CAMERA=OFF"
    "-DSDL_JOYSTICK=OFF"
    "-DSDL_HAPTIC=OFF"
    "-DSDL_HIDAPI=OFF"
    "-DSDL_SENSOR=OFF"
    "-DSDL_GPU=OFF"
    "-DSDL_RENDER=OFF"
  ];
}
