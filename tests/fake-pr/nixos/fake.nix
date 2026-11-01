{ lib, ... }:
{
  options.services.fake.enable = lib.mkEnableOption "fake";
  meta.doc = ./fake.md;
  meta.maintainers = [ ];
}
