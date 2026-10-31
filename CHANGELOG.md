# Changelog

## 0.1.0 (unreleased)

First version for use outside the kleinbem fleet.

- `lib.mkHolds { holds, nixpkgs-stable, extraOverlays, config }`: your own
  holds file gives `overlay`, `nixosTests` and `releaseChecks`.
- The held package sets get your nixpkgs config (allowUnfree, insecure
  packages, CUDA/ROCm, ...) instead of a forced `allowUnfree = true`.
- Release checks build with your own overlays, so holds of your own
  packages can be released too.
- Release action (`uses: kleinbem-dev/nix-holds@<sha>`): opens a PR per hold that
  can go; its `stale` output lists the old ones.
- CLI: `nix-holds add`, `remove`, `list`, `check`.
- Pinned revisions are fetched with `fetchTarball`, so the overlay works
  without the flakes feature.
- Removed: the kleinbem fleet's own holds and the outputs built from them
  (`overlays.default`, `lib.mkOverlay`, `lib.nixosTests`); they live in
  kleinbem/nix-holds-fleet.
