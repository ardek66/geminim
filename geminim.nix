{ lib, stdenv, fetchFromGitHub, nim, openssl }:
stdenv.mkDerivation rec {
  name = "geminim";
  version = "0.1.4";

  src = fetchFromGitHub {
    owner = "ardek66";
    repo = "geminim";
    rev = "master";
    sha256 = "1hc6fpzx7sznni56nhmcb9y5q4z3zjaky2gmk3lfsrf82cxjjakx";
  };

  nativeBuildInputs = [ openssl nim ];

  buildPhase = "HOME=$NIX_BUILD_TOP nim c -d:release --gc:orc -d:useMalloc src/geminim.nim";
  installPhase = "install -Dt $out/bin src/geminim";
}
