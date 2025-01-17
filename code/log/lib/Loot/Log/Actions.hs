module Loot.Log.Actions
       ( -- * 'LogAction's on 'Message's
         logMessageStdout
       , logMessageStderr
       , logMessageSyslog
       , logMessageFile
         -- * CPS 'LogAction's on 'Message's
       , withLogMessageStdout
       , withLogMessageStderr
       , withLogMessageSyslog
       , withLogMessageFile
         -- * Utils
       , withLogAction
       ) where

import Universum
import Loot.Log.Internal.Message

import Colog.Actions (logByteStringStdout, logByteStringStderr, logByteStringHandle)
import Colog.Core.Action (LogAction(..), cmap)
import Colog.Syslog.Actions (withLogMessageSyslogGeneric)
import Colog.Syslog.Config (SyslogConfig)
import Colog.Syslog.Handler (SyslogHandler, logSyslogMessage)

import Control.Monad.Trans.Control (MonadBaseControl, liftBaseOp)

-- | 'LogAction' that outputs a 'Message' to stdout
logMessageStdout :: MonadIO m => LogAction m Message
logMessageStdout = cmap fmtMessageColored logByteStringStdout

-- | 'LogAction' that outputs a 'Message' to stderr
logMessageStderr :: MonadIO m => LogAction m Message
logMessageStderr = cmap fmtMessageColored logByteStringStderr

-- | 'LogAction' that outputs a 'Message' to syslog. NOTE: if you use this you need
-- to remember to close the handle. Consider using 'withLogMessageSyslog' instead
logMessageSyslog :: MonadIO m => SyslogHandler -> LogAction m Message
logMessageSyslog = cmap toSyslogMessage . logSyslogMessage

-- | 'LogAction' that outputs a 'Message' to a file. NOTE: if you use this you need
-- to remember to close the handle. Consider using 'withLogMessageFile' instead
logMessageFile :: MonadIO m => Handle -> LogAction m Message
logMessageFile = cmap fmtMessageFlat . logByteStringHandle

-- | Continuation-passing style version of 'logMessageStdout'. This is an utility
-- function useful when dealing with multiple other CPS 'LogAction's, there is
-- no advantage in using this over 'logMessageStdout'
withLogMessageStdout :: MonadIO m => (LogAction m Message -> n r) -> n r
withLogMessageStdout = withLogAction logMessageStdout

-- | Continuation-passing style version of 'logMessageStderr'. This is an utility
-- function useful when dealing with multiple other CPS 'LogAction's, there is
-- no advantage in using this over 'logMessageStderr'
withLogMessageStderr :: MonadIO m => (LogAction m Message -> n r) -> n r
withLogMessageStderr = withLogAction logMessageStderr

-- | Continuation-passing style 'LogAction' for syslog backend. This is based
-- on 'bracket' and has the advantage of closing the handle when needed.
withLogMessageSyslog
    :: (MonadBaseControl IO n, MonadIO m)
    => SyslogConfig
    -> (LogAction m Message -> n r) -> n r
withLogMessageSyslog config action =
    withLogMessageSyslogGeneric config (action . cmap toSyslogMessage)

-- | Continuation-passing style 'LogAction' for file backend. This is based
-- on 'bracket' and has the advantage of closing the handle when needed.
withLogMessageFile
    :: (MonadBaseControl IO n, MonadIO m)
    => FilePath
    -> (LogAction m Message -> n r) -> n r
withLogMessageFile path action = liftBaseOp (withFile path AppendMode) $
    action . cmap fmtMessageFlat . logByteStringHandle

-- | Utility to use a 'LogAction' in continuation-passing style
withLogAction :: LogAction m msg -> (LogAction m msg -> n r) -> n r
withLogAction action = \f -> f action
