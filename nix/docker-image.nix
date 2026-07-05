{ pkgs, project, version, ... }:

pkgs.dockerTools.buildImage {
  name = "ghcr.io/lambdasistemi/cardano-multisig";
  tag = version;
  config = {
    EntryPoint = [ "cardano-multisig-server" ];
    ExposedPorts = { "8080/tcp" = { }; };
  };
  copyToRoot = pkgs.buildEnv {
    name = "image-root";
    paths = [ project.packages.cardano-multisig ];
  };
}
