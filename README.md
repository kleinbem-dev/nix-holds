# nix-holds

Hold packages back from nixos-unstable while they're broken there.

When one package breaks in nixos-unstable, it stays on a nixpkgs where it
works, and everything else moves on. Without this, the whole lock update
stops until the package is fixed. Each hold says why and where the fix is,
and goes away once the package builds from nixos-unstable again.

An example of it in use:
[kleinbem/nix-holds-fleet](https://github.com/kleinbem/nix-holds-fleet).

## How it works

`held-packages.json` lists each held package:

| Field | Meaning |
|---|---|
| `from` | `"stable"` (the nixpkgs-stable input, which keeps getting security fixes) or `{ rev, narHash }`, a pinned nixos-unstable commit, usually the last one you ran |
| `since` | when the hold started |
| `releaseWhen` | optional: the nixpkgs attribute whose repair ends the hold (default: the package itself), e.g. the broken dependency of one of our own packages |
| `reason`, `link` | why, and the upstream issue or PR that fixes it |
| `tests` | optional: the `nixosTests` to run with the hold (default: `nixosTests.<name>`, if nixpkgs has it; `[]` for none) |

The overlay replaces each held package with the one from its `from` nixpkgs.
Packages a consumer's package set doesn't have are left out.

## Using it

Keep your holds in your own repo, in a `held-packages.json` as above:

```nix
inputs.nix-holds = {
  url = "github:kleinbem-dev/nix-holds";
  inputs.nixpkgs.follows = "nixpkgs";
  inputs.nixpkgs-stable.follows = "nixpkgs-stable";
};

# outputs
let
  holds = inputs.nix-holds.lib.mkHolds {
    holds = ./held-packages.json;
    inherit (inputs) nixpkgs-stable;
    # Your own package overlays, so your packages can be held too.
    extraOverlays = [ inputs.my-packages.overlays.default ];
  };
in
{
  # NixOS: nixpkgs.overlays = [ holds.overlay ];  (after your own overlays)
  releaseChecks = forAllSystems (pkgs: holds.releaseChecks pkgs);
}
```

The held package sets get your nixpkgs config: `allowUnfree`, insecure
packages, CUDA/ROCm and the other common settings are taken from the package
set the overlay is applied to. Pass `config` to `mkHolds` to set them
yourself.

`mkHolds` returns:

- `overlay`: the held packages
- `nixosTests pkgs`: the nixpkgs NixOS tests of the held packages (see below)
- `releaseChecks pkgs`: what ends each hold (`releaseWhen`), from a package
  set without the holds but with your overlays

## The CLI

```sh
nix run github:kleinbem-dev/nix-holds -- add open-webui \
  --reason "chromadb needs posthog, broken since mcp 2" \
  --link https://github.com/NixOS/nixpkgs/pull/578265 \
  --release-when python3Packages.posthog
nix run github:kleinbem-dev/nix-holds -- list
nix run github:kleinbem-dev/nix-holds -- check   # which holds can go
```

`add` holds a package on the nixpkgs your `flake.lock` had before its last
nixpkgs update, read from git history: the usual case right after an update
broke it. `--from stable` or `--from <rev>` choose another. `remove` drops a
hold, and `check` runs the release checks locally. `--file`, `--lock` and
`--input` point it at another holds file, lock or nixpkgs input.

## Lifecycle

1. **Hold:** `nix-holds add` in a PR, with the reason and the upstream link.
2. **Release:** the release action (`uses: kleinbem-dev/nix-holds@<sha> # v0.1.0`,
   after installing Nix) builds each release check from nixos-unstable and
   opens a PR removing the hold once it builds. Its `stale` output lists the holds
   older than 14 days, for your own alert. A consumer whose nixpkgs is older
   keeps failing its lock check until it catches up, so nothing breaks in
   between.
3. **Alert:** a hold older than 14 days misses the fixes of the newer
   nixpkgs; alert on the action's `stale` output (nix-holds-fleet's weekly
   workflow sends it to ntfy).

Evaluate the held packages in your CI and build them where you use them:
you may adjust a held package on top (a wrapper fix, a patch), and that is
the package you deploy.

A held package runs under the NixOS module of the consumer's current nixpkgs,
and a module that expects a newer package only fails at runtime.
`nixosTests pkgs` gives the nixpkgs NixOS tests of the held packages
(`tests`, see above) from a package set with the holds applied; run them in
your CI with your own overlays on top, since that is the package you deploy:

```nix
checks.${system} = holds.nixosTests (import nixpkgs {
  inherit system;
  overlays = yourOverlays ++ [ holds.overlay ];
});
```

Each pinned commit is another full package set at evaluation time; keep
holds few and short.

Don't hold packages the standard environment is built from (on darwin, jq
is one): the darwin stdenv checks that its bootstrap tools come from one
compiler, and evaluation fails.

## Not here

Fixes that change a package (a patch, a skipped test) stay in the consumer
that needs them. This repo only chooses which nixpkgs a package comes from.
