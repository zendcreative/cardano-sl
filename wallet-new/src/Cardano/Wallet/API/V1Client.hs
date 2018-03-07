module Cardano.Wallet.API.V1Client where

import           Universum

import           Servant.API ((:<|>) (..), (:>))
import           Servant.Client (ClientEnv (..), ClientM, client, runClientM)
import           Servant.Client.Core (BaseUrl (..), Scheme (..))


import           Data.Default (def)
import           Network.Connection (TLSSettings (..))
import           Network.HTTP.Client (Manager, newManager)
import           Network.HTTP.Client.TLS (mkManagerSettings)
import           Network.TLS (ClientParams (..), credentialLoadX509FromMemory, defaultParamsClient,
                              onCertificateRequest, onServerCertificate, supportedCiphers)
import           Network.TLS.Extra.Cipher (ciphersuite_all)

--import           Cardano.Wallet.API.Request
import           Cardano.Wallet.API.Response
import           Cardano.Wallet.API.V1.Types

--import           Cardano.Wallet.API.V1.Parameters

--import qualified Cardano.Wallet.API.V1.Addresses as Addresses
--import qualified Cardano.Wallet.API.V1.Info as Info
--import qualified Cardano.Wallet.API.V1.Settings as Settings
--import qualified Cardano.Wallet.API.V1.Transactions as Transactions
--import qualified Cardano.Wallet.API.V1.Updates as Updates
import qualified Cardano.Wallet.API.V1.Wallets as Wallets


type APIWalletV1 = "api" :> "v1"


type APIWalletClientV1 = "api" :> "v1" :> (
         Wallets.APIWalletsNew
    -- :<|> Wallets.APIWalletsGet
    :<|> Wallets.APIWalletsPassword
    )


walletsNew
    :: NewWallet
    -> ClientM (WalletResponse Wallet)

--walletsGet
--    :: RequestParams
--    -> FilterOperations Wallet
--    -> SortOperations Wallet
--    -> ClientM (WalletResponse [Wallet])

walletsPassword
    :: WalletId
    -> PasswordUpdate
    -> ClientM (WalletResponse Wallet)


walletsNew
  -- :<|> walletsGet
  :<|> walletsPassword = client (Proxy @APIWalletClientV1)

data TlsCertificates = TlsCertificates
    { tlsPubCert :: ByteString
    , tlsPrivKey :: ByteString
    } deriving (Show, Eq)

-- | Run client for particular endpoint. It is assumed that
-- node is already running, with enabled Wallet Web API.
runEndpointClient
    :: TlsCertificates
    -> ClientM a
    -> IO (Either Text a)
runEndpointClient TlsCertificates{..} realClient = do
    manager <- makeClientManager tlsPubCert tlsPrivKey
    result  <- runClientM realClient (ClientEnv manager nodeURL)
    case result of
        Left problem   -> return . Left  $ toText (show problem :: String)
        Right response -> return . Right $ response
  where
    nodeURL  = BaseUrl Https nodeHost nodePort ""
    nodeHost = "localhost"
    nodePort = 8090

-- | Load credential files, because node requires TLS-connection with certificate.
makeClientManager
    :: ByteString
    -> ByteString
    -> IO Manager
makeClientManager pubCert privKey =
    case credentialLoadX509FromMemory pubCert privKey of
        Left problem -> error . toText $ "Unable to load credentials: " <> problem
        Right credential ->
            let hooks = def {
                            onCertificateRequest = \_ -> return $ Just credential,
                            onServerCertificate  = \_ _ _ _ -> return []
                        }
                clientParams = (defaultParamsClient "localhost" "") {
                                   clientHooks = hooks,
                                   clientSupported = def {
                                       supportedCiphers = ciphersuite_all
                                   }
                               }
                tlsSettings = TLSSettings clientParams
            in
            newManager $ mkManagerSettings tlsSettings Nothing

