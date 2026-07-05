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
    CHaP = {
      url = "github:intersectmbo/cardano-haskell-packages?ref=repo";
      flake = false;
    };
  };

  outputs =
    inputs@{ self, nixpkgs, flake-utils, haskellNix, iohkNix, CHaP, mkdocs, ... }:
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
        in {
          packages = project.packages // {
            default = project.packages.cardano-multisig;
            inherit docker-image;
          };
          inherit (project) devShells;
        };
    in (flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-darwin" ] perSystem)
    // {
      inherit version;
    };
}
