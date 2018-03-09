{-# OPTIONS_GHC -cpp #-}

module ProcessKiller
        ( stopProcess,
          killProcess,
          shellReturnHandle
        ) where

import System.Process
import System.Process.Internals ( withProcessHandle
                                , ProcessHandle__(..)
                                , ProcessHandle )

#ifdef mingw32_HOST_OS
import System.Win32.Console (generateConsoleCtrlEvent, cTRL_C_EVENT)
import System.Win32.Process (getProcessId)
#else
import System.Posix.Signals hiding (killProcess)
#endif

#ifdef mingw32_HOST_OS
stopProcess :: ProcessHandle -> IO ()
stopProcess ph = do
  pid <- getProcessId ph
  putStrLn "Stop me, oh, stop me"
  generateConsoleCtrlEvent cTRL_C_EVENT pid

killProcess :: ProcessHandle -> IO ()
killProcess ph = do
  putStrLn "Murder most foul, as in the best it is, but this most foul, strange, and unnatural"
  terminateProcess ph
#else
stopProcess :: ProcessHandle -> IO ()
stopProcess ph = do
  putStrLn "Stop me, oh, stop me"
  terminateProcess ph

killProcess :: ProcessHandle -> IO ()
killProcess ph = do
  withProcessHandle ph $ \p_ ->
    case p_ of
      ClosedHandle _ -> return ()
      OpenHandle h -> do
        putStrLn "Murder most foul, as in the best it is, But this most foul, strange, and unnatural."
        signalProcess sigKILL h
#endif

shellReturnHandle :: String -> IO ProcessHandle
shellReturnHandle cmd = do
  (_, _, _, phandle) <- createProcess (shell cmd)
  return phandle
