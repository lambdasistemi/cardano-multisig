{ indexState, pkgs, mkdocs, ... }:

let
  shell = { pkgs, ... }: {
    tools = {
      cabal = { index-state = indexState; };
      cabal-fmt = { index-state = indexState; };
      haskell-language-server = { index-state = indexState; };
      hoogle = { index-state = indexState; };
      fourmolu = { index-state = indexState; };
      hlint = { index-state = indexState; };
    };
    withHoogle = true;
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
