#! /usr/bin/env nix-shell
#! nix-shell regen-shell.nix -i runhaskell
{-# LANGUAGE OverloadedStrings, LambdaCase #-}

import Prelude hiding (FilePath)
import Turtle
import Nix.Parser
import Nix.Expr
import Nix.Pretty (prettyNix)
import Text.PrettyPrint.ANSI.Leijen (hPutDoc)
import Data.Fix
import qualified Data.Text as T
import qualified Data.Map as M
import System.IO (openFile, hClose, IOMode(WriteMode))
import Filesystem.Path.CurrentOS (encodeString)

main :: IO ()
main = do
  testMode <- options "Regenerate frontend dependencies" optionsParser
  sh $ if testMode
    then test
    else regen

regen :: Shell ()
regen = do
  echo "Regenerating nix for frontend"
  bower2nix "bower.json" "bower-generated.nix"
  node2nix "package.json" "node-packages.nix"

bower2nix :: FilePath -> FilePath -> Shell ()
bower2nix src out = cachedShell src out $ \out' ->
  procs "bower2nix" [tt src, tt out'] empty

node2nix :: FilePath -> FilePath -> Shell ()
node2nix src out = cachedShell src out $ \out' -> do
  let composition = "composition.nix"
  out'' <- mktempfile "." (tt out)
  composition' <- mktempfile "." (tt composition)
  procs "node2nix" ["-6", "-i", tt src, "-c", tt composition', "-o", tt out, "-d"] empty
  cp out out''
  liftIO $ fixNix composition' composition
  liftIO $ fixNix out'' out'
  inplace uglify2 out'
  inplace srcAttr out'
  inplace addSrcArg composition

test :: Shell ()
test = do
  echo "Checking that auto-generated frontend dependencies nix is up to date."
  b <- needsChange "bower.json" "bower-generated.nix"
  n <- needsChange "package.json" "node-packages.nix"
  when b $ echo " - bower-generated.nix needs update"
  when n $ echo " - node-packages.nix needs update"
  when (b || n) $ die "Run explorer/frontend/scripts/regen.hs to fix this"

optionsParser :: Parser Bool
optionsParser = switch "test" 't' "Test freshness but don't regenerate"

----------------------------------------------------------------------------

-- | Run a shell command only if the destination file is out of date
-- with respect to the source file.
cachedShell :: FilePath -> FilePath -> (FilePath -> Shell ()) -> Shell ()
cachedShell src dst action = needsChange src dst >>= \case
  True -> do
    printf ("Generating " % fp % "\n") dst
    tmp <- mktempfile "." (tt $ basename dst)
    action tmp
    whenM (testpath dst) $ rm dst
    input tmp & stampFile src & output dst
  False -> printf (fp % " is already up to date according to " % fp % "\n") dst src

-- | A file needs a change if its hash doesn't match or it doesn't exist.
needsChange :: FilePath -> FilePath -> Shell Bool
needsChange src dst = do
  exists <- testfile dst
  if exists
    then do
      line <- limit 1 $ input dst
      hash <- limit 1 $ hashFile src
      pure $ line /= hash
    else pure True

-- | sha256sum output prepended with a nix line comment symbol
hashFile :: FilePath -> Shell Line
hashFile src = fmap ("# " <>) (inproc "sha256sum" [tt src] empty)

-- | Adds a hash to the top of the file
stampFile :: FilePath -> Shell Line -> Shell Line
stampFile ref f = cat [hashFile ref, f]

----------------------------------------------------------------------------

-- | Replace references to uglify version 3 with uglify version 2
uglify2 :: Pattern Text
uglify2 = text "sources." *> char '"' *> old *> star (notChar '"') *> char '"' *> pure new
  where
    old = "uglify-js-3."
    new = "sources.\"uglify-js-2.8.29\""

-- | Inherit src attribute instead of using cwd
srcAttr :: Pattern Text
srcAttr = text "src = ./.;" *> pure "inherit src;"

-- | In the composition.nix file, add src to the arguments of node-packages.nix.
addSrcArg :: Pattern Text
addSrcArg = text "inherit nodeEnv" *> pure "inherit src nodeEnv"

----------------------------------------------------------------------------

fixNix :: FilePath -> FilePath -> IO ()
fixNix src dst = do
  Success nix <- parseNixFile (encodeString src)
  let
    nix' = addSrcParam nix
    doc = prettyNix nix'
  handle <- openFile (encodeString dst) WriteMode
  hPutDoc handle doc
  hClose handle

-- | Adds a src argument to the top level of the file.
addSrcParam :: NExpr -> NExpr
addSrcParam (Fix e) = case e of
  NAbs (ParamSet (FixedParamSet params) x) body ->
    Fix $ NAbs (ParamSet (FixedParamSet (M.insert "src" Nothing params)) x) body
  exp -> Fix exp

----------------------------------------------------------------------------

whenM :: Monad f => f Bool -> f () -> f ()
whenM f a = f >>= \t -> if t then a else pure ()

tt = format fp
