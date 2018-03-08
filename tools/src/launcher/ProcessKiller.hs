{-# OPTIONS_GHC -cpp #-}

module ProcessKiller
        ( stopProcess,
          killProcess
        ) where

import System.Process
import System.Process.Internals ( withProcessHandle
                                , ProcessHandle__(..)
                                , ProcessHandle )

#if defined(OS_WINDOWS)
import System.Win32.Process (terminateProcessById)
import System.Win32.Console (generateConsoleCtrlEvent, cTRL_C_EVENT)
#else
import System.Posix.Signals hiding (killProcess)
#endif

#if defined(WINDOWS)

stopProcess :: ProcessHandle -> IO ()
stopProcess ph = do
  pid <- getPid ph
  stop <- case pid of
    Nothing -> print "wtf"
    Just pD -> generateConsoleCtrlEvent cTRL_C_EVENT pD

killProcess :: ProcessHandle -> IO ()
killProcess ph = terminateProcess


#else

stopProcess :: ProcessHandle -> IO ()
stopProcess = terminateProcess

killProcess :: ProcessHandle -> IO ()
killProcess ph = do
  withProcessHandle ph $ \p_ ->
    case p_ of
      ClosedHandle _ -> return ()
      OpenHandle h -> do
        signalProcess sigKILL h
        return ()

#endif
