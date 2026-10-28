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

      # Evaluates every held package this flake can provide on its own, from
      # its pinned nixpkgs. Not a build: consumers may adjust a held package
      # (the open-webui container fixes its wrapper), so their own CI builds
      # the real thing.
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
        in
        {
          held-packages = pkgs.writeText "held-packages" (
            builtins.concatStringsSep "\n" (
              map (name: "${name} ${builtins.unsafeDiscardOutputDependency held.${name}.drvPath}") names
            )
          );
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
