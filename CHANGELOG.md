# Changelog

## Unreleased

- Update action (`kleinbem-dev/nix-holds/update`): on a lock-update PR, finds
  the watched packages that fail (evaluated one by one, built when no
  substituter has them) and holds each on the nixpkgs before the update, in
  the same PR (`mode: commit`) or as a report. Packages that still fail when
  held are reported, not held.
- `lib.watch.nixos` and `lib.watch.packages`: the top-level packages a
  configuration uses, for the update action (`nixHoldsWatch.<system>`).

## 0.2.0 (2026-11-01)

- Packages from open nixpkgs PRs: `lib.mkPrs { prs }` (or plain
  `import ./prs.nix`) builds the packages and NixOS modules of the PRs in a
  `nixpkgs-prs.json` against your nixpkgs (`overlay`, `packages`,
  `nixosModules`, `checks`).
- CLI: `nix-holds pr add`, `pin`, `remove`, `list`, `eval`, `merged`.
- Actions: `kleinbem-dev/nix-holds/pr-pin` pins an entry and opens the PR;
  `kleinbem-dev/nix-holds/pr-merged` opens a PR removing each entry nixpkgs
  has caught up with.

## 0.1.0 (2026-10-31)

First version for use outside the kleinbem fleet.

- `lib.mkHolds { holds, nixpkgs-stable, extraOverlays, config }`: your own
  holds file gives `overlay`, `nixosTests` and `releaseChecks`.
- The held package sets get your nixpkgs config (allowUnfree, insecure
  packages, CUDA/ROCm, ...) instead of a forced `allowUnfree = true`.
- Release checks build with your own overlays, so holds of your own
  packages can be released too.
- Release action (`uses: kleinbem-dev/nix-holds@<sha>`): opens a PR per hold that
  can go; its `stale` output lists the old ones.
- CLI: `nix-holds add`, `remove`, `list`, `check`
  (`nix run github:kleinbem-dev/nix-holds`), for Linux and aarch64-darwin.
- Release checks carry their hold (`nixHolds`), so `check` and the action
  read the holds the flake actually uses.
- Pinned revisions are fetched with `fetchTarball`, so the overlay works
  without the flakes feature.
- Removed: the kleinbem fleet's own holds and the outputs built from them
  (`overlays.default`, `lib.mkOverlay`, `lib.nixosTests`); they live in
  kleinbem/nix-holds-fleet.
