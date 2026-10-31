# Tests of mkHolds itself, on a small list of holds from nixpkgs-stable (no
# extra downloads). Evaluation only: a failing test fails `nix flake check`.
{
  pkgs,
  nixpkgs,
  nixpkgs-stable,
  mkHolds,
}:
let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) system;
  stable = import nixpkgs-stable { inherit system; };

  # The consumer's own package, defined differently in its two nixpkgs.
  own = final: _: { own-package = final.writeText "own-package" final.lib.version; };

  holds = mkHolds {
    inherit nixpkgs-stable;
    extraOverlays = [ own ];
    holds = {
      hello.from = "stable";
      unrar.from = "stable";
      own-package.from = "stable";
      not-in-nixpkgs.from = "stable";
      jq = {
        from = "stable";
        releaseWhen = "python3Packages.jq";
      };
    };
  };

  consumer =
    config:
    import nixpkgs {
      inherit system config;
      overlays = [
        own
        holds.overlay
      ];
    };
  held = consumer { };
  heldUnfree = consumer { allowUnfree = true; };

  failed = lib.runTests {
    testHeldFromStable = {
      expr = held.hello.outPath;
      expected = stable.hello.outPath;
    };
    testOwnPackageHeld = {
      expr = held.own-package.outPath;
      expected = (own stable stable).own-package.outPath;
    };
    testMissingLeftOut = {
      expr = held ? not-in-nixpkgs;
      expected = false;
    };
    # The consumer's config reaches the held package set: no unfree package
    # unless the consumer allows it.
    testUnfreeRefused = {
      expr = (builtins.tryEval held.unrar.drvPath).success;
      expected = false;
    };
    testUnfreeAllowed = {
      expr = (builtins.tryEval heldUnfree.unrar.drvPath).success;
      expected = true;
    };
    testReleaseWhen = {
      expr = (holds.releaseChecks pkgs).jq.outPath;
      expected = pkgs.python3Packages.jq.outPath;
    };
    testReleaseChecksSkipMissing = {
      expr = builtins.attrNames (holds.releaseChecks pkgs);
      expected = [
        "hello"
        "jq"
        "unrar"
      ];
    };
  };
in
{
  mk-holds =
    if failed == [ ] then
      pkgs.writeText "mk-holds-tests" "ok"
    else
      throw "mkHolds tests failed: ${builtins.toJSON failed}";
}
