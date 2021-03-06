# our packages overlay
pkgs: _: with pkgs;
  let
    compiler = config.haskellNix.compiler or "ghc8102";
  in {
    cardanoDbSyncHaskellPackages = callPackage ./haskell.nix {
      inherit compiler gitrev;
    };

  # Grab the executable component of our package.
  inherit (cardanoDbSyncHaskellPackages.cardano-db-sync.components.exes)
      cardano-db-sync;
  inherit (cardanoDbSyncHaskellPackages.cardano-db-sync-extended.components.exes)
      cardano-db-sync-extended;
  inherit (cardanoDbSyncHaskellPackages.cardano-node.components.exes)
      cardano-node;

  inherit ((haskell-nix.hackage-package {
    name = "hlint";
    version = "3.1.6";
    compiler-nix-name = compiler;
    inherit (cardanoDbSyncHaskellPackages) index-state;
  }).components.exes) hlint;

  inherit ((haskell-nix.hackage-package {
    name = "stylish-haskell";
    version = "0.12.2.0";
    compiler-nix-name = compiler;
    inherit (cardanoDbSyncHaskellPackages) index-state;
  }).components.exes) stylish-haskell;
}
