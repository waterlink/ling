{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE Rank2Types        #-}
{-# LANGUAGE TypeFamilies      #-}
module Ling.Proc
  ( Dottable(..)
  , _Pref
  , _PrefDotProc
  , _ActAt
  , __Act
  , splitAx
  , subChanDecs
  , fetchActProc
  , procActs
  , procActsChans

  , fetchActPref -- Unused
  ) where

import Prelude hiding (pred)
import qualified Data.Set as Set
import qualified Data.Map as Map
import Ling.Free (fcAct,fcProc)
import Ling.Norm
import Ling.Prelude
import Ling.Rename
import Ling.Session

infixr 4 `dotP`
infixr 4 `dotPs`

class Dottable proc where
  dotP  :: proc -> Endom Proc

  dotPs :: proc -> Endom Procs
  dotPs proc = asProcs . dotP proc . mconcat . _unPrll
    where
      asProcs (Procs procs) = procs
      asProcs p             = Prll [p]

  dotsP :: [proc] -> Proc
  dotsP = foldr dotP ø

  dotsPs :: [proc] -> Procs
  dotsPs = foldr dotPs ø

  toProc :: proc -> Proc
  toProc = (`dotP` ø)

  toProcs :: proc -> Procs
  toProcs = (`dotPs` ø)

-- Not exported: used internally only
dotQ :: Op2 Proc
dotQ proc0 proc1
  | proc1 == ø = proc0
  | otherwise  = proc0 `Dot` proc1

instance Dottable a => Dottable (Maybe a) where
  Nothing `dotP` proc = proc
  Just a  `dotP` proc = a `dotP` proc

instance Dottable act => Dottable (Order act) where
  Order []         `dotP` proc = proc
  Order (act:acts) `dotP` proc = act `dotP` Order acts `dotP` proc

instance Dottable Act where
  act `dotP` proc = Act act `dotQ` proc
  toProc = Act

instance Dottable Proc where
  proc0 `dotP` proc1
    | proc1 == ø = proc0
    | otherwise  =
      case proc0 of
        Act act -> act `dotP` proc1
        proc00 `Dot` proc01 -> proc00 `dotP` proc01 `dotP` proc1
        NewSlice{} -> proc0 `Dot` proc1
        Procs procs0 -> procs0 `dotP` proc1
  toProc = id

-- Is a given process only a prefix?
_Pref :: Prism' Proc Pref
_Pref =  prism' toProc go
  where
    go = \case
      Act act            -> Just (Prll [act])
      Procs (Prll procs) -> post =<< mconcat <$> procs ^? below _Pref
      Dot{}              -> Nothing
      NewSlice{}         -> Nothing
    post pref@(Prll acts) =
      case acts of
        [_] -> Just pref
        _ | all isSendRecv acts -> Just pref
        _                       -> Nothing

instance Dottable proc => Dottable (Prll proc) where
  Prll procs0 `dotP` proc1
    | [] <- procs0 = proc1
    | [proc0] <- procs0 = proc0 `dotP` proc1
    | proc1 == ø = Procs (Prll procs0')
    | Just pref <- procs0' ^? below _Pref = mconcat pref `pdotP` proc1
    | otherwise =
        error . unlines $
          ["Unsupported sequencing of parallel processes"
          ,show procs0'
          ,show proc1
          ]

    where
      procs0' = toProc <$> procs0

      Prll []    `pdotP` proc = proc
      Prll [act] `pdotP` proc = act `dotP` proc
      Prll acts  `pdotP` proc = Procs (Prll (Act <$> acts)) `dotQ` proc

_PrefDotProc :: Prism' Proc (Pref, Proc)
_PrefDotProc = prism' (uncurry dotP) go
  where
    go = \case
      Act act -> Just (Prll [act], ø)
      procs@Procs{} -> Just (ø, procs)
      proc0 `Dot` proc1 -> proc0 ^? _Pref . to (\pref -> (pref, proc1))
      NewSlice{} -> Nothing

unParP :: CPatt -> Maybe [ChanDec]
unParP = \case
  ChanP cd -> Just [cd]
  ArrayP ParK patts -> patts ^? below _ChanP
  ArrayP _ _ -> Nothing

-- Prism valid up to the reduction rules
_ActAt :: Prism' Proc (Term, CPatt)
_ActAt = prism con pat
  where
    con (t, p) =
      case t of
        Proc cs proc0 ->
          case unParP p of
            Just cs' | length cs == length cs' ->
              let
                l = zip cs cs' & each . both %~ view cdChan
                m = l2m l
                r = Ren (\_ x -> Map.lookup x m ?| x) ø ø
              in
              rename r proc0
            _ -> p0
        _ -> p0
      where
        p0 = Act (At t p)
    pat (Act (At t p)) = Right (t, p)
    pat proc0          = Left  proc0

-- Prism valid up to the reduction rules
__Act :: Prism' Proc Act
__Act = prism con pat
  where
    con act = Act act & _ActAt %~ id
    pat (Act act) = Right act
    pat proc0     = Left proc0

splitAx :: Int -> Session -> Channel -> [Act]
splitAx n s c = [Split ParK c cs, Ax s (_cdChan <$> cs)]
  where
    ss = oneS <$> fwds n s
    cs = subChanDecs ss c

subChanDecs :: [RSession] -> Channel -> [ChanDec]
subChanDecs rss c = [ ChanDec c' (rs ^. rfactor) (Just rs)
                    | (i, rs) <- zip [0 :: Int ..] rss
                    , let c' = suffixedChan (show i) # c ]

procActs :: Traversal' Proc Act
procActs f = \case
  Act act -> Act <$> f act
  Procs procs -> Procs <$> (each . procActs) f procs
  NewSlice cs t x proc0 ->
    NewSlice cs t x <$> procActs f proc0
  proc0 `Dot` proc1 ->
    Dot <$> procActs f proc0 <*> procActs f proc1

-- Only a traversal if we don't put back actions about these channels
procActsChans :: Set Channel -> Traversal' Proc Act
procActsChans cs = procActs . filtered (\act -> not (Set.null (fcAct act `Set.intersection` cs)))

{-
skippableAct :: Channel -> Act -> Bool
skippableAct c = \case
  Send{}     -> False
  Recv{}     -> False
  NewSlice{} -> False -- TODO
  Ax{}       -> False -- TODO
  At{}       -> False -- TODO

  LetA{} -> True
  Split _ _ cds
    | c `notElem` (cds ^.. each . argName) ->
        True
    | otherwise ->
        error $ "skippableAct: re-used channel names " ++ show (c, cds)
  Nu ds
    | c `notElem` ds ^.. each . argName ->
        True
    | otherwise ->
        error $ "skippableAct: re-used channel names " ++ show (c, ds)

skippableActs :: Channel -> [Act] -> Bool
skippableActs c acts = null acts || all (skippableAct c) acts
-}

fetchActAct :: (Set Channel -> Bool) -> Lens Act Proc (Maybe Act) Proc
fetchActAct pred f act
  | pred (fcAct act) = f (Just act)
  | otherwise        = (act `dotP`) <$> f Nothing

fetchActPref :: (Set Channel -> Bool) -> Lens [Act] Proc (Maybe Act) Proc
fetchActPref pred f = \case
  [] -> f Nothing
  (act:acts)
    | pred (fcAct act) -> (Prll acts `dotP`) <$> f (Just act)
    | otherwise        -> (act  `dotP`)      <$> fetchActPref pred f acts

fetchActProcs :: (Set Channel -> Bool) -> Lens Procs Procs (Maybe Act) Proc
fetchActProcs pred = _Prll . go
  where
    go f = \case
      [] -> pure <$> f Nothing
      proc0:procs
        | pred (fcProc proc0) -> (:procs) <$> fetchActProc' pred f proc0
        | otherwise           -> (proc0:) <$> go                 f procs

fetchActProc :: (Set Channel -> Bool) -> Lens' Proc Proc
fetchActProc pred f proc = fetchActProc' pred (f . toProc) proc

fetchActProc' :: (Set Channel -> Bool) -> Lens Proc Proc (Maybe Act) Proc
fetchActProc' pred f = \case
  Act act -> fetchActAct pred f act
  Procs procs -> toProc <$> fetchActProcs pred f procs
  NewSlice cs t x proc0 ->
    NewSlice cs t x <$> fetchActProc' pred f proc0
  proc0 `Dot` proc1
    | pred (fcProc proc0) -> (`dotP` proc1) <$> fetchActProc' pred f proc0
    | otherwise           -> (proc0 `dotP`) <$> fetchActProc' pred f proc1

{-
replProcs :: (Show i, Integral i) => i -> Name -> Endom Procs
replProcs n = concatMap . replProc n

replArg :: (Show i, Integral i) => i -> Name -> ChanDec -> [ChanDec]
replArg n x (Arg d s) = go <$> [0..n-1] where
  go i = Arg (suffChan (show i ++ "#") d) (substi (x, i) s)

replProc' :: Integral i => i -> Name -> Proc -> Procs
replProc' n x p = go <$> [0..n-1] where
  go i = substi (x, i) p

replPref :: (Show i, Integral i) => i -> Name -> Act -> Endom Proc
replPref n x pref p =
  case pref of
    Split k c [a]  -> [Split k c (replArg n x a)] `dotP` replProc' n x p
    Split{}        -> error "replPref/Split"
    Send _c _e     -> error "replPref/Send"
    Recv _c _xt    -> error "replPref/Recv"
    Nu _c _d       -> error "replPref/Nu"
    NewSlice{}     -> error "replPref/NewSlice"
    -- If Ax are expanded before, nothing to do here
    -- Otherwise this should do the same as the
    -- replication of the expansion.
    -- This might be needed because of abstract sessions.
    Ax{}           -> error "replProc/Ax"
    At{}           -> error "replProc/At"

replProc :: (Show i, Integral i) => i -> Name -> Proc -> Procs
replProc n x (pref0 `Dot` procs) =
  case pref0 of
    []    -> replProcs n x procs
    [act] -> [replPref n x act procs]
  --  act : pref -> [replPref n x act (pref `dotP` procs)]
-}
-- -}
