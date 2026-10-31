# The overlay: every held package comes from the nixpkgs its entry names
# instead of the consumer's nixpkgs.
#
# "stable" is the consumer's nixpkgs-stable, which keeps getting security
# fixes; a rev + narHash pins a nixos-unstable commit, usually the last one
# the consumer ran. That nixpkgs gets `extraOverlays`, so a consumer's own
# packages can be held too, and the consumer's nixpkgs config: `config` if
# given, else the settings in `carriedConfig` taken from the consumer's
# package set (its whole evaluated config doesn't type-check in another
# nixpkgs). Entries the consumer's package set doesn't have are left out.
{
  holds,
  nixpkgs-stable,
  extraOverlays ? [ ],
  config ? null,
}:
_final: prev:
let
  inherit (prev) lib;

  carriedConfig = [
    "allowAliases"
    "allowBroken"
    "allowInsecurePredicate"
    "allowNonSource"
    "allowNonSourcePredicate"
    "allowUnfree"
    "allowUnfreePackages"
    "allowUnfreePredicate"
    "allowUnsupportedSystem"
    "allowlistedLicenses"
    "blocklistedLicenses"
    "cudaCapabilities"
    "cudaForwardCompat"
    "cudaSupport"
    "permittedInsecurePackages"
    "rocmSupport"
  ];

  key = from: if from == "stable" then "stable" else from.rev;
  # fetchTarball, not builtins.fetchTree, which needs the flakes feature.
  source =
    from:
    if from == "stable" then
      nixpkgs-stable
    else
      builtins.fetchTarball {
        url = "https://github.com/NixOS/nixpkgs/archive/${from.rev}.tar.gz";
        sha256 = from.narHash;
      };

  # One package set per source, shared by the entries that use it.
  packageSets = lib.listToAttrs (
    map (from: {
      name = key from;
      value = import (source from) {
        inherit (prev.stdenv.hostPlatform) system;
        config =
          if config != null then
            config
          else
            lib.getAttrs (lib.filter (n: prev.config ? ${n}) carriedConfig) prev.config;
        overlays = extraOverlays;
      };
    }) (lib.unique (map (entry: entry.from) (lib.attrValues holds)))
  );
in
lib.mapAttrs (name: entry: packageSets.${key entry.from}.${name}) (
  lib.filterAttrs (name: _: prev ? ${name}) holds
)
