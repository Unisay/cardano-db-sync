module Cardano.DbSync.Cache.Epoch (
  readCacheEpoch,
  readEpochFromCacheEpoch,
  writeCacheEpoch,
  writeBlockAndFeeToCacheEpoch,
  writeEpochToCacheEpoch,
) where

import qualified Cardano.Db as DB
import Cardano.DbSync.Cache.Types (Cache (..), CacheEpoch (..), CacheInternal (..))
import Cardano.DbSync.Types (CardanoBlock, EpochSlot (..))
import Cardano.Prelude
import Cardano.Slotting.Slot (EpochNo (..))
import Control.Concurrent.Class.MonadSTM.Strict (readTVarIO, writeTVar)
import Database.Persist.Postgresql (SqlBackend)

-------------------------------------------------------------------------------------
-- Epoch Cache
-------------------------------------------------------------------------------------
readCacheEpoch :: Cache -> IO (Maybe CacheEpoch)
readCacheEpoch cache =
  case cache of
    UninitiatedCache -> pure Nothing
    Cache ci -> readTVarIO (cEpoch ci)

readEpochFromCacheEpoch :: Cache -> IO (Maybe DB.Epoch)
readEpochFromCacheEpoch cache =
  case cache of
    UninitiatedCache -> pure Nothing
    Cache ci -> do
      cachedEpoch <- readTVarIO (cEpoch ci)
      case cachedEpoch of
        Nothing -> pure Nothing
        Just ce -> pure $ Just =<< ceEpoch ce

writeCacheEpoch ::
  MonadIO m =>
  Cache ->
  CacheEpoch ->
  ReaderT SqlBackend m ()
writeCacheEpoch cache cacheEpoch =
  case cache of
    UninitiatedCache -> pure ()
    Cache ci -> liftIO $ atomically $ writeTVar (cEpoch ci) $ Just cacheEpoch

writeBlockAndFeeToCacheEpoch ::
  MonadIO m =>
  Cache ->
  CardanoBlock ->
  Word64 ->
  EpochNo ->
  ReaderT SqlBackend m ()
writeBlockAndFeeToCacheEpoch cache block fees blockEpochNo =
  case cache of
    UninitiatedCache -> pure ()
    Cache ci -> do
      cachedEpoch <- liftIO $ readTVarIO (cEpoch ci)
      case cachedEpoch of
        Nothing -> do
          -- If we don't have an CacheEpoch then this is either the first block (Syncing/Folowing)
          -- So let's try and attempt to get the latest epoch from DB.
          latestEpochFromDb <- DB.queryLatestEpoch
          case latestEpochFromDb of
            -- We don't have any epochs on the DB do this is the first block
            Nothing -> writeToCacheWithEpoch ci Nothing
            -- An Epoch is returned but we need to make sure it's in the same epoch as the current block.
            -- If we're wanting to add it to cache.
            Just ep ->
              if DB.epochNo ep == unEpochNo blockEpochNo
                then writeToCacheWithEpoch ci (Just ep)
                else writeToCacheWithEpoch ci Nothing
        Just cacheE -> liftIO $ atomically $ writeTVar (cEpoch ci) (Just cacheE {ceBlock = block, ceFees = fees})
  where
    writeToCacheWithEpoch ci latestEpochFromDb =
      liftIO $ atomically $ writeTVar (cEpoch ci) (Just $ CacheEpoch latestEpochFromDb block fees)

writeEpochToCacheEpoch ::
  MonadIO m =>
  Cache ->
  DB.Epoch ->
  ReaderT SqlBackend m ()
writeEpochToCacheEpoch cache newEpoch =
  case cache of
    UninitiatedCache -> pure ()
    Cache ci -> do
      cachedEpoch <- liftIO $ readTVarIO (cEpoch ci)
      case cachedEpoch of
        Nothing -> pure ()
        Just cacheE ->
          liftIO $ atomically $ writeTVar (cEpoch ci) (Just $ cacheE {ceEpoch = Just newEpoch})
