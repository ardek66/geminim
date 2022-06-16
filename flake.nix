{
  description = "Async Gemini server written in Nim";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    flake-nimble.url = "github:nix-community/flake-nimble";
  };

  outputs = { self, nixpkgs, flake-utils, flake-nimble }:
    flake-utils.lib.eachDefaultSystem (sys:
      let pkgs = nixpkgs.legacyPackages.${sys}; in
      rec {
        overlays.default = final: prev: {
          nimPackages = prev.nimPackages.overrideScope' (nimfinal: nimprev: {
            stew = pkgs.nimPackages.stew;
            
            chronos = nimprev.chronos.overrideAttrs (oldAttrs: {
              inherit (nimprev.chronos) pname version src;
              doCheck = false;
            });
          });
        };
        
        pkgsWithNimble = pkgs.appendOverlays [ flake-nimble.overlay overlays.default ];
        
        packages = flake-utils.lib.flattenTree {
          chronos = pkgsWithNimble.nimPackages.chronos;
          openssl = pkgs.openssl;

          nim = pkgs.nim;
          nimlsp = pkgs.nimlsp;

          geminim = pkgs.nimPackages.buildNimPackage {
            pname = "geminim";
            version = "0.1.5";
            src = ./.;
            nativeBuildInputs = with packages; [ chronos openssl ];
          };
        };
        
        defaultPackage = packages.geminim;

        devShell = pkgs.mkShell {
          nativeBuildInputs = with packages; [ nim nimlsp ];
        };
      });
}
