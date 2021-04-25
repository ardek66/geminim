{ crossSystem ? "" }:
with
  if crossSystem == "" then
    import <unstable> {}
  else
    import <unstable> { crossSystem.system = crossSystem; };

callPackage ./geminim.nix {}
