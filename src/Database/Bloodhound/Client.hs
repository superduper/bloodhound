{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}

-------------------------------------------------------------------------------
-- |
-- Module : Database.Bloodhound.Client
-- Copyright : (C) 2014 Chris Allen
-- License : BSD-style (see the file LICENSE)
-- Maintainer : Chris Allen <cma@bitemyapp.com
-- Stability : provisional
-- Portability : OverloadedStrings
--
-- Client side functions for talking to Elasticsearch servers.
--
-------------------------------------------------------------------------------

module Database.Bloodhound.Client
       ( -- * Bloodhound client functions
         -- | The examples in this module assume the following code has been run.
         --   The :{ and :} will only work in GHCi. You'll only need the data types
         --   and typeclass instances for the functions that make use of them.

         -- $setup
         withBH
       , createIndex
       , deleteIndex
       , indexExists
       , openIndex
       , closeIndex
       , putTemplate
       , templateExists
       , deleteTemplate
       , putMapping
       , deleteMapping
       , indexDocument
       , updateDocument 
       , getDocument
       , documentExists
       , deleteDocument
       , searchAll
       , searchByIndex
       , searchByType
       , scanSearch
       , refreshIndex
       , mkSearch
       , mkAggregateSearch
       , mkHighlightSearch
       , bulk
       , pageSearch
       , mkShardCount
       , mkReplicaCount
       , getStatus
       , encodeBulkOperations
       , encodeBulkOperation
       -- * Reply-handling tools
       , isVersionConflict
       , isSuccess
       , isCreated
       )
       where

import qualified Blaze.ByteString.Builder as BB
import           Control.Applicative
import           Control.Monad
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Data.Aeson
import           Data.ByteString.Lazy.Builder
import qualified Data.ByteString.Lazy.Char8   as L
import           Data.Default.Class
import           Data.Ix
import           Data.Maybe                   (fromMaybe)
import           Data.Monoid
import           Data.Text                    (Text)
import qualified Data.Text                    as T
import qualified Data.Text.Encoding           as T
import qualified Data.Vector                  as V
import           Network.HTTP.Client
import qualified Network.HTTP.Types.Method    as NHTM
import qualified Network.HTTP.Types.Status    as NHTS
import qualified Network.HTTP.Types.URI       as NHTU
import           Prelude                      hiding (filter, head)
import           URI.ByteString               hiding (Query)

import           Database.Bloodhound.Types

-- $setup
-- >>> :set -XOverloadedStrings
-- >>> :set -XDeriveGeneric
-- >>> import Database.Bloodhound
-- >>> import Test.DocTest.Prop (assert)
-- >>> let testServer = (Server "http://localhost:9200")
-- >>> let runBH' = withBH defaultManagerSettings testServer
-- >>> let testIndex = IndexName "twitter"
-- >>> let testMapping = MappingName "tweet"
-- >>> let defaultIndexSettings = IndexSettings (ShardCount 1) (ReplicaCount 0)
-- >>> data TweetMapping = TweetMapping deriving (Eq, Show)
-- >>> _ <- runBH' $ deleteIndex testIndex >> deleteMapping testIndex testMapping
-- >>> import GHC.Generics
-- >>> import           Data.Time.Calendar        (Day (..))
-- >>> import Data.Time.Clock (UTCTime (..), secondsToDiffTime)
-- >>> :{
--instance ToJSON TweetMapping where
--          toJSON TweetMapping =
--            object ["tweet" .=
--              object ["properties" .=
--                object ["location" .=
--                  object ["type" .= ("geo_point" :: Text)]]]]
--data Location = Location { lat :: Double
--                         , lon :: Double } deriving (Eq, Generic, Show)
--data Tweet = Tweet { user     :: Text
--                    , postDate :: UTCTime
--                    , message  :: Text
--                    , age      :: Int
--                    , location :: Location } deriving (Eq, Generic, Show)
--exampleTweet = Tweet { user     = "bitemyapp"
--                      , postDate = UTCTime
--                                   (ModifiedJulianDay 55000)
--                                   (secondsToDiffTime 10)
--                      , message  = "Use haskell!"
--                      , age      = 10000
--                      , location = Location 40.12 (-71.34) }
--instance ToJSON   Tweet
--instance FromJSON Tweet
--instance ToJSON   Location
--instance FromJSON Location
--data BulkTest = BulkTest { name :: Text } deriving (Eq, Generic, Show)
--instance FromJSON BulkTest
--instance ToJSON BulkTest
-- :}

-- | 'mkShardCount' is a straight-forward smart constructor for 'ShardCount'
--   which rejects 'Int' values below 1 and above 1000.
--
-- >>> mkShardCount 10
-- Just (ShardCount 10)
mkShardCount :: Int -> Maybe ShardCount
mkShardCount n
  | n < 1 = Nothing
  | n > 1000 = Nothing
  | otherwise = Just (ShardCount n)

-- | 'mkReplicaCount' is a straight-forward smart constructor for 'ReplicaCount'
--   which rejects 'Int' values below 1 and above 1000.
--
-- >>> mkReplicaCount 10
-- Just (ReplicaCount 10)
mkReplicaCount :: Int -> Maybe ReplicaCount
mkReplicaCount n
  | n < 1 = Nothing
  | n > 1000 = Nothing -- ...
  | otherwise = Just (ReplicaCount n)

emptyBody :: L.ByteString
emptyBody = L.pack ""

dispatch :: MonadBH m => Method -> Text -> Maybe L.ByteString
            -> m Reply
dispatch dMethod url body = do
  initReq <- liftIO $ parseUrl' url
  let reqBody = RequestBodyLBS $ fromMaybe emptyBody body
  let req = initReq { method = dMethod
                    , requestBody = reqBody
                    , checkStatus = \_ _ _ -> Nothing}
  mgr <- bhManager <$> getBHEnv
  liftIO $ httpLbs req mgr

joinPath' :: [Text] -> Text
joinPath' = T.intercalate "/"

joinPath :: MonadBH m => [Text] -> m Text
joinPath ps = do
  Server s <- bhServer <$> getBHEnv
  return $ joinPath' (s:ps)

appendSearchTypeParam :: Text -> SearchType -> Text
appendSearchTypeParam originalUrl st = addQuery params originalUrl
  where stText = "search_type"
        params
          | st == SearchTypeDfsQueryThenFetch = [(stText, Just "dfs_query_then_fetch")]
          | st == SearchTypeCount             = [(stText, Just "count")]
          | st == SearchTypeScan              = [(stText, Just "scan"), ("scroll", Just "1m")]
          | st == SearchTypeQueryAndFetch     = [(stText, Just "query_and_fetch")]
          | st == SearchTypeDfsQueryAndFetch  = [(stText, Just "dfs_query_and_fetch")]
        -- used to catch 'SearchTypeQueryThenFetch', which is also the default
          | otherwise                         = [(stText, Just "query_then_fetch")]

-- | Severely dumbed down query renderer. Assumes your data doesn't
-- need any encoding
addQuery :: [(Text, Maybe Text)] -> Text -> Text
addQuery q u = u <> rendered
  where
    rendered =
      T.decodeUtf8 $ BB.toByteString $ NHTU.renderQueryText prependQuestionMark q
    prependQuestionMark = True

bindM2 :: (Applicative m, Monad m) => (a -> b -> m c) -> m a -> m b -> m c
bindM2 f ma mb = join (f <$> ma <*> mb)

-- | Convenience function that sets up a manager and BHEnv and runs
-- the given set of bloodhound operations. Connections will be
-- pipelined automatically in accordance with the given manager
-- settings in IO. If you've got your own monad transformer stack, you
-- should use 'runBH' directly.
withBH :: ManagerSettings -> Server -> BH IO a -> IO a
withBH ms s f = withManager ms $ \mgr -> do
  let env = BHEnv { bhServer  = s
                  , bhManager = mgr }
  runBH env f

-- Shortcut functions for HTTP methods
delete :: MonadBH m => Text -> m Reply
delete = flip (dispatch NHTM.methodDelete) Nothing
get    :: MonadBH m => Text -> m Reply
get    = flip (dispatch NHTM.methodGet) Nothing
head   :: MonadBH m => Text -> m Reply
head   = flip (dispatch NHTM.methodHead) Nothing
put    :: MonadBH m => Text -> Maybe L.ByteString -> m Reply
put    = dispatch NHTM.methodPut
post   :: MonadBH m => Text -> Maybe L.ByteString -> m Reply
post   = dispatch NHTM.methodPost

-- indexDocument s ix name doc = put (root </> s </> ix </> name </> doc) (Just encode doc)
-- http://hackage.haskell.org/package/http-client-lens-0.1.0/docs/Network-HTTP-Client-Lens.html
-- https://github.com/supki/libjenkins/blob/master/src/Jenkins/Rest/Internal.hs

-- | 'getStatus' fetches the 'Status' of a 'Server'
--
-- >>> serverStatus <- runBH' getStatus
-- >>> fmap status (serverStatus)
-- Just 200
getStatus :: MonadBH m => m (Maybe Status)
getStatus = do
  url <- joinPath []
  request <- liftIO $ parseUrl' url
  mgr <- bhManager <$> getBHEnv
  response <- liftIO $ httpLbs request mgr
  return $ decode (responseBody response)

-- | 'createIndex' will create an index given a 'Server', 'IndexSettings', and an 'IndexName'.
--
-- >>> response <- runBH' $ createIndex defaultIndexSettings (IndexName "didimakeanindex")
-- >>> respIsTwoHunna response
-- True
-- >>> runBH' $ indexExists (IndexName "didimakeanindex")
-- True
createIndex :: MonadBH m => IndexSettings -> IndexName -> m Reply
createIndex indexSettings (IndexName indexName) =
  bindM2 put url (return body)
  where url = joinPath [indexName]
        body = Just $ encode indexSettings

-- | 'deleteIndex' will delete an index given a 'Server', and an 'IndexName'.
--
-- >>> _ <- runBH' $ createIndex defaultIndexSettings (IndexName "didimakeanindex")
-- >>> response <- runBH' $ deleteIndex (IndexName "didimakeanindex")
-- >>> respIsTwoHunna response
-- True
-- >>> runBH' $ indexExists testIndex
-- False
deleteIndex :: MonadBH m => IndexName -> m Reply
deleteIndex (IndexName indexName) =
  delete =<< joinPath [indexName]

statusCodeIs :: Int -> Reply -> Bool
statusCodeIs n resp = NHTS.statusCode (responseStatus resp) == n

respIsTwoHunna :: Reply -> Bool
respIsTwoHunna = statusCodeIs 200

existentialQuery :: MonadBH m => Text -> m (Reply, Bool)
existentialQuery url = do
  reply <- head url
  return (reply, respIsTwoHunna reply)

-- | 'indexExists' enables you to check if an index exists. Returns 'Bool'
--   in IO
--
-- >>> exists <- runBH' $ indexExists testIndex
indexExists :: MonadBH m => IndexName -> m Bool
indexExists (IndexName indexName) = do
  (_, exists) <- existentialQuery =<< joinPath [indexName]
  return exists

-- | 'refreshIndex' will force a refresh on an index. You must
-- do this if you want to read what you wrote.
--
-- >>> _ <- runBH' $ createIndex defaultIndexSettings testIndex
-- >>> _ <- runBH' $ refreshIndex testIndex
refreshIndex :: MonadBH m => IndexName -> m Reply
refreshIndex (IndexName indexName) =
  bindM2 post url (return Nothing)
  where url = joinPath [indexName, "_refresh"]

stringifyOCIndex :: OpenCloseIndex -> Text
stringifyOCIndex oci = case oci of
  OpenIndex  -> "_open"
  CloseIndex -> "_close"

openOrCloseIndexes :: MonadBH m => OpenCloseIndex -> IndexName -> m Reply
openOrCloseIndexes oci (IndexName indexName) =
  bindM2 post url (return Nothing)
  where ociString = stringifyOCIndex oci
        url = joinPath [indexName, ociString]

-- | 'openIndex' opens an index given a 'Server' and an 'IndexName'. Explained in further detail at
--   <http://www.elasticsearch.org/guide/en/elasticsearch/reference/current/indices-open-close.html>
--
-- >>> reply <- runBH' $ openIndex testIndex
openIndex :: MonadBH m => IndexName -> m Reply
openIndex = openOrCloseIndexes OpenIndex

-- | 'closeIndex' closes an index given a 'Server' and an 'IndexName'. Explained in further detail at
--   <http://www.elasticsearch.org/guide/en/elasticsearch/reference/current/indices-open-close.html>
--
-- >>> reply <- runBH' $ closeIndex testIndex
closeIndex :: MonadBH m => IndexName -> m Reply
closeIndex = openOrCloseIndexes CloseIndex

-- | 'putTemplate' creates a template given an 'IndexTemplate' and a 'TemplateName'.
--   Explained in further detail at
--   <https://www.elastic.co/guide/en/elasticsearch/reference/1.7/indices-templates.html>
--
--   >>> let idxTpl = IndexTemplate (TemplatePattern "tweet-*") (Just (IndexSettings (ShardCount 1) (ReplicaCount 1))) [toJSON TweetMapping]
--   >>> resp <- runBH' $ putTemplate idxTpl (TemplateName "tweet-tpl")
putTemplate :: MonadBH m => IndexTemplate -> TemplateName -> m Reply
putTemplate indexTemplate (TemplateName templateName) =
  bindM2 put url (return body)
  where url = joinPath ["_template", templateName]
        body = Just $ encode indexTemplate

-- | 'templateExists' checks to see if a template exists.
--
--   >>> exists <- runBH' $ templateExists (TemplateName "tweet-tpl")
templateExists :: MonadBH m => TemplateName -> m Bool
templateExists (TemplateName templateName) = do
  (_, exists) <- existentialQuery =<< joinPath ["_template", templateName]
  return exists

-- | 'deleteTemplate' is an HTTP DELETE and deletes a template.
--
--   >>> let idxTpl = IndexTemplate (TemplatePattern "tweet-*") (Just (IndexSettings (ShardCount 1) (ReplicaCount 1))) [toJSON TweetMapping]
--   >>> _ <- runBH' $ putTemplate idxTpl (TemplateName "tweet-tpl")
--   >>> resp <- runBH' $ deleteTemplate (TemplateName "tweet-tpl")
deleteTemplate :: MonadBH m => TemplateName -> m Reply
deleteTemplate (TemplateName templateName) =
  delete =<< joinPath ["_template", templateName]

-- | 'putMapping' is an HTTP PUT and has upsert semantics. Mappings are schemas
-- for documents in indexes.
--
-- >>> _ <- runBH' $ createIndex defaultIndexSettings testIndex
-- >>> resp <- runBH' $ putMapping testIndex testMapping TweetMapping
-- >>> print resp
-- Response {responseStatus = Status {statusCode = 200, statusMessage = "OK"}, responseVersion = HTTP/1.1, responseHeaders = [("Content-Type","application/json; charset=UTF-8"),("Content-Length","21")], responseBody = "{\"acknowledged\":true}", responseCookieJar = CJ {expose = []}, responseClose' = ResponseClose}
putMapping :: (MonadBH m, ToJSON a) => IndexName
                 -> MappingName -> a -> m Reply
putMapping (IndexName indexName) (MappingName mappingName) mapping =
  bindM2 put url (return body)
  where url = joinPath [indexName, "_mapping", mappingName]
        -- "_mapping" and mappingName above were originally transposed
        -- erroneously. The correct API call is: "/INDEX/_mapping/MAPPING_NAME"
        body = Just $ encode mapping

-- | 'deleteMapping' is an HTTP DELETE and deletes a mapping for a given index.
-- Mappings are schemas for documents in indexes.
--
-- >>> _ <- runBH' $ createIndex defaultIndexSettings testIndex
-- >>> _ <- runBH' $ putMapping testIndex testMapping TweetMapping
-- >>> resp <- runBH' $ deleteMapping testIndex testMapping
-- >>> print resp
-- Response {responseStatus = Status {statusCode = 200, statusMessage = "OK"}, responseVersion = HTTP/1.1, responseHeaders = [("Content-Type","application/json; charset=UTF-8"),("Content-Length","21")], responseBody = "{\"acknowledged\":true}", responseCookieJar = CJ {expose = []}, responseClose' = ResponseClose}
deleteMapping :: MonadBH m => IndexName -> MappingName -> m Reply
deleteMapping (IndexName indexName)
  (MappingName mappingName) =
  -- "_mapping" and mappingName below were originally transposed
  -- erroneously. The correct API call is: "/INDEX/_mapping/MAPPING_NAME"
  delete =<< joinPath [indexName, "_mapping", mappingName]


versionCtlParams :: VersionControl -> [(Text, Maybe Text)]
versionCtlParams ctrl =
  let vt = T.pack . show . docVersionNumber
      versionParams v t = [ ("version", Just $ vt v), ("version_type", Just t)]
  in case ctrl of
       NoVersionControl                    -> []
       InternalVersion v                   -> versionParams v "internal"
       ExternalGT (ExternalDocVersion v)   -> versionParams v "external_gt"
       ExternalGTE (ExternalDocVersion v)  -> versionParams v "external_gte"
       ForceVersion (ExternalDocVersion v) -> versionParams v "force"


-- | 'indexDocument' is the primary way to save a single document in
--   Elasticsearch. The document itself is simply something we can
--   convert into a JSON 'Value'. The 'DocId' will function as the
--   primary key for the document.
--
-- >>> resp <- runBH' $ indexDocument testIndex testMapping defaultIndexDocumentSettings exampleTweet (DocId "1")
-- >>> print resp
-- Response {responseStatus = Status {statusCode = 201, statusMessage = "Created"}, responseVersion = HTTP/1.1, responseHeaders = [("Content-Type","application/json; charset=UTF-8"),("Content-Length","74")], responseBody = "{\"_index\":\"twitter\",\"_type\":\"tweet\",\"_id\":\"1\",\"_version\":1,\"created\":true}", responseCookieJar = CJ {expose = []}, responseClose' = ResponseClose}
indexDocument :: (ToJSON doc, MonadBH m) => IndexName -> MappingName
                 -> IndexDocumentSettings -> doc -> DocId -> m Reply
indexDocument (IndexName indexName)
  (MappingName mappingName) cfg document (DocId docId) =
  bindM2 put url (return body)
  where url = addQuery params <$> joinPath [indexName, mappingName, docId]
        parentParams = case idsParent cfg of
          Nothing -> []
          Just (DocumentParent (DocId p)) -> [ ("parent", Just p) ]
        params = (versionCtlParams $ idsVersionControl cfg) ++ parentParams
        body = Just (encode document)

     
-- | 'updateDocument' is the primary way to save a single document in
--   Elasticsearch. The document itself is simply something we can
--   convert into a JSON 'Value'. The 'DocId' will function as the
--   primary key for the document.
--
-- >>> resp <- runBH' $ updateDocument testIndex testMapping defaultIndexDocumentSettings exampleTweet (DocId "1")
-- >>> print resp
-- Response {responseStatus = Status {statusCode = 201, statusMessage = "Created"}, responseVersion = HTTP/1.1, responseHeaders = [("Content-Type","application/json; charset=UTF-8"),("Content-Length","74")], responseBody = "{\"_index\":\"twitter\",\"_type\":\"tweet\",\"_id\":\"1\",\"_version\":1,\"created\":true}", responseCookieJar = CJ {expose = []}, responseClose' = ResponseClose}
updateDocument :: (ToJSON doc, MonadBH m) => IndexName  -> MappingName
                 -> UpdateDocumentSettings -> doc -> DocId -> m Reply
updateDocument (IndexName indexName) 
	       (MappingName mappingName) cfg document (DocId docId) =
  bindM2 post url (return body)
  where url    = addQuery params <$> joinPath [indexName, mappingName, docId, "_update"]
        retryParams = [("retry_on_conflict", Just (T.pack $ show $ udsRetryAttempts cfg))]
        params = (versionCtlParams $ udsVersionControl cfg) ++ retryParams
        body   = Just (encode $ object [ "doc" .= (toJSON document)] )

-- | 'deleteDocument' is the primary way to delete a single document.
--
-- >>> _ <- runBH' $ deleteDocument testIndex testMapping (DocId "1")
deleteDocument :: MonadBH m => IndexName -> MappingName
                  -> DocId -> m Reply
deleteDocument (IndexName indexName)
  (MappingName mappingName) (DocId docId) =
  delete =<< joinPath [indexName, mappingName, docId]

-- | 'bulk' uses
--    <http://www.elasticsearch.org/guide/en/elasticsearch/reference/current/docs-bulk.html Elasticsearch's bulk API>
--    to perform bulk operations. The 'BulkOperation' data type encodes the
--    index/update/delete/create operations. You pass a 'V.Vector' of 'BulkOperation's
--    and a 'Server' to 'bulk' in order to send those operations up to your Elasticsearch
--    server to be performed. I changed from [BulkOperation] to a Vector due to memory overhead.
--
-- >>> let stream = V.fromList [BulkIndex testIndex testMapping (DocId "2") (toJSON (BulkTest "blah"))]
-- >>> _ <- runBH' $ bulk stream
-- >>> _ <- runBH' $ refreshIndex testIndex
bulk :: MonadBH m => V.Vector BulkOperation -> m Reply
bulk bulkOps = bindM2 post url (return body)
  where url = joinPath ["_bulk"]
        body = Just $ encodeBulkOperations bulkOps

-- | 'encodeBulkOperations' is a convenience function for dumping a vector of 'BulkOperation'
--   into an 'L.ByteString'
--
-- >>> let bulkOps = V.fromList [BulkIndex testIndex testMapping (DocId "2") (toJSON (BulkTest "blah"))]
-- >>> encodeBulkOperations bulkOps
-- "\n{\"index\":{\"_type\":\"tweet\",\"_id\":\"2\",\"_index\":\"twitter\"}}\n{\"name\":\"blah\"}\n"
encodeBulkOperations :: V.Vector BulkOperation -> L.ByteString
encodeBulkOperations stream = collapsed where
  blobs = fmap encodeBulkOperation stream
  mashedTaters = mash (mempty :: Builder) blobs
  collapsed = toLazyByteString $ mappend mashedTaters (byteString "\n")

mash :: Builder -> V.Vector L.ByteString -> Builder
mash = V.foldl' (\b x -> b `mappend` (byteString "\n") `mappend` (lazyByteString x))

mkBulkStreamValue :: Text -> Text -> Text -> Text -> Value
mkBulkStreamValue operation indexName mappingName docId =
  object [operation .=
          object [ "_index" .= indexName
                 , "_type"  .= mappingName
                 , "_id"    .= docId]]

-- | 'encodeBulkOperation' is a convenience function for dumping a single 'BulkOperation'
--   into an 'L.ByteString'
--
-- >>> let bulkOp = BulkIndex testIndex testMapping (DocId "2") (toJSON (BulkTest "blah"))
-- >>> encodeBulkOperation bulkOp
-- "{\"index\":{\"_type\":\"tweet\",\"_id\":\"2\",\"_index\":\"twitter\"}}\n{\"name\":\"blah\"}"
encodeBulkOperation :: BulkOperation -> L.ByteString
encodeBulkOperation (BulkIndex (IndexName indexName)
                (MappingName mappingName)
                (DocId docId) value) = blob
    where metadata = mkBulkStreamValue "index" indexName mappingName docId
          blob = encode metadata `mappend` "\n" `mappend` encode value

encodeBulkOperation (BulkCreate (IndexName indexName)
                (MappingName mappingName)
                (DocId docId) value) = blob
    where metadata = mkBulkStreamValue "create" indexName mappingName docId
          blob = encode metadata `mappend` "\n" `mappend` encode value

encodeBulkOperation (BulkDelete (IndexName indexName)
                (MappingName mappingName)
                (DocId docId)) = blob
    where metadata = mkBulkStreamValue "delete" indexName mappingName docId
          blob = encode metadata

encodeBulkOperation (BulkUpdate (IndexName indexName)
                (MappingName mappingName)
                (DocId docId) value) = blob
    where metadata = mkBulkStreamValue "update" indexName mappingName docId
          doc = object ["doc" .= value]
          blob = encode metadata `mappend` "\n" `mappend` encode doc

-- | 'getDocument' is a straight-forward way to fetch a single document from
--   Elasticsearch using a 'Server', 'IndexName', 'MappingName', and a 'DocId'.
--   The 'DocId' is the primary key for your Elasticsearch document.
--
-- >>> yourDoc <- runBH' $ getDocument testIndex testMapping (DocId "1")
getDocument :: MonadBH m => IndexName -> MappingName
               -> DocId -> m Reply
getDocument (IndexName indexName)
  (MappingName mappingName) (DocId docId) =
  get =<< joinPath [indexName, mappingName, docId]

-- | 'documentExists' enables you to check if a document exists. Returns 'Bool'
--   in IO
--
-- >>> exists <- runBH' $ documentExists testIndex testMapping (DocId "1")
documentExists :: MonadBH m => IndexName -> MappingName
                  -> DocId -> m Bool
documentExists (IndexName indexName)
  (MappingName mappingName) (DocId docId) = do
  (_, exists) <- existentialQuery =<< url
  return exists
  where url = joinPath [indexName, mappingName, docId]

dispatchSearch :: MonadBH m => Text -> Search -> m Reply
dispatchSearch url search = post url' (Just (encode search))
  where url' = appendSearchTypeParam url (searchType search)

-- | 'searchAll', given a 'Search', will perform that search against all indexes
--   on an Elasticsearch server. Try to avoid doing this if it can be helped.
--
-- >>> let query = TermQuery (Term "user" "bitemyapp") Nothing
-- >>> let search = mkSearch (Just query) Nothing
-- >>> reply <- runBH' $ searchAll search
searchAll :: MonadBH m => Search -> m Reply
searchAll = bindM2 dispatchSearch url . return
  where url = joinPath ["_search"]

-- | 'searchByIndex', given a 'Search' and an 'IndexName', will perform that search
--   against all mappings within an index on an Elasticsearch server.
--
-- >>> let query = TermQuery (Term "user" "bitemyapp") Nothing
-- >>> let search = mkSearch (Just query) Nothing
-- >>> reply <- runBH' $ searchByIndex testIndex search
searchByIndex :: MonadBH m => IndexName -> Search -> m Reply
searchByIndex (IndexName indexName) = bindM2 dispatchSearch url . return
  where url = joinPath [indexName, "_search"]

-- | 'searchByType', given a 'Search', 'IndexName', and 'MappingName', will perform that
--   search against a specific mapping within an index on an Elasticsearch server.
--
-- >>> let query = TermQuery (Term "user" "bitemyapp") Nothing
-- >>> let search = mkSearch (Just query) Nothing
-- >>> reply <- runBH' $ searchByType testIndex testMapping search
searchByType :: MonadBH m => IndexName -> MappingName -> Search
                -> m Reply
searchByType (IndexName indexName)
  (MappingName mappingName) = bindM2 dispatchSearch url . return
  where url = joinPath [indexName, mappingName, "_search"]

scanSearch' :: MonadBH m => IndexName -> MappingName -> Search -> m (Maybe ScrollId)
scanSearch' (IndexName indexName) (MappingName mappingName) search = do
    let url = joinPath [indexName, mappingName, "_search"]
        search' = search { searchType = SearchTypeScan }
    resp' <- bindM2 dispatchSearch url (return search')
    let msr = decode' $ responseBody resp' :: Maybe (SearchResult ())
        msid = maybe Nothing scrollId msr
    return msid

scroll' :: (FromJSON a, MonadBH m) => Maybe ScrollId -> m ([Hit a], Maybe ScrollId)
scroll' Nothing = return ([], Nothing)
scroll' (Just sid) = do
    url <- joinPath ["_search/scroll?scroll=1m"]
    resp' <- post url (Just . L.fromStrict $ T.encodeUtf8 sid)
    let msr = decode' $ responseBody resp' :: FromJSON a => Maybe (SearchResult a)
        resp = case msr of
            Just sr -> (hits $ searchHits sr, scrollId sr)
            _       -> ([], Nothing)
    return resp

simpleAccumilator :: (FromJSON a, MonadBH m) => [Hit a] -> ([Hit a], Maybe ScrollId) -> m ([Hit a], Maybe ScrollId)
simpleAccumilator oldHits (newHits, Nothing) = return (oldHits ++ newHits, Nothing)
simpleAccumilator oldHits ([], _) = return (oldHits, Nothing)
simpleAccumilator oldHits (newHits, msid) = do
    (newHits', msid') <- scroll' msid
    simpleAccumilator (oldHits ++ newHits) (newHits', msid')

-- | 'scanSearch' uses the 'scan&scroll' API of elastic,
-- for a given 'IndexName' and 'MappingName',
scanSearch :: (FromJSON a, MonadBH m) => IndexName -> MappingName -> Search -> m [Hit a]
scanSearch indexName mappingName search = do
    msid <- scanSearch' indexName mappingName search
    (hits, msid') <- scroll' msid
    (totalHits, _) <- simpleAccumilator [] (hits, msid')
    return totalHits

-- | 'mkSearch' is a helper function for defaulting additional fields of a 'Search'
--   to Nothing in case you only care about your 'Query' and 'Filter'. Use record update
--   syntax if you want to add things like aggregations or highlights while still using
--   this helper function.
--
-- >>> let query = TermQuery (Term "user" "bitemyapp") Nothing
-- >>> mkSearch (Just query) Nothing
-- Search {queryBody = Just (TermQuery (Term {termField = "user", termValue = "bitemyapp"}) Nothing), filterBody = Nothing, sortBody = Nothing, aggBody = Nothing, highlight = Nothing, trackSortScores = False, from = From 0, size = Size 10, searchType = SearchTypeQueryThenFetch, fields = Nothing, source = Nothing}
mkSearch :: Maybe Query -> Maybe Filter -> Search
mkSearch query filter = Search query filter Nothing Nothing Nothing False (From 0) (Size 10) SearchTypeQueryThenFetch Nothing Nothing

-- | 'mkAggregateSearch' is a helper function that defaults everything in a 'Search' except for
--   the 'Query' and the 'Aggregation'.
--
-- >>> let terms = TermsAgg $ (mkTermsAggregation "user") { termCollectMode = Just BreadthFirst }
-- >>> terms
-- TermsAgg (TermsAggregation {term = Left "user", termInclude = Nothing, termExclude = Nothing, termOrder = Nothing, termMinDocCount = Nothing, termSize = Nothing, termShardSize = Nothing, termCollectMode = Just BreadthFirst, termExecutionHint = Nothing, termAggs = Nothing})
-- >>> let myAggregation = mkAggregateSearch Nothing $ mkAggregations "users" terms
mkAggregateSearch :: Maybe Query -> Aggregations -> Search
mkAggregateSearch query mkSearchAggs = Search query Nothing Nothing (Just mkSearchAggs) Nothing False (From 0) (Size 0) SearchTypeQueryThenFetch Nothing Nothing

-- | 'mkHighlightSearch' is a helper function that defaults everything in a 'Search' except for
--   the 'Query' and the 'Aggregation'.
--
-- >>> let query = QueryMatchQuery $ mkMatchQuery (FieldName "_all") (QueryString "haskell")
-- >>> let testHighlight = Highlights Nothing [FieldHighlight (FieldName "message") Nothing]
-- >>> let search = mkHighlightSearch (Just query) testHighlight
mkHighlightSearch :: Maybe Query -> Highlights -> Search
mkHighlightSearch query searchHighlights = Search query Nothing Nothing Nothing (Just searchHighlights) False (From 0) (Size 10) SearchTypeQueryThenFetch Nothing Nothing

-- | 'pageSearch' is a helper function that takes a search and assigns the from
--    and size fields for the search. The from parameter defines the offset
--    from the first result you want to fetch. The size parameter allows you to
--    configure the maximum amount of hits to be returned.
--
-- >>> let query = QueryMatchQuery $ mkMatchQuery (FieldName "_all") (QueryString "haskell")
-- >>> let search = mkSearch (Just query) Nothing
-- >>> search
-- Search {queryBody = Just (QueryMatchQuery (MatchQuery {matchQueryField = FieldName "_all", matchQueryQueryString = QueryString "haskell", matchQueryOperator = Or, matchQueryZeroTerms = ZeroTermsNone, matchQueryCutoffFrequency = Nothing, matchQueryMatchType = Nothing, matchQueryAnalyzer = Nothing, matchQueryMaxExpansions = Nothing, matchQueryLenient = Nothing, matchQueryBoost = Nothing})), filterBody = Nothing, sortBody = Nothing, aggBody = Nothing, highlight = Nothing, trackSortScores = False, from = From 0, size = Size 10, searchType = SearchTypeQueryThenFetch, fields = Nothing, source = Nothing}
-- >>> pageSearch (From 10) (Size 100) search
-- Search {queryBody = Just (QueryMatchQuery (MatchQuery {matchQueryField = FieldName "_all", matchQueryQueryString = QueryString "haskell", matchQueryOperator = Or, matchQueryZeroTerms = ZeroTermsNone, matchQueryCutoffFrequency = Nothing, matchQueryMatchType = Nothing, matchQueryAnalyzer = Nothing, matchQueryMaxExpansions = Nothing, matchQueryLenient = Nothing, matchQueryBoost = Nothing})), filterBody = Nothing, sortBody = Nothing, aggBody = Nothing, highlight = Nothing, trackSortScores = False, from = From 10, size = Size 100, searchType = SearchTypeQueryThenFetch, fields = Nothing, source = Nothing}
pageSearch :: From     -- ^ The result offset
           -> Size     -- ^ The number of results to return
           -> Search  -- ^ The current seach
           -> Search  -- ^ The paged search
pageSearch resultOffset pageSize search = search { from = resultOffset, size = pageSize }

parseUrl' :: MonadThrow m => Text -> m Request
parseUrl' t =
  case parseURI laxURIParserOptions (T.encodeUtf8 t) of
    Right uri -> setURI def uri
    Left e -> throwM $ InvalidUrlException (T.unpack t) ("Invalid URL: " ++ show e)

setURI :: MonadThrow m => Request -> URI -> m Request
setURI req URI{..} = do
  Authority {..} <- maybe missingUA return uriAuthority
  let req' = req { secure = isSecure
                 , host   = hostBS authorityHost
                 , port   = thePort
                 , path   = uriPath
                 }
      thePort = maybe defPort portNumber authorityPort
      addAuth = maybe id addAuth' authorityUserInfo
  return $ setQueryString theQueryString $ addAuth req'
  where
    missingUA = throwM $ InvalidUrlException "N/A" "Missing URI host/port"
    addAuth' UserInfo {..} = applyBasicProxyAuth uiUsername uiPassword
    defPort
      | isSecure  = 443
      | otherwise = 80
    isSecure = case uriScheme of
      Scheme "https" -> True
      _              -> False
    theQueryString = [(k , Just v) | (k, v) <- queryPairs uriQuery]

-- | Was there an optimistic concurrency control conflict when
-- indexing a document?
isVersionConflict :: Reply -> Bool
isVersionConflict = statusCheck (== 409)

isSuccess :: Reply -> Bool
isSuccess = statusCheck (inRange (200, 299))

isCreated :: Reply -> Bool
isCreated = statusCheck (== 201)

statusCheck :: (Int -> Bool) -> Reply -> Bool
statusCheck prd = prd . NHTS.statusCode . responseStatus
