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
        wgpu-native = pkgs.callPackage ./nix/wgpu-native.nix {
          source = sources.wgpu_native;
          inherit system;
        };

        # Fonts are platform-independent; they go into fonts/
        fonts = pkgs.callPackage ./nix/fonts.nix { source = sources.dwg; };

        # Everything that goes into prebuilt/<platform>/
        prebuilt = pkgs.runCommand "myod-prebuilt-${platforms.${system}}" { } ''
          mkdir -p $out
          cp ${sdl3}/lib/libSDL3.a $out/
          cp ${wgpu-native}/lib/libwgpu_native.a $out/
          chmod 644 $out/*.a
          cd $out && sha256sum *.a > SHA256SUMS
        '';

        default = prebuilt;
      });
    };
}
