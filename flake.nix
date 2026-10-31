{
  description = "Hold packages back from nixos-unstable while they're broken there";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Consumers make this follow their own nixpkgs-stable.
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      nixpkgs-stable,
    }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # The holds of one consumer.
      #   holds: its held-packages.json (a path) or the same as an attrset
      #   nixpkgs-stable: the nixpkgs behind `from = "stable"`
      #   extraOverlays: its own package overlays, so its packages can be
      #     held too
      #   config: its nixpkgs config for the held package sets; by default
      #     the usual settings (allowUnfree, insecure packages, CUDA, ...)
      #     are taken from the package set the overlay is applied to
      lib.mkHolds =
        {
          holds,
          nixpkgs-stable ? inputs.nixpkgs-stable,
          extraOverlays ? [ ],
          config ? null,
        }:
        let
          entries = if builtins.isAttrs holds then holds else lib.importJSON holds;
          heldIn = pkgs: builtins.filter (name: pkgs ? ${name}) (builtins.attrNames entries);
        in
        {
          overlay = import ./overlay.nix {
            inherit nixpkgs-stable extraOverlays config;
            holds = entries;
          };

          # The nixpkgs NixOS tests of the held packages, from a package set
          # with the holds applied: an entry's `tests`, by default
          # `nixosTests.<name>` if there is one. The NixOS module comes from
          # the current nixpkgs, the package from its hold, and a module that
          # expects a newer package only fails at runtime. Run these with
          # your own overlays on top, since that is the package you deploy.
          nixosTests =
            pkgs:
            let
              testsOf = name: entries.${name}.tests or (lib.optional (pkgs.nixosTests ? ${name}) name);
            in
            lib.genAttrs (lib.unique (lib.concatMap testsOf (heldIn pkgs))) (test: pkgs.nixosTests.${test});

          # What ends each hold: its `releaseWhen` (default: the package
          # itself), from a package set *without* the holds but with the
          # consumer's own overlays. A hold can go once its release check
          # builds from the newest nixpkgs.
          releaseChecks =
            pkgs:
            lib.genAttrs (heldIn pkgs) (
              name: lib.getAttrFromPath (lib.splitString "." (entries.${name}.releaseWhen or name)) pkgs
            );
        };

      # Tests of mkHolds itself, on holds from nixpkgs-stable.
      checks = forAllSystems (
        pkgs:
        import ./tests {
          inherit pkgs nixpkgs nixpkgs-stable;
          inherit (self.lib) mkHolds;
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
