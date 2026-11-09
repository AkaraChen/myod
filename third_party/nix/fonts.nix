# Fonts shipped with myod, taken from pinned upstream releases. Platform-independent.
{ fetchzip, runCommand, lib, source }:

let
  release = fetchzip {
    url = source.url;
    hash = source.hash;
    stripRoot = false;
  };
in
runCommand "myod-fonts-${source.version}" { } ''
  mkdir -p $out
  ${lib.concatMapStringsSep "\n" (f: "cp ${release}/${f} $out/") source.files}
  chmod 644 $out/*
  cd $out && sha256sum * > SHA256SUMS
''
