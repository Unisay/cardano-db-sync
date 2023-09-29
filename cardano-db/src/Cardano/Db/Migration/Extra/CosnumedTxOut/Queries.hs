{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Db.Migration.Extra.CosnumedTxOut.Queries where

import Cardano.BM.Trace (Trace, logError, logInfo, logWarning)
import Cardano.Db.Error (LookupFail (..))
import Cardano.Db.Insert (insertMany', insertUnchecked)
import Cardano.Db.Migration.Extra.CosnumedTxOut.Schema
import Cardano.Db.Query (isJust, listToMaybe, queryBlockHeight, queryMaxRefId)
import Cardano.Db.Text
import Control.Exception.Lifted (handle, throwIO)
import Control.Monad.Extra (unless, when, whenJust)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Trans.Control (MonadBaseControl)
import Control.Monad.Trans.Reader (ReaderT)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)

-- import Database.Esqueleto.Experimental hiding (update, (<=.), (=.), (==.))
import Database.Esqueleto.Experimental hiding (update, (<=.), (=.), (==.))
import qualified Database.Esqueleto.Experimental as E
import Database.Persist ((<=.), (=.), (==.))
import Database.Persist.Class (update)
import Database.Persist.Sql (deleteWhereCount)
import Database.PostgreSQL.Simple (SqlError)

insertTxOutExtra :: (MonadBaseControl IO m, MonadIO m) => TxOut -> ReaderT SqlBackend m TxOutId
insertTxOutExtra = insertUnchecked "TxOutExtra"

insertManyTxOutExtra :: (MonadBaseControl IO m, MonadIO m) => [TxOut] -> ReaderT SqlBackend m [TxOutId]
insertManyTxOutExtra = insertMany' "TxOut"

queryUpdateListTxOutConsumedByTxInId :: MonadIO m => [(TxOutId, TxInId)] -> ReaderT SqlBackend m ()
queryUpdateListTxOutConsumedByTxInId ls = do
  mapM_ (uncurry updateTxOutConsumedByTxInId) ls

updateTxOutConsumedByTxInId :: MonadIO m => TxOutId -> TxInId -> ReaderT SqlBackend m ()
updateTxOutConsumedByTxInId txOutId txInId =
  update txOutId [TxOutConsumedByTxInId =. Just txInId]

querySetNullTxOut :: MonadIO m => Trace IO Text -> Maybe TxInId -> Word64 -> ReaderT SqlBackend m ()
querySetNullTxOut trce mMinTxInId txInDeleted = do
  whenJust mMinTxInId $ \txInId -> do
    txOutIds <- getTxOutConsumedAfter txInId
    mapM_ setNullTxOutConsumedAfterTxInId txOutIds
    let updatedEntries = fromIntegral (length txOutIds)
    when (updatedEntries /= txInDeleted) $
      liftIO $
        logError trce $
          Text.concat
            [ "Deleted "
            , textShow txInDeleted
            , " inputs, but set to null only "
            , textShow updatedEntries
            , "consumed outputs. Please file an issue at https://github.com/input-output-hk/cardano-db-sync/issues"
            ]

-- | This requires an index at TxOutConsumedByTxInId.
getTxOutConsumedAfter :: MonadIO m => TxInId -> ReaderT SqlBackend m [TxOutId]
getTxOutConsumedAfter txInId = do
  res <- select $ do
    txOut <- from $ table @TxOut
    where_ (txOut ^. TxOutConsumedByTxInId >=. just (val txInId))
    pure $ txOut ^. persistIdField
  pure $ unValue <$> res

-- | This requires an index at TxOutConsumedByTxInId.
setNullTxOutConsumedAfterTxInId :: MonadIO m => TxOutId -> ReaderT SqlBackend m ()
setNullTxOutConsumedAfterTxInId txOutId = do
  update txOutId [TxOutConsumedByTxInId =. Nothing]

migrateTxOut ::
  ( MonadBaseControl IO m
  , MonadIO m
  ) =>
  Maybe (Trace IO Text) ->
  ReaderT SqlBackend m ()
migrateTxOut mTrace = do
  _ <- createConsumedTxOut
  migrateNextPage 0
  where
    migrateNextPage :: MonadIO m => Word64 -> ReaderT SqlBackend m ()
    migrateNextPage offst = do
      whenJust mTrace $ \trce ->
        liftIO $ logInfo trce $ "Handling input offset " <> textShow offst
      page <- getInputPage offst pageSize
      mapM_ migratePair page
      when (fromIntegral (length page) == pageSize) $
        migrateNextPage $!
          offst
            + pageSize

migratePair :: MonadIO m => (TxInId, TxId, Word64) -> ReaderT SqlBackend m ()
migratePair (txInId, txId, index) =
  updateTxOutConsumedByTxInIdUnique txId index txInId

pageSize :: Word64
pageSize = 100_000

queryTxConsumedColumnExists :: MonadIO m => ReaderT SqlBackend m Bool
queryTxConsumedColumnExists = do
  columntExists :: [Text] <-
    fmap unSingle
      <$> rawSql
        ( mconcat
            [ "SELECT column_name FROM information_schema.columns "
            , "WHERE table_name='tx_out' and column_name='consumed_by_tx_in_id'"
            ]
        )
        []
  pure (not $ null columntExists)

-- | This is a count of the null consumed_by_tx_in_id
queryTxOutConsumedNullCount :: MonadIO m => ReaderT SqlBackend m Word64
queryTxOutConsumedNullCount = do
  res <- select $ do
    txOut <- from $ table @TxOut
    where_ (isNothing $ txOut ^. TxOutConsumedByTxInId)
    pure countRows
  pure $ maybe 0 unValue (listToMaybe res)

queryTxOutConsumedCount :: MonadIO m => ReaderT SqlBackend m Word64
queryTxOutConsumedCount = do
  res <- select $ do
    txOut <- from $ table @TxOut
    where_ (not_ $ isNothing $ txOut ^. TxOutConsumedByTxInId)
    pure countRows
  pure $ maybe 0 unValue (listToMaybe res)

createConsumedTxOut ::
  forall m.
  ( MonadBaseControl IO m
  , MonadIO m
  ) =>
  ReaderT SqlBackend m ()
createConsumedTxOut = do
  handle exceptHandler $
    rawExecute
      "ALTER TABLE tx_out ADD COLUMN consumed_by_tx_in_id INT8 NULL"
      []
  handle exceptHandler $
    rawExecute
      "CREATE INDEX IF NOT EXISTS idx_tx_out_consumed_by_tx_in_id ON tx_out (consumed_by_tx_in_id)"
      []
  handle exceptHandler $
    rawExecute
      "ALTER TABLE ma_tx_out ADD CONSTRAINT ma_tx_out_tx_out_id_fkey FOREIGN KEY(tx_out_id) REFERENCES tx_out(id) ON DELETE CASCADE ON UPDATE RESTRICT"
      []
  where
    exceptHandler :: SqlError -> ReaderT SqlBackend m a
    exceptHandler e =
      liftIO $ throwIO (DBPruneConsumed $ show e)

_validateMigration :: MonadIO m => Trace IO Text -> ReaderT SqlBackend m Bool
_validateMigration trce = do
  _migrated <- queryTxConsumedColumnExists
  --  unless migrated $ runMigration
  txInCount <- countTxIn
  consumedTxOut <- countConsumed
  if txInCount > consumedTxOut
    then do
      liftIO $
        logWarning trce $
          mconcat
            [ "Found incomplete TxOut migration. There are"
            , textShow txInCount
            , " TxIn, but only"
            , textShow consumedTxOut
            , " consumed TxOut"
            ]
      pure False
    else
      if txInCount == consumedTxOut
        then do
          liftIO $ logInfo trce "Found complete TxOut migration"
          pure True
        else do
          liftIO $
            logError trce $
              mconcat
                [ "The impossible happened! There are"
                , textShow txInCount
                , " TxIn, but "
                , textShow consumedTxOut
                , " consumed TxOut"
                ]
          pure False

updateTxOutConsumedByTxInIdUnique :: MonadIO m => TxId -> Word64 -> TxInId -> ReaderT SqlBackend m ()
updateTxOutConsumedByTxInIdUnique txOutId index txInId =
  updateWhere [TxOutTxId ==. txOutId, TxOutIndex ==. index] [TxOutConsumedByTxInId =. Just txInId]

getInputPage :: MonadIO m => Word64 -> Word64 -> ReaderT SqlBackend m [(TxInId, TxId, Word64)]
getInputPage offs pgSize = do
  res <- select $ do
    txIn <- from $ table @TxIn
    limit (fromIntegral pgSize)
    offset (fromIntegral offs)
    orderBy [asc (txIn ^. TxInId)]
    pure txIn
  pure $ convert <$> res
  where
    convert txIn =
      (entityKey txIn, txInTxOutId (entityVal txIn), txInTxOutIndex (entityVal txIn))

countTxIn :: MonadIO m => ReaderT SqlBackend m Word64
countTxIn = do
  res <- select $ do
    _ <- from $ table @TxIn
    pure countRows
  pure $ maybe 0 unValue (listToMaybe res)

countConsumed :: MonadIO m => ReaderT SqlBackend m Word64
countConsumed = do
  res <- select $ do
    txOut <- from $ table @TxOut
    where_ (isJust $ txOut ^. TxOutConsumedByTxInId)
    pure countRows
  pure $ maybe 0 unValue (listToMaybe res)

deleteAndUpdateConsumedTxOut ::
  forall m.
  (MonadIO m, MonadBaseControl IO m) =>
  Trace IO Text ->
  Word64 ->
  ReaderT SqlBackend m ()
deleteAndUpdateConsumedTxOut trce blockNoDiff = do
  maxTxInId <- findMaxTxInId blockNoDiff
  case maxTxInId of
    Left errMsg -> do
      liftIO $ logInfo trce $ "No tx_out was deleted: " <> errMsg
      migrateNextPage Nothing False 0
    Right mTxIdIn ->
      migrateNextPage (Just mTxIdIn) False 0
  where
    migrateNextPage :: Maybe TxInId -> Bool -> Word64 -> ReaderT SqlBackend m ()
    migrateNextPage maxTxInId ranCreateConsumedTxOut offst = do
      case maxTxInId of
        -- If there is no maxTxInId then don't need to deleteEntries so on first itteration we createConsumedTxOut.
        -- Then we itterate over the rest of the pages entries in chunks of `pageSize`.
        Nothing -> do
          shouldCreateConsumedTxOut trce ranCreateConsumedTxOut
          pageEntries <- getInputPage offst pageSize
          updatePageEntries pageEntries
          when (fromIntegral (length pageEntries) == pageSize) $
            migrateNextPage Nothing True $!
              offst
                + pageSize
        -- we do have a maxTxInId which allows us to delete then update and iterating using `pageSize`
        Just mxTxInId -> do
          pageEntries <- getInputPage offst pageSize
          resPageEntries <- splitAndProcessPageEntries trce ranCreateConsumedTxOut mxTxInId pageEntries
          when (fromIntegral (length pageEntries) == pageSize) $
            migrateNextPage (Just mxTxInId) resPageEntries $!
              offst
                + pageSize

-- Split the page entries by maxTxInId and process
splitAndProcessPageEntries ::
  forall m.
  (MonadIO m, MonadBaseControl IO m) =>
  Trace IO Text ->
  Bool ->
  TxInId ->
  [(TxInId, TxId, Word64)] ->
  ReaderT SqlBackend m Bool
splitAndProcessPageEntries trce ranCreateConsumedTxOut maxTxInId pageEntries = do
  let entriesSplit = span (\(txInId, _, _) -> txInId <= maxTxInId) pageEntries
  case entriesSplit of
    -- empty lists just return
    ([], []) -> pure True
    -- the whole list is less that maxTxInId
    (xs, []) -> do
      deleteEntries xs
      pure False
    -- the whole list is greater that maxTxInId
    ([], ys) -> do
      shouldCreateConsumedTxOut trce ranCreateConsumedTxOut
      updateEntries ys
      pure True
    -- the list has both bellow and above maxTxInId
    (xs, ys) -> do
      deleteEntries xs
      shouldCreateConsumedTxOut trce ranCreateConsumedTxOut
      updateEntries ys
      pure True
  where
    deleteEntries = deletePageEntries
    -- this is deleting one entry at a time to check in benchmarking
    -- deleteEntries = mapM_ (\(_, txId, index) -> deleteTxOutConsumed txId index)
    updateEntries = updatePageEntries

shouldCreateConsumedTxOut ::
  (MonadIO m, MonadBaseControl IO m) =>
  Trace IO Text ->
  Bool ->
  ReaderT SqlBackend m ()
shouldCreateConsumedTxOut trce rcc =
  unless rcc $ do
    liftIO $ logInfo trce "Created ConsumedTxOut when handling page entries."
    createConsumedTxOut

updatePageEntries ::
  MonadIO m =>
  [(TxInId, TxId, Word64)] ->
  ReaderT SqlBackend m ()
updatePageEntries = mapM_ (\(txInId, txId, index) -> updateTxOutConsumedByTxInIdUnique txId index txInId)

-- this builds up a single delete query using the pageEntries list
deletePageEntries ::
  MonadIO m =>
  [(TxInId, TxId, Word64)] ->
  ReaderT SqlBackend m ()
deletePageEntries transactionEntries = do
  delete $ do
    txOut <- from $ table @TxOut
    where_
      ( foldl1
          (||.)
          ( map
              ( \(_, txId, index) ->
                  txOut E.^. TxOutTxId E.==. val txId E.&&. txOut E.^. TxOutIndex E.==. val index
              )
              transactionEntries
          )
      )

deleteTxOutConsumed :: MonadIO m => TxId -> Word64 -> ReaderT SqlBackend m ()
deleteTxOutConsumed txOutId index =
  deleteWhere [TxOutTxId ==. txOutId, TxOutIndex ==. index]

deleteConsumedTxOut ::
  forall m.
  MonadIO m =>
  Trace IO Text ->
  Word64 ->
  ReaderT SqlBackend m ()
deleteConsumedTxOut trce blockNoDiff = do
  maxTxInId <- findMaxTxInId blockNoDiff
  case maxTxInId of
    Left errMsg -> liftIO $ logInfo trce $ "No tx_out was deleted: " <> errMsg
    Right mxtid -> deleteConsumedBeforeTxIn trce mxtid

findMaxTxInId :: forall m. MonadIO m => Word64 -> ReaderT SqlBackend m (Either Text TxInId)
findMaxTxInId blockNoDiff = do
  mBlockHeight <- queryBlockHeight
  maybe (pure $ Left "No blocks found") findConsumed mBlockHeight
  where
    findConsumed :: Word64 -> ReaderT SqlBackend m (Either Text TxInId)
    findConsumed tipBlockNo = do
      if tipBlockNo <= blockNoDiff
        then pure $ Left $ "Tip blockNo is " <> textShow tipBlockNo
        else do
          mBlockId <- queryBlockNo $ tipBlockNo - blockNoDiff
          maybe
            (pure $ Left $ "BlockNo hole found at " <> textShow (tipBlockNo - blockNoDiff))
            findConsumedBeforeBlock
            mBlockId

    findConsumedBeforeBlock :: BlockId -> ReaderT SqlBackend m (Either Text TxInId)
    findConsumedBeforeBlock blockId = do
      mTxId <- queryMaxRefId TxBlockId blockId False
      case mTxId of
        Nothing -> pure $ Left $ "No txs found before " <> textShow blockId
        Just txId -> do
          mTxInId <- queryMaxRefId TxInTxInId txId True
          pure $ maybe (Left $ "No tx_in found before or at " <> textShow txId) Right mTxInId

deleteConsumedBeforeTxIn :: MonadIO m => Trace IO Text -> TxInId -> ReaderT SqlBackend m ()
deleteConsumedBeforeTxIn trce txInId = do
  countDeleted <- deleteWhereCount [TxOutConsumedByTxInId <=. Just txInId]
  liftIO $ logInfo trce $ "Deleted " <> textShow countDeleted <> " tx_out"

queryBlockNo :: MonadIO m => Word64 -> ReaderT SqlBackend m (Maybe BlockId)
queryBlockNo blkNo = do
  res <- select $ do
    blk <- from $ table @Block
    where_ (blk ^. BlockBlockNo E.==. just (val blkNo))
    pure (blk ^. BlockId)
  pure $ fmap unValue (listToMaybe res)
