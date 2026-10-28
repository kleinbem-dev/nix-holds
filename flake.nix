{
  description = "Packages the kleinbem fleet holds back from nixos-unstable";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Consumers make this follow their own nixpkgs-stable.
    nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-stable,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # extraOverlays: the consumer's own package overlays, so its packages
      # can be held too (nix-config passes nix-packages' overlay).
      lib.mkOverlay =
        {
          extraOverlays ? [ ],
        }:
        import ./overlay.nix { inherit nixpkgs-stable extraOverlays; };

      overlays.default = self.lib.mkOverlay { };

      # The nixpkgs NixOS tests of the held packages, from a package set with
      # the holds applied: an entry's `tests`, by default `nixosTests.<name>`
      # if there is one. The NixOS module comes from the current nixpkgs, the
      # package from its hold, and a module that expects a newer package only
      # fails at runtime. Consumers run these with their own overlays on top,
      # since that is the package they deploy.
      lib.nixosTests =
        pkgs:
        let
          inherit (nixpkgs) lib;
          entries = lib.importJSON ./held-packages.json;
          names = builtins.filter (name: pkgs ? ${name}) (builtins.attrNames entries);
          testsOf = name: entries.${name}.tests or (lib.optional (pkgs.nixosTests ? ${name}) name);
        in
        lib.genAttrs (lib.unique (lib.concatMap testsOf names)) (test: pkgs.nixosTests.${test});

      # Evaluates every held package this flake can provide on its own, from
      # its pinned nixpkgs, and its NixOS tests. Not a build: consumers may
      # adjust a held package (the open-webui container fixes its wrapper),
      # so their own CI builds the real thing.
      checks = forAllSystems (
        pkgs:
        let
          held = import nixpkgs {
            inherit (pkgs.stdenv.hostPlatform) system;
            config.allowUnfree = true;
            overlays = [ self.overlays.default ];
          };
          names = builtins.filter (name: pkgs ? ${name}) (
            builtins.attrNames (nixpkgs.lib.importJSON ./held-packages.json)
          );
          drvs =
            map (name: "${name} ${held.${name}.drvPath}") names
            ++ nixpkgs.lib.mapAttrsToList (test: drv: "nixosTests.${test} ${drv.drvPath}") (
              self.lib.nixosTests held
            );
        in
        {
          held-packages = pkgs.writeText "held-packages" (
            builtins.concatStringsSep "\n" (map builtins.unsafeDiscardOutputDependency drvs)
          );
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
