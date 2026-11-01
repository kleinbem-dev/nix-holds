# Tests of mkHolds and mkPrs, on a small list of holds from nixpkgs-stable
# and PRs from a local tree (no extra downloads). Evaluation only: a failing
# test fails `nix flake check`.
{
  pkgs,
  nixpkgs,
  nixpkgs-stable,
  mkHolds,
  mkPrs,
  watch,
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
  # Two PRs from a local tree: fake-a needs the unexported fake-b of its PR,
  # and an older hello than nixpkgs' with a NixOS module.
  prs = mkPrs {
    fetch = _: ./fake-pr;
    prs = {
      fake = {
        pr = 1;
        attrs = [ "fake-a" ];
        scope = [ "fake-b" ];
      };
      old-hello = {
        pr = 2;
        attrs = [ "hello" ];
        modules = {
          fake = "nixos/fake.nix";
          fake-attrs = "nixos/fake-attrs.nix";
        };
      };
    };
  };
  withPrs = import nixpkgs {
    inherit system;
    overlays = [ prs.overlay ];
  };
  prChecks = prs.checks pkgs;
  fakeModule = prs.nixosModules.fake { inherit lib; };

  # The update action's watch list: top-level packages only, the same
  # package as the attribute, and a broken one whose attribute is broken too.
  brokenPkgs = pkgs.extend (
    _: prev: {
      figlet = prev.figlet.overrideAttrs { meta.broken = true; };
    }
  );
  watched = watch.packages {
    pkgs = brokenPkgs;
    packages = [
      brokenPkgs.hello
      brokenPkgs.figlet
      (brokenPkgs.writeText "not-top-level" "x")
      (brokenPkgs.hello.overrideAttrs {
        pname = "hello";
        version = "0-other";
      })
      brokenPkgs.python3Packages.six
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

    testPrPackageInOverlay = {
      expr = withPrs.fake-a.text;
      expected = "${withPrs.writeText "fake-b" "b"}";
    };
    testPrScopeNotExported = {
      expr = withPrs ? fake-b;
      expected = false;
    };
    testPrReplacesNixpkgs = {
      expr = withPrs.hello.version;
      expected = "0.1";
    };
    testPrMerged = {
      expr = lib.mapAttrs (_: c: c.merged) prChecks;
      expected = {
        fake = false;
        old-hello = true;
      };
    };
    testPrCheckCarriesEntry = {
      expr = prChecks.fake.nixPrs.pr;
      expected = 1;
    };
    testPrModuleWithoutDoc = {
      expr = fakeModule.meta;
      expected = {
        maintainers = [ ];
      };
    };
    testPrAttrsetModuleWithoutDoc = {
      expr = prs.nixosModules.fake-attrs.meta;
      expected = {
        maintainers = [ ];
      };
    };
    testPrDuplicateModuleRefused = {
      expr =
        (builtins.tryEval
          (mkPrs {
            fetch = _: ./fake-pr;
            prs = {
              a = {
                attrs = [ ];
                modules.fake = "nixos/fake.nix";
              };
              b = {
                attrs = [ ];
                modules.fake = "nixos/fake-attrs.nix";
              };
            };
          }).nixosModules
        ).success;
      expected = false;
    };
    testWatchNames = {
      expr = builtins.attrNames watched;
      expected = [
        "figlet"
        "hello"
      ];
    };
    testWatchBrokenStaysBroken = {
      expr = (builtins.tryEval watched.figlet.drvPath).success;
      expected = false;
    };
    testWatchNixos = {
      expr = builtins.attrNames (
        watch.nixos {
          pkgs = brokenPkgs;
          config = {
            environment.systemPackages = [ brokenPkgs.hello ];
            home-manager.users.u.home.packages = [ brokenPkgs.figlet ];
          };
        }
      );
      expected = [
        "figlet"
        "hello"
      ];
    };
    testPrModuleArgs = {
      expr = lib.functionArgs prs.nixosModules.fake;
      expected = {
        lib = false;
      };
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
        jq '.nodate = {from: "stable", reason: "r", releaseWhen: "python3Packages.x"}' held-packages.json > h && mv h held-packages.json
        nix-holds list | grep -q '^nodate  *stable  *no date  until python3Packages.x builds$'
        nix-holds remove nodate
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

  # The PR CLI, without the commands that fetch (pin) or evaluate a flake.
  pr-cli =
    pkgs.runCommand "nix-holds-pr-cli-tests"
      {
        nativeBuildInputs = [
          nix-holds
          pkgs.jq
        ];
      }
      ''
        set -euo pipefail
        nix-holds pr add mesh --pr 571722 --repo someone/nixpkgs --attrs mesh-llm,skippy \
          --scope skippy-runtime --module mesh-llm=nixos/modules/services/misc/mesh-llm.nix
        test "$(jq -c .mesh nixpkgs-prs.json)" = '{"pr":571722,"owner":"someone","repo":"nixpkgs","rev":"","narHash":"","attrs":["mesh-llm","skippy"],"scope":["skippy-runtime"],"modules":{"mesh-llm":"nixos/modules/services/misc/mesh-llm.nix"}}'
        nix-holds pr add berd --pr 2 --repo someone/nixpkgs --attrs berd
        test "$(jq -r 'keys | join(",")' nixpkgs-prs.json)" = berd,mesh
        test "$(jq -c .berd nixpkgs-prs.json)" = '{"pr":2,"owner":"someone","repo":"nixpkgs","rev":"","narHash":"","attrs":["berd"]}'
        nix-holds pr list | grep -q '^mesh  *#571722  *not pinned  *mesh-llm,skippy$'
        if nix-holds pr pin berd abc 2>/dev/null; then echo "pin with a short sha should fail" >&2; exit 1; fi
        if nix-holds pr pin nope 0000000000000000000000000000000000000000 2>/dev/null; then echo "pin of a missing entry should fail" >&2; exit 1; fi
        if nix-holds pr add x --pr 3 --attrs x 2>/dev/null; then echo "add without --repo should fail" >&2; exit 1; fi
        if nix-holds pr add x --pr 3 --repo a/b --attrs x --module bad 2>/dev/null; then echo "a module without a path should fail" >&2; exit 1; fi
        if nix-holds pr add berd --pr 2 --repo other/nixpkgs --attrs berd 2>/dev/null; then echo "adding an existing entry should fail" >&2; exit 1; fi
        test "$(jq -r .berd.owner nixpkgs-prs.json)" = someone
        # A --rev that can't be pinned adds nothing.
        if nix-holds pr add x --pr 3 --repo a/b --attrs x --rev abc 2>/dev/null; then echo "add with a short --rev should fail" >&2; exit 1; fi
        test "$(jq -r 'has("x")' nixpkgs-prs.json)" = false
        nix-holds pr remove berd
        test "$(jq -r 'keys | join(",")' nixpkgs-prs.json)" = mesh
        if nix-holds pr remove berd 2>/dev/null; then echo "removing a missing entry should fail" >&2; exit 1; fi
        touch $out
      '';

  mk-holds =
    if failed == [ ] then
      pkgs.writeText "mk-holds-tests" "ok"
    else
      throw "mkHolds/mkPrs tests failed: ${builtins.toJSON failed}";
}
