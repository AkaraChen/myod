# Phosphor icon SVGs (MIT), one directory per weight, plus the license. Platform-independent.
{ fetchzip, runCommand, source }:

let
  release = fetchzip { url = source.url; hash = source.hash; };
in
runCommand "myod-phosphor-${source.version}" { } ''
  mkdir -p $out
  cp -r ${release}/assets/. $out/
  cp ${release}/LICENSE $out/LICENSE
  chmod -R u+w $out
''
