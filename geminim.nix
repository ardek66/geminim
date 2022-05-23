{ lib, stdenv, fetchFromGitHub, nim, openssl }:
stdenv.mkDerivation rec {
  name = "geminim";
  version = "0.1.4";

  src = ./src;

  nativeBuildInputs = [ openssl nim ];

  buildPhase = "HOME=$NIX_BUILD_TOP nim c -d:release --gc:orc -d:useMalloc src/geminim.nim";
  installPhase = "install -Dt $out/bin src/geminim";
}
