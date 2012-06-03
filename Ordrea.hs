{-# LANGUAGE DeriveFunctor, GeneralizedNewtypeDeriving #-}
module Ordrea where

import Control.Applicative
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Control.Monad.Trans.Reader
import Data.IORef
import Data.List
import qualified Data.Map as M
import Data.Maybe
import Data.Monoid
import Data.Ord (comparing)
import qualified Data.Vector.Unboxed as U
import Data.Word
import System.Mem.Weak

newtype SignalGen a = SignalGen (ReaderT GEnv IO a)
  deriving (Monad, Functor, Applicative, MonadIO)
type Initialize = ReaderT IEnv IO
type Run = ReaderT REnv IO
type Finalize = IO

data Signal a   = Sig !Priority !(Initialize (Pull a))
data Event a    = Evt !Priority !(Initialize (Pull [a], Notifier))
data Discrete a = Dis !Priority !(Initialize (Pull a, Notifier))

type Consumer a = a -> IO ()

----------------------------------------------------------------------
-- locations and priorities

-- Location of a dynamic node.
type Location = U.Vector Word

-- Priority of updates.
data Priority = Priority
  { priLoc :: {-- UNPACK #-} !Location
  , priNum :: {-# UNPACK #-} !Int
  }
  deriving (Eq, Ord, Show) -- The default lexicographical ordering is appropriate
    -- Show is just for debugging

nextPrio :: Priority -> Priority
nextPrio prio@Priority{priNum=n} = prio{ priNum = n + 1 }

bottomLocation :: Location
bottomLocation = U.empty

bottomPrio :: Location -> Priority
bottomPrio loc = Priority
  { priLoc = loc
  , priNum = 0
  }

newLocationGen :: Location -> IO (IO Location)
newLocationGen parentLoc = do
  counter <- newRef 0
  return $ do
    num <- readRef counter
    writeRef counter $! num + 1
    return $! parentLoc `U.snoc` num

----------------------------------------------------------------------
-- SignalGen monad

data GEnv = GEnv
  { envRegisterInit :: Consumer (Initialize ())
  , envGenLocation :: IO Location
  }

runSignalGen :: Location -> Notifier -> SignalGen a -> Run a
runSignalGen parentLoc clock (SignalGen gen) = do
  (registerI, runAccumI) <- liftIO newActionAccum
  locGen <- liftIO $ newLocationGen parentLoc
  let
    genv = GEnv
      { envRegisterInit = registerI
      , envGenLocation = locGen
      }
  result <- liftIO $ runReaderT gen genv
  (_, runAccumF) <- liftIO $ runInit parentLoc clock runAccumI
  isolatingUpdates runAccumF
  return result

genLocation :: SignalGen Location
genLocation = SignalGen $ do
  gen <- asks envGenLocation
  lift gen

registerInit :: Initialize () -> SignalGen ()
registerInit ini = SignalGen $ do
  reg <- asks envRegisterInit
  lift $ reg ini

----------------------------------------------------------------------
-- Initialize monad

data IEnv = IEnv
  { envClock :: Notifier
  , envParentLocation :: Location
  , envRegisterFirstStep :: Consumer (Run ())
  }

registerFirstStep :: Run () -> Initialize ()
registerFirstStep fst = do
  reg <- asks envRegisterFirstStep
  lift $ reg fst

getClock :: Initialize Notifier
getClock = asks envClock

getParentLocation :: Initialize Location
getParentLocation = asks envParentLocation

runInit :: Location -> Notifier -> Initialize a -> IO (a, Run ())
runInit parentLoc clock i = do
  (registerF, runAccumF) <- newActionAccum
  let
    ienv = IEnv
      { envClock = clock
      , envRegisterFirstStep = registerF
      , envParentLocation = parentLoc
      }
  result <- runReaderT i ienv
  return (result, runAccumF)

----------------------------------------------------------------------
-- Run monad

data REnv = REnv
  { envRegisterFini :: Consumer (Finalize ())
  , envPendingUpdates :: IORef (M.Map Priority (Run ())) -- TODO: use heap?
  }

runRun :: Run a -> IO a
runRun run = do
  (registerF, runAccumF) <- liftIO newActionAccum
  pqueueRef <- newRef M.empty
  let
    renv = REnv
      { envRegisterFini = registerF
      , envPendingUpdates = pqueueRef
      }
  result <- runReaderT (run <* runUpdates) renv
  runAccumF
  return result

runUpdates :: Run ()
runUpdates = asks envPendingUpdates >>= loop
  where
    loop pqueueRef = do
      pending <- readRef pqueueRef
      case M.minView pending of
        Nothing -> return ()
        Just (upd, next) -> do
          writeRef pqueueRef next
          liftIO $ putStrLn $ "Running update"
          upd
          loop pqueueRef

registerFini :: IO () -> Run ()
registerFini fini = do
  reg <- asks envRegisterFini
  lift $ reg fini

registerUpd :: Priority -> Run () -> Run ()
registerUpd prio upd = do
  pqueueRef <- asks envPendingUpdates
  modifyRef pqueueRef $ M.insertWith' (>>) prio upd

isolatingUpdates :: Run a -> Run a
isolatingUpdates action = do
  pqueueRef <- asks envPendingUpdates
  pqueue <- readRef pqueueRef
  writeRef pqueueRef M.empty
  result <- action
  runUpdates
  writeRef pqueueRef pqueue
  return result

----------------------------------------------------------------------
-- push

type Notifier = Priority -> Weak (Run ()) -> IO ()

listenToNotifier :: Notifier -> Priority -> (Run ()) -> key -> Initialize ()
listenToNotifier push prio handler key = do
  weak <- liftIO $ mkWeak key handler Nothing
  liftIO $ push prio weak

newNotifier :: IO (Notifier, Run ())
newNotifier = do
  listenersRef <- newRef M.empty
  return (register listenersRef, invoke listenersRef)
  where
    register ref listenerPrio listenerWeak = do
      listenerMap <- readRef ref
      writeRef ref $! M.alter (add listenerWeak) listenerPrio listenerMap
    add weak = Just . (weak:) . fromMaybe []

    invoke ref = do
      m <- readRef ref
      m' <- M.fromList . catMaybes <$> mapM run (M.toList m)
      writeRef ref m'
      where
        run (prio, weaks) = do
          weaks' <- catMaybes <$> mapM run1 weaks
          return $! if null weaks' then Nothing else Just (prio, weaks')
        run1 weak = do
          m <- liftIO $ deRefWeak weak
          case m of
            Just listener -> do
              listener
              return $ Just weak
            Nothing -> return Nothing

pushFromOccPull :: Priority -> Pull [a] -> Initialize Notifier
pushFromOccPull prio occPull = do
  (push, trigger) <- liftIO newNotifier
  clock <- getClock
  let
    trg = do
      occs <- occPull
      when (not $ null occs) trigger
  listenToNotifier clock prio trg push
  return push

emptyNotifier :: Notifier
emptyNotifier _prio _weak = return ()

----------------------------------------------------------------------
-- pull

type Pull a = Run a

newCachedPull :: Initialize (Run a) -> SignalGen (Pull a)
newCachedPull gencalc = do
  actionRef <- newRef (error "newCachedPull: not initialized")
  registerInit $ writeRef actionRef =<< mkpull =<< gencalc
  return $ join $ readRef actionRef
  where
    mkpull calc = do
      ref <- newRef Nothing
      return $ do
        cache <- readRef ref
        case cache of
          Just val -> return val
          Nothing -> do
            val <- calc
            writeRef ref (Just val)
            registerFini $ writeRef ref Nothing
            return val

----------------------------------------------------------------------
-- events

instance Functor Event where
  fmap f = transformEvent (map f)

instance Monoid (Event a) where
  mempty = emptyEvent
  mappend x y = mergeEvents [x, y]
  mconcat = mergeEvents

listenToEvent :: Event a -> Priority -> ([a] -> Run ()) -> key -> Initialize ()
listenToEvent (Evt evtPrio evt) prio handler key = do
  (evtPull, evtNot) <- evt
  let hdl = handler =<< evtPull
  listenToNotifier evtNot prio hdl key
  parLoc <- getParentLocation
  when (priLoc evtPrio < parLoc) $
    registerFirstStep $ do
      initialOccs <- evtPull
      when (not $ null initialOccs) $
        handler initialOccs

newEventSG :: Priority -> SignalGen (Event a, [a] -> Run ())
newEventSG prio = do
  ref <- newRef []
  (push, trigger) <- liftIO newNotifier
  let evt = Evt prio $ return (eventPull ref, push)
  return (evt, eventTrigger ref trigger)

newEventInit :: Initialize ((Pull [a], Notifier), [a] -> Run ())
newEventInit = do
  ref <- newRef []
  (push, trigger) <- liftIO newNotifier
  return ((eventPull ref, push), eventTrigger ref trigger)

eventPull :: IORef [a] -> Pull [a]
eventPull buf = readRef buf

eventTrigger :: IORef [a] -> Run () -> [a] -> Run ()
eventTrigger buf notify occs = do
  writeRef buf occs
  registerFini $ writeRef buf []
  notify

transformEvent :: ([a] -> [b]) -> Event a -> Event b
transformEvent f parent@(Evt prio _) = Evt prio $ do
  (pullpush, trigger) <- newEventInit
  listenToEvent parent prio (trigger . f) pullpush
  return pullpush

generatorE :: Event (SignalGen a) -> SignalGen (Event a)
generatorE evt = do
  here <- genLocation
  let prio = bottomPrio here
  (result, trigger) <- newEventSG prio
  registerInit $ do
    clock <- getClock
    listenToEvent evt prio (handler here clock trigger) result
  return $ result
  where
    handler here clock trigger gens =
      trigger =<< mapM (runSignalGen here clock) gens

mergeEvents :: [Event a] -> Event a
mergeEvents [] = emptyEvent
mergeEvents evts = Evt prio $ do
  (pullpush, trigger) <- newEventInit
  occListRef <- newRef []
  let
    handler num occs = do
      modifyRef occListRef ((num, occs):)
      registerUpd prio upd
    upd = do
      occList <- readRef occListRef
      liftIO $ putStrLn $ "upd; occList= " ++ show (map fst occList)
      when (not $ null occList) $ do
        writeRef occListRef []
        trigger $ concatMap snd $ sortBy (comparing fst) occList
  forM_ (zip [0..] evts) $ \(num, evt) ->
    listenToEvent evt prio (handler num) pullpush
  return pullpush
  where
    prio = maximum $ map evtPrio evts
    evtPrio (Evt p _) = p

emptyEvent :: Event a
emptyEvent = Evt (bottomPrio bottomLocation) $ return (return [], emptyNotifier)

----------------------------------------------------------------------
-- discretes

newDiscrete :: a -> Priority -> SignalGen (Discrete a, Run a, a -> Run ())
newDiscrete initial prio = do
  ref <- newRef initial
  (push, trigger) <- liftIO newNotifier
  let dis = Dis prio $ return (readRef ref, push)
  return (dis, readRef ref, discreteTrigger ref trigger)

discreteTrigger :: IORef a -> Run () -> a -> Run ()
discreteTrigger buf notify val = do
  writeRef buf val
  notify

{-
listenToDiscrete :: Discrete a -> Priority -> (a -> Run ()) -> key -> Initialize ()
listenToDiscrete (Dis disPrio dis) prio handler key = do
  (disPull, disNot) <- dis
  let hdl = handler =<< disPull
  listenToNotifier evtNot prio hdl key
  parLoc <- getParentLocation
  when (priLoc evtPrio < parLoc) $
    registerFirstStep $ do
      initialOccs <- disPull
      handler initialOccs
-}

----------------------------------------------------------------------
-- signals

start :: SignalGen (Signal a) -> IO (IO a)
start gensig = do
  (clock, clockTrigger) <- newNotifier
  getval <- runRun $ do
    ref <- newRef undefined
    runSignalGen bottomLocation clock $ do
      Sig _ sig <- gensig
      registerInit $ do
        getval <- sig
        writeRef ref getval
    readRef ref
  return $ runRun $ do
    isolatingUpdates clockTrigger
    getval

externalS :: IO a -> SignalGen (Signal a)
externalS get = do
  pull <- newCachedPull $ return $ liftIO get
  return $ Sig (bottomPrio bottomLocation) $ return pull

joinS :: Signal (Signal a) -> SignalGen (Signal a)
joinS ~(Sig _sigsigprio sigsig) = do
  here <- genLocation
  let prio = bottomPrio here
  pull <- newCachedPull $ do
    parLoc <- getParentLocation
    clock <- getClock
    sigpull <- sigsig
    return $ do
      Sig _sigprio sig <- sigpull
      (pull, first) <- liftIO $ runInit parLoc clock sig
      first
      pull
  return $! Sig prio $ return pull

delayS :: a -> Signal a -> SignalGen (Signal a)
delayS initial ~(Sig _sigprio sig) = do
  ref <- newRef initial
  registerInit $ do
    clock <- getClock
    pull <- sig
    listenToNotifier clock prio (upd ref pull) ref
  return $ Sig prio $ return $ readRef ref
  where
    upd ref pull = do
      newVal <- pull
      registerFini $ writeRef ref newVal
    prio = bottomPrio bottomLocation

instance Functor Signal where
  fmap f (Sig prio pull) = Sig prio (fmap f <$> pull)

----------------------------------------------------------------------
-- events and discretes

accumD :: a -> Event (a -> a) -> SignalGen (Discrete a)
accumD initial evt@(~(Evt evtprio _)) = do
  (dis, get, set) <- newDiscrete initial prio
  registerInit $
    listenToEvent evt prio (upd get set) dis
  return dis
  where
    prio = nextPrio evtprio
    upd get set occs = do
      oldVal <- get
      set $! foldl' (flip ($)) oldVal occs

changesD :: Discrete a -> Event a
changesD (Dis prio dis) = Evt prio $ do
  (pull, notifier) <- dis
  return ((:[]) <$> pull, notifier)

----------------------------------------------------------------------
-- events and signals

eventToSignal :: Event a -> Signal [a]
eventToSignal (Evt prio evt) = Sig prio $ do
  (pull, _push) <- evt
  return pull

signalToEvent :: Signal [a] -> Event a
signalToEvent (Sig sigprio sig) = Evt prio $ do
  pull <- sig
  push <- pushFromOccPull prio pull
  return (pull, push)
  where
    prio = nextPrio sigprio

----------------------------------------------------------------------
-- discretes and signals

discreteToSignal :: Discrete a -> Signal a
discreteToSignal (Dis prio dis) = Sig prio $ fst <$> dis

----------------------------------------------------------------------
-- utils

newRef :: (MonadIO m) => a -> m (IORef a)
newRef = liftIO . newIORef

readRef :: (MonadIO m) => IORef a -> m a
readRef = liftIO . readIORef

writeRef :: (MonadIO m) => IORef a -> a -> m ()
writeRef x v = liftIO $ writeIORef x v

modifyRef :: (MonadIO m) => IORef a -> (a -> a) -> m ()
modifyRef x f = do
  old <- readRef x
  writeRef x $! f old

-- TODO: specialize
newActionAccum :: (MonadIO m) => IO (Consumer (m ()), m ())
newActionAccum = do
  actions <- newRef []
  return (add actions, run actions)
  where
    add ref act = modifyIORef ref (act:)
    run ref = readRef ref >>= sequence_

----------------------------------------------------------------------
-- tests

test0 = do
  smp <- start $ do
    strS <- externalS $ do
      putStrLn "input:"
      getLine
    return $ eventToSignal (signalToEvent strS)
  smp >>= print
  smp >>= print
  smp >>= print
  smp >>= print

test1 = do
  smp <- start $ do
    strS <- externalS $ do
      putStrLn "input:"
      getLine
    accD <- accumD "<zero>" $ append <$> signalToEvent strS
    return $ discreteToSignal accD
  smp >>= print
  smp >>= print
  smp >>= print
  where
    append ch str = str ++ "/" ++ show ch

test2 = do
  smp <- start $ do
    strS <- externalS $ do
      putStrLn "input:"
      getLine
    accD <- accumD "<zero>" $ append <$> signalToEvent strS
    return $ eventToSignal $ changesD accD
  smp >>= print
  smp >>= print
  smp >>= print
  where
    append ch str = str ++ "/" ++ show ch

test3 = do
  smp <- start $ do
    strS <- externalS $ do
      putStrLn "input:"
      getLine
    accD <- accumD "<zero>" $ append <$> signalToEvent strS
    return $ eventToSignal $ changesD accD `mappend` (signalToEvent $ (:[]) <$> strS)
  smp >>= print
  smp >>= print
  smp >>= print
  where
    append ch str = str ++ "/" ++ show ch

-- vim: sw=2 ts=2 sts=2
