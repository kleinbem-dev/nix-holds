# The overlay: every package in held-packages.json comes from the nixpkgs its
# entry names instead of the consumer's nixpkgs.
#
# "stable" is this flake's nixpkgs-stable input (consumers make it follow
# their own), which keeps getting security fixes; a rev + narHash pins a
# nixos-unstable commit, usually the last one the fleet ran. That nixpkgs
# gets `extraOverlays`, so a consumer's own packages can be held too.
# Entries the consumer's package set doesn't have are left out.
{
  nixpkgs-stable,
  extraOverlays ? [ ],
}:
_final: prev:
let
  inherit (prev) lib;
  held = lib.importJSON ./held-packages.json;

  key = from: if from == "stable" then "stable" else from.rev;
  source =
    from:
    if from == "stable" then
      nixpkgs-stable
    else
      builtins.fetchTree {
        type = "github";
        owner = "NixOS";
        repo = "nixpkgs";
        inherit (from) rev narHash;
      };

  # One package set per source, shared by the entries that use it.
  packageSets = lib.listToAttrs (
    map (from: {
      name = key from;
      value = import (source from) {
        inherit (prev.stdenv.hostPlatform) system;
        config = {
          allowUnfree = true;
          inherit (prev.config) cudaSupport rocmSupport;
        };
        overlays = extraOverlays;
      };
    }) (lib.unique (map (entry: entry.from) (lib.attrValues held)))
  );
in
lib.mapAttrs (name: entry: packageSets.${key entry.from}.${name}) (
  lib.filterAttrs (name: _: prev ? ${name}) held
)
