# nix-detour

Single packages take a detour from your nixpkgs, and come back on their own
once nixpkgs catches up:

- **Hold:** a package that broke in nixos-unstable stays on a nixpkgs where
  it works, and everything else moves on. Without this, the whole lock
  update stops until the package is fixed. The [update
  action](#holding-automatically-on-a-lock-update) adds holds by itself when
  a lock update breaks something.
- **Ahead:** a package that only exists on an open nixpkgs PR (often your
  own) runs from that PR, pinned, [before it
  lands](#packages-from-open-nixpkgs-prs).

Each detour says why and where the fix is, and goes away once nixpkgs has
it: the hold-release and pr-merged actions open the PRs that end them.

(Renamed from nix-holds on 2026-11-01. Web, git and flake URLs redirect,
but GitHub Actions' `uses:` doesn't: in your workflows,
`kleinbem-dev/nix-holds@` becomes `kleinbem-dev/nix-detour/hold-release@`,
and `kleinbem-dev/nix-holds/<action>@` becomes
`kleinbem-dev/nix-detour/<action>@`.)

An example of it in use:
[kleinbem/nix-detour-fleet](https://github.com/kleinbem/nix-detour-fleet).

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
inputs.nix-detour = {
  url = "github:kleinbem-dev/nix-detour";
  inputs.nixpkgs.follows = "nixpkgs";
  inputs.nixpkgs-stable.follows = "nixpkgs-stable";
};

# outputs
let
  holds = inputs.nix-detour.lib.mkHolds {
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
nix run github:kleinbem-dev/nix-detour -- hold add open-webui \
  --reason "chromadb needs posthog, broken since mcp 2" \
  --link https://github.com/NixOS/nixpkgs/pull/578265 \
  --release-when python3Packages.posthog
nix run github:kleinbem-dev/nix-detour -- hold list
nix run github:kleinbem-dev/nix-detour -- hold check   # which holds can go
```

`hold add` holds a package on the nixpkgs your `flake.lock` had before its last
nixpkgs update, read from git history: the usual case right after an update
broke it. `--from stable` or `--from <rev>` choose another. `hold remove` drops a
hold, and `hold check` runs the release checks locally. `--file`, `--lock` and
`--input` point it at another holds file, lock or nixpkgs input.

## Lifecycle

1. **Hold:** `nix-detour hold add` in a PR, with the reason and the upstream link.
2. **Release:** the hold-release action (`uses: kleinbem-dev/nix-detour/hold-release@<sha>`,
   after installing Nix) builds each release check from nixos-unstable and
   opens a PR removing the hold once it builds. Its `stale` output lists the holds
   older than 14 days, for your own alert. A consumer whose nixpkgs is older
   keeps failing its lock check until it catches up, so nothing breaks in
   between.
3. **Alert:** a hold older than 14 days misses the fixes of the newer
   nixpkgs; alert on the action's `stale` output (nix-detour-fleet's weekly
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

## Holding automatically on a lock update

The update action runs on your lock-update PR (from update-flake-lock,
Renovate or your own workflow). It finds what the update broke and holds
each package on the nixpkgs from before the update, in the same PR. Then it
checks again: a package that still fails held is reported instead (an error
a hold can't fix), and a failure that shows up only now is held in the next
round.

Tell it what you use, from package sets with your overlays and holds. Two
kinds, use either or both:

```nix
# outputs
# Targets: a NixOS host's toplevel. On failure, the package to hold is found
# in the error's trace, so packages reached any way count (services, config
# files, plugins). One per round.
nixDetourTargets.x86_64-linux.myhost = inputs.nix-detour.lib.watch.target self.nixosConfigurations.myhost;
# Watched packages: each evaluated on its own, and built when no substituter
# has it. lib.watch.nixos takes a host's system packages and its home-manager
# users' home.packages.
nixDetourWatch.x86_64-linux = inputs.nix-detour.lib.watch.nixos self.nixosConfigurations.myhost;
# or: lib.watch.packages { inherit pkgs; packages = [ ... ]; }
```

Only top-level packages can be held, so only those are found. Targets are
evaluated, not built.

```yaml
# in the workflow that opens or updates the lock PR, after installing Nix
- uses: kleinbem-dev/nix-detour/update@<sha>
  id: holds
  with:
    mode: commit          # report (the default) only reports
    token: ${{ secrets.TOKEN }}   # contents write, for the commit
```

The holds go to the PR branch as one signed commit; the hold-release action
removes them again once nixos-unstable has the fix. `held`, `failed` and a
Markdown `report` are outputs, for a PR comment or an issue. `build: false`
only evaluates (for big closures such as CUDA, where substituters decide);
`directory` and `nix-args` cover a checkout in a subfolder and flakes that
need `--override-input`; `systems: x86_64-linux aarch64-linux` checks other
systems' hosts from the same runner (evaluation only, builds need the
runner's system).

Holds kept in another repository (one list shared by several flakes):

```yaml
- uses: kleinbem-dev/nix-detour/update@<sha>
  with:
    holds-repo: you/fleet-holds   # where held-packages.json is
    holds-input: fleet-holds      # the flake input that brings it in here
    mode: commit
    holds-token: ${{ secrets.TOKEN }}   # contents + PR write there
```

The action clones that repository, holds there, checks through
`--override-input` with the edited copy, and in commit mode opens a PR in it.
Once that merges and your lock moves to it, the update goes through.

## Packages from open nixpkgs PRs

When a package you need only exists on a nixpkgs PR (often your own), run
the PR's own package files instead of copying them. The package is built
against your nixpkgs from the PR pinned at one commit, so what runs is
exactly what the PR contains. Once your nixpkgs has the package in the same
or a newer version, the entry goes and nixpkgs' package takes over.

`nixpkgs-prs.json` lists each entry:

| Field | Meaning |
|---|---|
| `pr` | the nixpkgs PR number |
| `owner`, `repo` | where the PR's branch is (your fork) |
| `rev`, `narHash` | the pinned commit (`nix-detour pr pin`) |
| `attrs` | the packages to take from the PR (from `pkgs/by-name`) |
| `scope` | optional: packages of the PR that `attrs` need but that stay unexported |
| `modules` | optional: NixOS modules of the PR, `{ name = path in the PR; }` |

```nix
# outputs
let
  prs = inputs.nix-detour.lib.mkPrs { prs = ./nixpkgs-prs.json; };
in
{
  overlays.default = prs.overlay;
  nixosModules = prs.nixosModules;  # e.g. nixosModules.mesh-llm
  # For the CLI and the actions, from a package set without the overlay.
  nixpkgsPrs = forAllSystems (pkgs: prs.checks pkgs);
}
```

The packages of one entry see each other first, then your nixpkgs. The
modules come without their `meta.doc`: the NixOS manual rejects chapters
nixpkgs doesn't know, and the module's options are documented either way.
`mkPrs` doesn't need flakes: `import "${nix-detour}/prs.nix" { inherit lib;
prs = ./nixpkgs-prs.json; }` gives the same.

```sh
nix run github:kleinbem-dev/nix-detour -- pr add mesh-llm --pr 571722 \
  --repo you/nixpkgs --attrs mesh-llm,skippy --rev <full sha> \
  --module mesh-llm=nixos/modules/services/misc/mesh-llm.nix
nix run github:kleinbem-dev/nix-detour -- pr pin mesh-llm <newer full sha>
nix run github:kleinbem-dev/nix-detour -- pr list
nix run github:kleinbem-dev/nix-detour -- pr merged   # which entries can go
```

Lifecycle:

1. **Add** an entry with `nix-detour pr add ... --rev <sha>`, pinned to a
   commit whose packages build (nixpkgs-review). An entry without a pin
   doesn't evaluate, so don't commit one.
2. **Pin** a newer commit of the PR later, by hand or with the pin action,
   which evaluates the packages and opens the PR:
   `uses: kleinbem-dev/nix-detour/pr-pin@<sha> # v0.2.0` with `token`, `name` and
   `rev`. Lock updates never move a pin, so nothing new runs unless you
   pinned it.
3. **Remove:** `uses: kleinbem-dev/nix-detour/pr-merged@<sha> # v0.2.0` with `token`,
   on a schedule, opens a PR removing each entry your flake's nixpkgs has
   caught up with. An entry with modules gets a draft: switch to nixpkgs'
   own module first, then mark it ready.

Both actions run after installing Nix, from a checkout of your repository.

## Not here

Fixes that change a package (a patch, a skipped test) stay in the consumer
that needs them. This repo only chooses which nixpkgs a package comes from:
an older one, or a PR.
