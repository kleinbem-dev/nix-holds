# Packages and NixOS modules from open nixpkgs pull requests: the other way
# round from a hold. Each entry pins a PR at one commit; its packages are
# built from the PR's own package files against the consumer's nixpkgs, so
# what runs is exactly what the PR contains, never a copy. An entry goes once
# the consumer's nixpkgs has its packages in the same or a newer version.
#
# Plain Nix (no flake needed): `import ./prs.nix { inherit lib; prs = ...; }`.
{
  lib,
  # The PRs file (a path) or the same as an attrset.
  prs,
  # The source tree of an entry. Tests pass a local tree.
  fetch ? (
    entry:
    # fetchTarball, not builtins.fetchTree, which needs the flakes feature.
    builtins.fetchTarball {
      url = "https://github.com/${entry.owner}/${entry.repo}/archive/${entry.rev}.tar.gz";
      sha256 = entry.narHash;
    }
  ),
}:
let
  entries = if builtins.isAttrs prs then prs else lib.importJSON prs;

  byName = src: name: "${src}/pkgs/by-name/${lib.substring 0 2 name}/${name}/package.nix";

  allAttrs = lib.concatMap (entry: entry.attrs) (lib.attrValues entries);

  # One entry's attributes, from pkgs. Each entry gets its own scope, so
  # packages of the same PR find each other before falling back to nixpkgs.
  # `scope` names packages of the PR that its attributes need but that aren't
  # exported (a dependency with its own PR, say).
  packagesOf =
    pkgs: entry:
    let
      src = fetch entry;
      scope = lib.makeScope pkgs.newScope (
        self:
        lib.genAttrs (entry.attrs ++ entry.scope or [ ]) (name: self.callPackage (byName src name) { })
      );
    in
    lib.getAttrs entry.attrs scope;

  packages = pkgs: lib.concatMapAttrs (_: packagesOf pkgs) entries;
in
assert lib.assertMsg (lib.allUnique allAttrs) "nix-holds prs: an attribute is in two entries";
{
  inherit entries packages;

  # Every entry's packages, built against the package set the overlay is
  # applied to.
  overlay = final: _prev: packages final;

  # Every entry's NixOS modules, without their meta.doc: the NixOS manual
  # only accepts chapters whose identifiers are in nixpkgs' own
  # redirects.json, so an out-of-tree chapter fails the manual build. The
  # options are documented either way. The module system passes only the
  # arguments a module names, so the wrapper takes over the module's own
  # argument names. A module needs its packages: apply the overlay too.
  nixosModules = lib.concatMapAttrs (
    _: entry:
    lib.mapAttrs (
      _: path:
      let
        module = import "${fetch entry}/${path}";
      in
      lib.setFunctionArgs (
        args:
        let
          evaluated = module args;
        in
        evaluated // { meta = removeAttrs (evaluated.meta or { }) [ "doc" ]; }
      ) (lib.functionArgs module)
    ) (entry.modules or { })
  ) entries;

  # Per entry, from a package set *without* the overlay: its packages, and
  # whether that nixpkgs already has all of them in the same or a newer
  # version (`merged`), so the entry can go. Each carries its entry as
  # `nixPrs`, so the tools read the entries the flake actually uses.
  checks =
    pkgs:
    lib.mapAttrs (
      _: entry:
      let
        ours = packagesOf pkgs entry;
        inNixpkgs =
          attr:
          pkgs ? ${attr}
          && builtins.compareVersions (pkgs.${attr}.version or "") (ours.${attr}.version or "") >= 0;
      in
      {
        packages = ours;
        merged = lib.all inNixpkgs entry.attrs;
        nixPrs = entry;
      }
    ) entries;
}
