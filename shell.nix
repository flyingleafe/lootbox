with import <nixpkgs> { };
let hspkgs = haskell.packages.ghc8107; in
haskell.lib.buildStackProject {
   ghc = hspkgs.ghc;
   name = "lootbox";
   buildInputs = [ zlib gmp git icu zeromq ];
}
