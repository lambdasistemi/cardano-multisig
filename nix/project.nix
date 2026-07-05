{ CHaP, indexState, pkgs, system, mkdocs, ... }:

let
  isLinux = system == "x86_64-linux";
  indexTool = { index-state = indexState; };
  toolArgs = name:
    indexTool // pkgs.lib.optionalAttrs (name == "cabal-fmt") {
      cabalProjectLocal = ''
        allow-newer: cabal-fmt:base
      '';
    };

  # Force the cardano crypto/native library pkgconfig closures — these
  # packages hard-code libnames that must map to the iohk-nix overlay
  # variants (libsodium-vrf, blst) or nixpkgs equivalents.
  fix-libs = { lib, pkgs, ... }:
    {
      packages.cardano-crypto-praos.components.library.pkgconfig =
        lib.mkForce [ [ pkgs.libsodium-vrf ] ];
      packages.cardano-crypto-class.components.library.pkgconfig =
        lib.mkForce [ [ pkgs.libsodium-vrf pkgs.secp256k1 pkgs.libblst ] ];
      packages.cardano-lmdb.components.library.pkgconfig =
        lib.mkForce [ [ pkgs.lmdb ] ];
      packages.lzma.components.library.libs = lib.mkForce [ pkgs.xz ];
    } // lib.optionalAttrs isLinux {
      packages.blockio-uring.components.library.pkgconfig =
        lib.mkForce [ [ pkgs.liburing ] ];
    };

  shell = { pkgs, ... }: {
    tools = {
      cabal = toolArgs "cabal";
      cabal-fmt = toolArgs "cabal-fmt";
      fourmolu = toolArgs "fourmolu";
      hlint = toolArgs "hlint";
    };
    withHoogle = false;
    buildInputs = [
      pkgs.just
      pkgs.nixfmt-classic
      pkgs.shellcheck
      pkgs.mkdocs
      mkdocs.from-nixpkgs
      mkdocs.markdown-callouts
      mkdocs.markdown-graphviz
      pkgs.lmdb
      pkgs.xz
    ] ++ pkgs.lib.optionals isLinux [ pkgs.liburing ];
    shellHook = ''
      echo "Entering cardano-multisig dev shell"
    '';
  };

  project = pkgs.haskell-nix.cabalProject' {
    name = "cardano-multisig";
    src = ./..;
    compiler-nix-name = "ghc9123";
    shell = shell { inherit pkgs; };
    modules = [
      fix-libs
      { packages.cardano-multisig.flags.werror = true; }
    ];
    inputMap = { "https://chap.intersectmbo.org/" = CHaP; };
  };

in {
  devShells.default = project.shell;
  inherit project;
  packages.cardano-multisig =
    project.hsPkgs.cardano-multisig.components.exes.cardano-multisig-server;
  packages.unit-tests =
    project.hsPkgs.cardano-multisig.components.tests.unit-tests;
}
