# Changelog

## Unreleased

- Update action: when the base branch's flake.lock can't be read (no git
  checkout, unknown input), it says so instead of stopping with exit 128.

## 0.3.0 (2026-11-01)

Renamed from nix-holds: single packages take a detour from your nixpkgs,
held back while broken or ahead from an open nixpkgs PR, until nixpkgs
catches up.

- The repository is `kleinbem-dev/nix-detour`. Web, git and flake URLs
  redirect; GitHub Actions' `uses:` doesn't, so workflows change
  `kleinbem-dev/nix-holds@` to `kleinbem-dev/nix-detour/hold-release@` and
  `kleinbem-dev/nix-holds/<action>@` to `kleinbem-dev/nix-detour/<action>@`.
- CLI `nix-detour`: holds are under `nix-detour hold` (`add`, `remove`,
  `list`, `check`), next to `nix-detour pr`. The old top-level commands say
  where they went.
- The holds' release action is `kleinbem-dev/nix-detour/hold-release`, next
  to `pr-pin`, `pr-merged` and `update`.
- Update action (`kleinbem-dev/nix-detour/update`): on a lock-update PR, it
  finds what the update broke and holds each package on the nixpkgs before
  the update, in the same PR (`mode: commit`) or as a report. After each
  round it checks again: what still fails held is reported, not held, and a
  failure that shows up only then is held next round (up to 5).
  - What it checks: targets (`nixDetourTargets`, `lib.watch.target host`),
    where the package to hold is found in the error's trace however the host
    reaches it; and watched packages (`nixDetourWatch`, `lib.watch.nixos` or
    `lib.watch.packages`), each evaluated on its own and built when no
    substituter has it. The old output names `nixHoldsWatch` and
    `nixHoldsTargets` still work, with a warning.
  - Holds kept in another repository: `holds-repo`, `holds-input` and
    `holds-token`. It clones that repository, checks through
    `--override-input`, and in commit mode opens a PR there with only its new
    holds on top of the file as it is then.
  - `directory` and `nix-args` cover a checkout in a subfolder and flakes
    that need `--override-input`; `systems` checks other systems' hosts from
    the same runner (evaluation only).
  - Outputs `held`, `failed` and a Markdown `report`.

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
