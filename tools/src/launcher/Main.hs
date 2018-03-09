module Main where

import ProcessKiller (shellReturnHandle, killProcess)
import Control.Concurrent (threadDelay)


main :: IO ()
main = do
  pr <- shellReturnHandle $ "./Main"
  threadDelay 1000000
  killProcess pr
