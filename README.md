# nix-holds

Packages the kleinbem fleet holds back from nixos-unstable.

When one package breaks in nixos-unstable, it stays on a nixpkgs where it
works, and everything else moves on. Without this, the fleet's whole lock
update stops until the package is fixed.

## How it works

`held-packages.json` lists each held package:

| Field | Meaning |
|---|---|
| `from` | `"stable"` (the nixpkgs-stable input, which keeps getting security fixes) or `{ rev, narHash }`, a pinned nixos-unstable commit, usually the last one the fleet ran |
| `since` | when the hold started |
| `releaseWhen` | optional: the nixpkgs attribute whose repair ends the hold (default: the package itself), e.g. the broken dependency of one of our own packages |
| `reason`, `link` | why, and the upstream issue or PR that fixes it |
| `tests` | optional: the `nixosTests` to run with the hold (default: `nixosTests.<name>`, if nixpkgs has it; `[]` for none) |

The overlay replaces each held package with the one from its `from` nixpkgs.
Packages a consumer's package set doesn't have are left out.

## Using it

```nix
inputs.nix-holds = {
  url = "github:kleinbem/nix-holds";
  inputs.nixpkgs-stable.follows = "nixpkgs-stable";
};
```

- Plain: `nixpkgs.overlays = [ inputs.nix-holds.overlays.default ];`
- With your own packages, so they can be held too:
  `inputs.nix-holds.lib.mkOverlay { extraOverlays = [ inputs.nix-packages.overlays.default ]; }`,
  placed after those overlays.

## Lifecycle

1. **Hold:** a PR adding an entry, with the reason and the upstream link.
2. **Release:** the weekly `release` workflow builds each hold's cause
   (`releaseWhen`) from nixos-unstable and opens a PR removing the hold once
   it builds. A consumer whose nixpkgs is older keeps failing its lock check
   until it catches up, so nothing breaks in between.
3. **Alert:** a hold older than 14 days alerts via ntfy: the package misses
   the fixes of the newer nixpkgs.

The `check` only evaluates the held packages and their NixOS tests: a
consumer may adjust a held package (the open-webui container fixes its
wrapper), so the consumer's own CI builds the real thing.

A held package runs under the NixOS module of the consumer's current nixpkgs,
and a module that expects a newer package only fails at runtime.
`lib.nixosTests pkgs` gives the nixpkgs NixOS tests of the held packages
(`tests`, see above) from a package set with the holds applied; run them in
your CI with your own overlays on top, since that is the package you deploy:

```nix
checks.${system} = inputs.nix-holds.lib.nixosTests (import nixpkgs {
  inherit system;
  overlays = [ inputs.nix-holds.overlays.default ] ++ yourOverlays;
});
```

Each pinned commit is another full package set at evaluation time; keep
holds few and short.

## Not here

Fixes that change a package (a patch, a skipped test) stay in the consumer
that needs them. This repo only chooses which nixpkgs a package comes from.
