# Tests of mkHolds itself, on a small list of holds from nixpkgs-stable (no
# extra downloads). Evaluation only: a failing test fails `nix flake check`.
{
  pkgs,
  nixpkgs,
  nixpkgs-stable,
  mkHolds,
  nix-holds,
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
      figlet = {
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
      expr = (holds.releaseChecks pkgs).figlet.outPath;
      expected = pkgs.python3Packages.jq.outPath;
    };
    # The release tools read each hold from its check.
    testReleaseCheckCarriesEntry = {
      expr = (holds.releaseChecks pkgs).figlet.nixHolds;
      expected = {
        from = "stable";
        releaseWhen = "python3Packages.jq";
      };
    };
    testReleaseChecksSkipMissing = {
      expr = builtins.attrNames (holds.releaseChecks pkgs);
      expected = [
        "figlet"
        "hello"
        "unrar"
      ];
    };
  };
in
{
  # The CLI on a git repo whose flake.lock moved nixpkgs from rev a to b.
  cli =
    pkgs.runCommand "nix-holds-cli-tests"
      {
        nativeBuildInputs = [
          nix-holds
          pkgs.git
          pkgs.jq
        ];
      }
      ''
        set -euo pipefail
        lock() {
          jq -n --arg rev "$1" '{nodes: {root: {inputs: {nixpkgs: "nixpkgs"}},
            nixpkgs: {locked: {type: "github", owner: "NixOS", repo: "nixpkgs", rev: $rev, narHash: ("sha256-" + $rev)}}}}' > flake.lock
        }
        export HOME=$TMPDIR GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
        git init -q .
        lock a; git add flake.lock; git commit -qm a
        lock b

        # Uncommitted update: the committed lock is the previous one.
        nix-holds add foo --reason "broken in b" --link https://example.org/1
        test "$(jq -c .foo.from held-packages.json)" = '{"rev":"a","narHash":"sha256-a"}'
        test "$(jq -r .foo.link held-packages.json)" = https://example.org/1

        # Committed update: found in the history.
        git add flake.lock; git commit -qm b
        nix-holds add bar --reason r --release-when python3Packages.bar --tests t1,t2
        test "$(jq -r .bar.from.rev held-packages.json)" = a
        test "$(jq -r .bar.releaseWhen held-packages.json)" = python3Packages.bar
        test "$(jq -c .bar.tests held-packages.json)" = '["t1","t2"]'

        nix-holds add baz --from stable --reason r
        test "$(jq -r .baz.from held-packages.json)" = stable
        test "$(jq -r 'keys | join(",")' held-packages.json)" = bar,baz,foo

        nix-holds list | grep -q '^foo  *a  '
        nix-holds remove foo
        test "$(jq -r 'keys | join(",")' held-packages.json)" = bar,baz
        if nix-holds remove foo 2>/dev/null; then echo "removing a missing hold should fail" >&2; exit 1; fi
        if nix-holds add qux 2>/dev/null; then echo "add without --reason should fail" >&2; exit 1; fi
        if nix-holds add qux --reason 2>/dev/null; then echo "an option without a value should fail" >&2; exit 1; fi

        # An invalid holds file stays as it is.
        echo '{ broken' > bad.json
        if nix-holds add qux --reason r --from stable --file bad.json 2>/dev/null; then echo "add to an invalid file should fail" >&2; exit 1; fi
        test "$(cat bad.json)" = '{ broken'
        if nix-holds remove bar --file bad.json 2>/dev/null; then echo "remove from an invalid file should fail" >&2; exit 1; fi
        test "$(cat bad.json)" = '{ broken'
        touch $out
      '';

  mk-holds =
    if failed == [ ] then
      pkgs.writeText "mk-holds-tests" "ok"
    else
      throw "mkHolds tests failed: ${builtins.toJSON failed}";
}
