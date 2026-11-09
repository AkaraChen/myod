# wgpu-native as a static library.
#
# For now this uses the upstream prebuilt release as is (build = "upstream-release" in sources.toml)
# and only checks its hash. It will be built from source with Nix later.
{ fetchzip, runCommand, source, system }:

let
  artifact = source.artifacts.${system};
  release = fetchzip {
    url = artifact.url;
    hash = artifact.hash;
    stripRoot = false;
  };
in
runCommand "wgpu-native-${source.version}" { } ''
  mkdir -p $out/lib
  cp ${release}/lib/libwgpu_native.a $out/lib/
''
