# args@{...}: (import ./default.nix (args // { cardano-sl-explorer = null; })).shell

{ pkgs ? import <nixpkgs> {} }:

let 
  ghc = pkgs.haskellPackages.ghcWithPackages (ps: [ps.turtle ps.hnix]);

in
  pkgs.stdenv.mkDerivation {
    name = "explorer-frontend-shell";
    buildInputs = with pkgs; [ nodePackages.bower2nix nodePackages.node2nix ghc ];
    shellHook = "eval $(egrep ^export ${ghc}/bin/ghc)";
    src = null;
  }
