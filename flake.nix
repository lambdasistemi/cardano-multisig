{
  description =
    "Permissionless witness-collection coordinator for Conway transactions";
  nixConfig = {
    extra-substituters = [ "https://cache.iog.io" ];
    extra-trusted-public-keys =
      [ "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=" ];
  };
  inputs = {
    haskellNix.url =
      "github:input-output-hk/haskell.nix/8b447d7f57d62fab9249f79bb916bc891e29b9d0";
    nixpkgs = { follows = "haskellNix/nixpkgs-unstable"; };
    flake-utils.url = "github:hamishmack/flake-utils/hkm/nested-hydraJobs";
    mkdocs.url = "github:paolino/dev-assets?dir=mkdocs";
    iohkNix = {
      url = "github:input-output-hk/iohk-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    cardano-node = {
      url = "github:IntersectMBO/cardano-node/10.7.0";
    };
    CHaP = {
      url = "github:intersectmbo/cardano-haskell-packages?ref=repo";
      flake = false;
    };
  };

  outputs =
    inputs@{ self, nixpkgs, flake-utils, haskellNix, iohkNix, cardano-node
    , CHaP, mkdocs, ... }:
    let
      version = self.dirtyShortRev or self.shortRev;

      perSystem = system:
        let
          pkgs = import nixpkgs {
            overlays = [
              iohkNix.overlays.crypto
              haskellNix.overlay
              iohkNix.overlays.haskell-nix-crypto
              iohkNix.overlays.cardano-lib
              (_final: prev: { lzma = prev.xz; })
            ];
            inherit system;
          };
          project = import ./nix/project.nix {
            indexState = "2026-04-17T00:00:00Z";
            inherit CHaP pkgs system;
            mkdocs = mkdocs.packages.${system};
          };
          docker-image =
            import ./nix/docker-image.nix { inherit pkgs version project; };
          cardanoNode = cardano-node.packages.${system}.cardano-node;
          cardanoCli =
            cardano-node.packages.${system}.cardano-cli or cardanoNode;
          devnetPublishSmokeApp = pkgs.writeShellApplication {
            name = "devnet-publish-smoke";
            runtimeInputs = [
              cardanoNode
              cardanoCli
              pkgs.curl
              project.packages.cardano-multisig
              project.packages.devnet-publish-smoke
            ];
            text = ''
              export E2E_GENESIS_DIR=${./test/fixtures/devnet-genesis}
              exec devnet-publish-smoke
            '';
          };
          devnetPublishSmokeCheck =
            pkgs.runCommand "devnet-publish-smoke-check" {
              nativeBuildInputs =
                pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux
                  [ pkgs.glibcLocales ];
              LANG = "C.UTF-8";
              LC_ALL = "C.UTF-8";
            } ''
              set -euo pipefail
              cd ${./.}
              ${pkgs.lib.getExe devnetPublishSmokeApp}
              touch "$out"
            '';
        in {
          packages = project.packages // {
            default = project.packages.cardano-multisig;
            inherit docker-image;
          };
          checks = {
            devnet-publish-smoke = devnetPublishSmokeCheck;
          };
          apps = {
            cardano-multisig-server = {
              type = "app";
              program = pkgs.lib.getExe project.packages.cardano-multisig;
            };
            devnet-publish-smoke = {
              type = "app";
              program = pkgs.lib.getExe devnetPublishSmokeApp;
            };
          };
          inherit (project) devShells;
        };
    in (flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-darwin" ] perSystem)
    // {
      inherit version;
    };
}
