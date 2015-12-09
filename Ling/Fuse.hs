{-# LANGUAGE LambdaCase      #-}
{-# LANGUAGE TemplateHaskell #-}
module Ling.Fuse where

import           Ling.Free
import           Ling.Norm
import           Ling.Prelude hiding (subst1)
import           Ling.Proc
import           Ling.Print
import           Ling.Session

type Allocation = Term

data AllocAnn
  = Fused
  | Fuse Int

defaultFusion, autoFusion :: AllocAnn -- [Allocation] -> Maybe [Allocation]
defaultFusion = Fused
autoFusion = defaultFusion

makePrisms ''AllocAnn

instance Monoid AllocAnn where
  mempty = defaultFusion
  x `mappend` _ = x

_AllocAnn :: Prism' Allocation AllocAnn
_AllocAnn = prism' con pat where
  con = \case
    Fused   -> Def (Name "fused") []
    Fuse i  -> Def (Name "fuse" ) [litTerm . integral # i]
  pat = \case
    Def (Name "fused") []  -> Just Fused
    Def (Name "fuse" ) [i] -> i ^? litTerm . integral . re _Fuse
    Def (Name "alloc") []  -> Just (Fuse 0) -- TEMPORARY, `alloc` is defined as `fuse 0`
    Def (Name "auto" ) []  -> Just autoFusion
    _                      -> Nothing

doFuse :: [Allocation] -> Maybe [Allocation]
doFuse anns =
  case anns ^. each . _AllocAnn of
    Fused  -> Just anns
    Fuse i
      | i > 0     -> Just $ anns & each . _AllocAnn . _Fuse %~ pred
      | otherwise -> Nothing

fuseDot :: Op2 Proc
fuseDot = \case
  Act (Nu anns cds) | Just anns' <- doFuse anns ->
    case cds of
      [c, d] -> fuseProc . fuseChanDecs anns' [(c, d)]
      _      -> error . unlines $ [ "Unsupported fusion for multi-sided `new` " ++ pretty cds
                                  , "Hint: fusion can be disabled using `new/ alloc` instead of `new`" ]
  proc0@NewSlice{} -> (fuseProc proc0 `dotP`) . fuseProc
  proc0 -> (proc0 `dotP`) . fuseProc

fuseProc :: Endom Proc
fuseProc = \case
  proc0 `Dot` proc1 -> fuseDot proc0 proc1

  Act act -> fuseDot (Act act) ø

  -- go recurse...
  Procs procs -> Procs $ over each fuseProc procs
  NewSlice cs t x proc0 -> NewSlice cs t x $ fuseProc proc0

fuseChanDecs :: [Allocation] -> [(ChanDec,ChanDec)] -> Endom Proc
fuseChanDecs _    []           = id
fuseChanDecs anns ((c0,c1):cs) = fuse2Chans anns c0 c1 . fuseChanDecs anns cs

fuseSendRecv :: [Allocation] -> ChanDec -> Term -> ChanDec -> VarDec -> Order Act
fuseSendRecv anns c0 e c1 (Arg x mty) =
  Order [LetA (aDef x mty e), Nu anns ([c0,c1] & each . argBody . _Just . rsession %~ sessionStep)]

nu2 :: [Allocation] -> ChanDec -> ChanDec -> Act
nu2 anns c0 c1 = Nu anns [c0,c1]

fuse2Acts :: [Allocation] -> ChanDec -> Act -> ChanDec -> Act -> Order Act
fuse2Acts anns c0 act0 c1 act1 =
  case (act0, act1) of
    (Split _k0 _c0 cs0, Split _k1 _c1 cs1) -> Order $ zipWith (nu2 anns) cs0 cs1
              -- By typing, k0 and k1 should match, we could assert that for debugging.
    (Send _d0 e,   Recv _d1 arg) -> fuseSendRecv anns c0 e c1 arg
    (Recv _d0 arg, Send _d1 e)   -> fuseSendRecv anns c1 e c0 arg
              -- By typing, (c0,c1) and (d0,d1) should be equal, we could assert that for debugging.
    (Split{}, _)    -> error "fuse2Acts/Split: IMPOSSIBLE `split` should match another `split`"
    (Send{}, _)     -> error "fuse2Acts/Send: IMPOSSIBLE `send` should match `recv`"
    (Recv{}, _)     -> error "fuse2Acts/Recv: IMPOSSIBLE `recv` should match `send`"
    (Nu{}, _)       -> error "fuse2Acts/Nu: IMPOSSIBLE `new` does not consume channels"
    (LetA{}, _)     -> error "fuse2Acts/LetA: IMPOSSIBLE `let` does not consume channels"
    (Ax{}, _)       -> error "fuse2Acts/Ax: should be expanded before"
    (At{}, _)       -> error "fuse2Acts/At: should be expanded before"

fuse2Chans :: [Allocation] -> ChanDec -> ChanDec -> Endom Proc
fuse2Chans anns cd0 cd1 p0 =
  case mact0 of
    Nothing -> p0 -- error "fuse2Chans: mact0 is Nothing"
    Just actA ->
      let
        (cdA, cdB) = if actA ^. to fcAct . hasKey c0 then (cd0, cd1) else (cd1, cd0)
        predB :: Set Channel -> Bool
        predB fc = fc ^. hasKey (cdB ^. argName)
        mactB = p1 ^? {-scoped .-} fetchActProc predB . _Act
      in
      case mactB of
        Nothing -> error $ "fuse2Chans: mactB is Nothing" ++ pretty (cdB, p1) -- p1
        Just actB ->
          p1 & fetchActProc predB .~ toProc (fuse2Acts anns cdA actA cdB actB)
  where
    c0 = cd0 ^. argName
    c1 = cd1 ^. argName
    predA :: Set Channel -> Bool
    predA fc = fc ^. hasKey c0 || fc ^. hasKey c1

    -- TODO fuse into one traversal
    mact0 = p0 ^? {-scoped .-} fetchActProc predA . _Act
    p1    = p0 &  {-scoped .-} fetchActProc predA .~ ø

fuseProgram :: Endom Program
fuseProgram = prgDecs . each . _Sig . _3 . _Just . _Proc . _2 %~ fuseProc