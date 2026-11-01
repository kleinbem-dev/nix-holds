{
  description = "Single packages take a detour from your nixpkgs (held back while broken, or ahead from an open nixpkgs PR) until nixpkgs catches up";

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
        "aarch64-darwin"
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
            root = if builtins.isAttrs holds then null else dirOf holds;
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
          # builds from the newest nixpkgs. Each check carries its hold's
          # entry as `nixHolds`, so the release tools read the holds this
          # flake actually uses.
          releaseChecks =
            pkgs:
            lib.genAttrs (heldIn pkgs) (
              name:
              lib.getAttrFromPath (lib.splitString "." (entries.${name}.releaseWhen or name)) pkgs
              // {
                nixHolds = entries.${name};
              }
            );
        };

      # Packages from open nixpkgs PRs of one consumer (see prs.nix).
      #   prs: its nixpkgs-prs.json (a path) or the same as an attrset
      lib.mkPrs = { prs }: import ./prs.nix { inherit lib prs; };

      # What the update action checks (see watch.nix): lib.watch.nixos
      # nixosSystem, or lib.watch.packages { pkgs, packages }.
      lib.watch = import ./watch.nix { inherit lib; };

      # The CLI: add, remove, list and check holds, and the same for PR
      # packages (`nix-detour pr`). Nix itself comes from the user's PATH.
      packages = forAllSystems (pkgs: {
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.nix-detour;
        nix-detour =
          let
            releaseCheck = pkgs.writeShellApplication {
              name = "nix-detour-release-check";
              runtimeInputs = [
                pkgs.coreutils
                pkgs.jq
              ];
              text = builtins.readFile ./scripts/release-check.sh;
            };
            prs = pkgs.writeShellApplication {
              name = "nix-detour-pr";
              runtimeInputs = [
                pkgs.coreutils
                pkgs.jq
              ];
              text = builtins.readFile ./scripts/prs.sh;
            };
          in
          pkgs.writeShellApplication {
            name = "nix-detour";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.git
              pkgs.jq
            ];
            text =
              builtins.replaceStrings [ "@releaseCheck@" "@prs@" ] [ (lib.getExe releaseCheck) (lib.getExe prs) ]
                (builtins.readFile ./scripts/nix-detour.sh);
          };
      });

      # Tests of mkHolds, mkPrs and the CLI.
      checks = forAllSystems (
        pkgs:
        import ./tests {
          inherit pkgs nixpkgs nixpkgs-stable;
          inherit (self.lib) mkHolds;
          mkPrs = args: import ./prs.nix ({ inherit lib; } // args);
          inherit (self.lib) watch;
          inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) nix-detour;
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
