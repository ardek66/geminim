{
  description = "Async Gemini server written in Nim";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    flake-nimble.url = "github:nix-community/flake-nimble";
  };

  outputs = { self, nixpkgs, flake-utils, flake-nimble }:
    flake-utils.lib.eachDefaultSystem (sys:
      let
        pkgs = nixpkgs.legacyPackages.${sys};
        nimblePkgs = flake-nimble.packages.${sys};
      in {
        packages.geminim = pkgs.nimPackages.buildNimPackage {
          pname = "geminim";
          version = "0.1.5";
          src = ./.;
          buildInputs = [ pkgs.openssl ];
        };

        defaultPackage = self.packages.${sys}.geminim;
      });
}
