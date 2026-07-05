{ indexState, pkgs, mkdocs, ... }:

let
  indexTool = { index-state = indexState; };
  toolArgs = name:
    indexTool // pkgs.lib.optionalAttrs (name == "cabal-fmt") {
      cabalProjectLocal = ''
        allow-newer: cabal-fmt:base
      '';
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
    ];
    shellHook = ''
      echo "Entering cardano-multisig dev shell"
    '';
  };

  project = pkgs.haskell-nix.cabalProject' {
    name = "cardano-multisig";
    src = ./..;
    compiler-nix-name = "ghc9123";
    shell = shell { inherit pkgs; };
    modules = [{ packages.cardano-multisig.flags.werror = true; }];
  };

in {
  devShells.default = project.shell;
  inherit project;
  packages.cardano-multisig =
    project.hsPkgs.cardano-multisig.components.exes.cardano-multisig-server;
  packages.unit-tests =
    project.hsPkgs.cardano-multisig.components.tests.unit-tests;
}
