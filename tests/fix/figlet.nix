{ pkgs, package }:
package.overrideAttrs { passthru.fixedWith = pkgs.lib.version; }
