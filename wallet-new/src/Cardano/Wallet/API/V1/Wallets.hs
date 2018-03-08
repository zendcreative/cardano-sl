module Cardano.Wallet.API.V1.Wallets where

import           Cardano.Wallet.API.Request
import           Cardano.Wallet.API.Response
import           Cardano.Wallet.API.Types
import qualified Cardano.Wallet.API.V1.Accounts as Accounts
import           Cardano.Wallet.API.V1.Parameters
import           Cardano.Wallet.API.V1.Types

import           Servant


type APIWalletsNew =
    "wallets" :> Summary "Creates a new or restores an existing Wallet."
              :> ReqBody '[ValidJSON] (New Wallet)
              :> PostCreated '[ValidJSON] (WalletResponse Wallet)

type APIWalletsGet =
    "wallets" :> Summary "Returns all the available wallets."
              :> WalletRequestParams
              :> FilterBy '["wallet_id", "balance"] Wallet
              :> SortBy   '["balance"] Wallet
              :> Get '[ValidJSON] (WalletResponse [Wallet])

type APIWalletsGetSingle =
    "wallets" :> Capture "walletId" WalletId
              :> Summary "Returns the Wallet identified by the given walletId."
              :> Get '[ValidJSON] (WalletResponse Wallet)

type APIWalletsUpdate =
    "wallets" :> Capture "walletId" WalletId
              :> Summary "Update the Wallet identified by the given walletId."
              :> ReqBody '[ValidJSON] (Update Wallet)
              :> Put '[ValidJSON] (WalletResponse Wallet)

type APIWalletsDelete =
    "wallets" :> Capture "walletId" WalletId
              :> Summary "Deletes the given Wallet and all its accounts."
              :> DeleteNoContent '[ValidJSON] NoContent

type APIWalletsPassword =
    "wallets" :> Capture "walletId" WalletId
              :> "password"
              :> Summary "Updates the password for the given Wallet."
              :> ReqBody '[ValidJSON] PasswordUpdate
              :> Put '[ValidJSON] (WalletResponse Wallet)

type APIWalletsAccounts =
    "wallets" :> Capture "walletId" WalletId
              :> Tags '["Accounts"] :> Accounts.API

-- Sorted by relevance, CRUD.
type API = APIWalletsNew
      :<|> APIWalletsGet
      :<|> APIWalletsGetSingle
      :<|> APIWalletsUpdate
      :<|> APIWalletsDelete

      :<|> APIWalletsPassword
      -- Nest the Accounts API
      :<|> APIWalletsAccounts


