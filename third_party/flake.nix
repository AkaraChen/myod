{
  description = "Third-party dependencies of myod: builds the per-platform static libraries listed in sources.toml";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      sources = builtins.fromTOML (builtins.readFile ./sources.toml);

      # Nix system name -> directory name under prebuilt/
      platforms = {
        aarch64-darwin = "macos-arm64";
        x86_64-linux = "linux-x86_64";
        aarch64-linux = "linux-arm64";
      };

      forAll = f: nixpkgs.lib.genAttrs (builtins.attrNames platforms)
        (system: f system nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAll (system: pkgs: rec {
        sdl3 = pkgs.callPackage ./nix/sdl3.nix { source = sources.sdl3; };
        zlib = pkgs.callPackage ./nix/zlib.nix { source = sources.zlib; };
        libpng = pkgs.callPackage ./nix/libpng.nix { source = sources.libpng; inherit zlib; };
        freetype = pkgs.callPackage ./nix/freetype.nix { source = sources.freetype; inherit libpng zlib; };
        harfbuzz = pkgs.callPackage ./nix/harfbuzz.nix { source = sources.harfbuzz; inherit freetype; };
        text-shim = pkgs.callPackage ./nix/text-shim.nix { inherit freetype; nanosvg = sources.nanosvg; };
        libunibreak = pkgs.callPackage ./nix/libunibreak.nix { source = sources.libunibreak; };
        wgpu-native = pkgs.callPackage ./nix/wgpu-native.nix {
          source = sources.wgpu_native;
          inherit system;
        };

        # Fonts are platform-independent; they go into fonts/
        fonts = pkgs.callPackage ./nix/fonts.nix { source = sources.dwg; };
        phosphor = pkgs.callPackage ./nix/phosphor.nix { source = sources.phosphor; };

        # Everything that goes into prebuilt/<platform>/
        prebuilt = pkgs.runCommand "myod-prebuilt-${platforms.${system}}" { } ''
          mkdir -p $out
          cp ${sdl3}/lib/libSDL3.a $out/
          cp ${wgpu-native}/lib/libwgpu_native.a $out/
          cp ${freetype}/lib/libfreetype.a $out/
          cp ${libpng}/lib/libpng16.a $out/
          cp ${zlib}/lib/libz.a $out/
          cp ${harfbuzz}/lib/libharfbuzz.a $out/
          cp ${text-shim}/lib/libmyod_text_shim.a $out/
          cp ${libunibreak}/lib/libunibreak.a $out/
          chmod 644 $out/*.a
          cd $out && sha256sum *.a > SHA256SUMS
        '';

        default = prebuilt;
      });
    };
}
