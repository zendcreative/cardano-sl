{-# LANGUAGE CPP           #-}
{-# LANGUAGE TypeOperators #-}

module Pos.Diffusion.Full.Types
       ( DiffusionWorkMode
       ) where

import           Universum

import           Pos.Block.Configuration (HasBlockConfiguration)
import           Pos.Communication.Limits (HasAdoptedBlockVersionData)
import           Pos.Configuration (HasNodeConfiguration)
import           Pos.Core (HasConfiguration)
import           Pos.Infra.Configuration (HasInfraConfiguration)

type DiffusionWorkMode
    = (
      -- Unfortunately we need HasConfigurations because so much of the core
      -- program depends upon it (serialization, message limits, smart
      -- constructors).
      -- [CSL-2141] aspires to fix that. There's a lot of stuff in here that
      -- a diffusion layer simply should not need to know about.
        HasConfiguration
      -- Needed for the recoveryHeadersMessage, which is not ideal but whatever
      -- we can deal with that later.
      , HasBlockConfiguration
      -- Needed for message size limits, but shouldn't be [CSL-2242].
      , HasInfraConfiguration
      , HasNodeConfiguration
      )
