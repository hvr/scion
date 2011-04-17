{-# LANGUAGE PatternGuards, CPP,
             FlexibleInstances, FlexibleContexts, MultiParamTypeClasses,
             TypeSynonymInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans -fno-warn-name-shadowing #-}
-- |
-- Module      : Scion.Inspect
-- Copyright   : (c) Thomas Schilling 2008
-- License     : BSD-style
--
-- Maintainer  : nominolo@gmail.com
-- Stability   : experimental
-- Portability : portable
--
-- Functionality to inspect Haskell programs.
--
module Scion.Inspect 
  ( typeOfResult, prettyResult
  , typeDecls, classDecls, familyDecls
  , toplevelNames, outline
  , module Scion.Inspect.Find
  , module Scion.Inspect.TypeOf
  ) where

import Scion.Ghc
import Scion.Utils()
import Scion.Inspect.Find
import Scion.Inspect.TypeOf
import Scion.Types.Notes
import Scion.Types.Outline

import Bag
import Var ( varType )
import DataCon ( dataConUserType )
#if __GLASGOW_HASKELL__ < 700
import Type ( tidyType )
#else
import TcType ( tidyType )
#endif
import VarEnv ( emptyTidyEnv )

import Data.Generics.Biplate
import Data.Generics.UniplateStr hiding ( Str (..) )
import qualified Data.Generics.Str as U
import Data.List ( foldl' )

#if __GLASGOW_HASKELL__ >= 700
import Util(filterOut)
#endif

#ifdef SCION_DEBUG
--import FastString
import Test.QuickCheck()
import Test.GHC.Gen()
--import Debug.Trace
--import StaticFlags ( initStaticOpts )
#endif
------------------------------------------------------------------------------

-- | Extract the type of a search result.
typeOfResult :: SearchResult Id -> Maybe Type
typeOfResult (FoundId i) = Just $ tidyType emptyTidyEnv $ varType i
typeOfResult (FoundCon _ c) = Just $ dataConUserType c
typeOfResult _ = Nothing

-- | Pretty-print a search result.
prettyResult :: OutputableBndr id => SearchResult id -> SDoc
prettyResult (FoundId i) = ppr i
prettyResult (FoundName n) = ppr n
prettyResult (FoundCon _ c) = ppr c
prettyResult r = ppr r

------------------------------------------------------------------------------

typeDecls :: TypecheckedMod m => m -> [LTyClDecl Name]
typeDecls m | Just grp <- renamedSourceGroup `fmap` renamedSource m =
    [ t
#if __GLASGOW_HASKELL__ < 700
        | t <- hs_tyclds grp
#else
        | t <- concat (hs_tyclds grp)
#endif
        , isDataDecl (unLoc t) 
            || isTypeDecl (unLoc t) 
            || isSynDecl (unLoc t) ]
    -- XXX: include families?
typeDecls _ = error "typeDecls: No renamer information available."

classDecls :: RenamedSource -> [LTyClDecl Name]
classDecls rn_src =
    [ t
#if __GLASGOW_HASKELL__ < 700
        | t <- hs_tyclds (renamedSourceGroup rn_src)
#else
        | t <- concat (hs_tyclds (renamedSourceGroup rn_src))
#endif
        , isClassDecl (unLoc t) ]

familyDecls :: RenamedSource -> [LTyClDecl Name]
familyDecls rn_src =
    [ t
#if __GLASGOW_HASKELL__ < 700
        | t <- hs_tyclds (renamedSourceGroup rn_src)
#else
        | t <- concat (hs_tyclds (renamedSourceGroup rn_src))
#endif
        , isFamilyDecl (unLoc t) ]

toplevelNames :: TypecheckedMod m => m -> [Name]
toplevelNames m  = extractNames (outline "" m)

------------------------------------------------------------------------------

typeToName :: [(TyClDecl Name -> Bool, [Char])]
typeToName = [(isFamilyDecl, "family")
             ,(isClassDecl,  "class")
             ,(isDataDecl,   "data")
             ,(isSynDecl,    "syn")
             ,(const True,   "type")]

mkConDeclOutlineDef :: FilePath -> SrcSpan -> Name -> Located (ConDecl Name) -> [OutlineDef]
mkConDeclOutlineDef  base_dir sp n (L _ c@(ConDecl { con_name = lname})) =
  let
    L sp2 n2 = lname
    o1 = OutlineDef (Left n2) "constructor"
                    (ghcSpanToLocation base_dir sp2) (ghcSpanToLocation base_dir sp)
                    (Just (n,"data"))

    os = case con_details c of
           RecCon flds -> 
             [ OutlineDef (Left n3) "field"
                          (ghcSpanToLocation base_dir sp3)
                          (ghcSpanToLocation base_dir sp)
                          (Just (n2,"constructor"))
              | L sp3 n3 <- map cd_fld_name flds ]
           _ -> []
  in
    (o1:os)

mkOutlineDef :: FilePath -> Located (TyClDecl Name) -> [OutlineDef]
mkOutlineDef base_dir (L sp (TyData {tcdLName = tc_name, tcdCons = cons})) =
  let
    L sp2 n = tc_name
    o1 = OutlineDef (Left n) "data" 
                    (ghcSpanToLocation base_dir sp2)
                    (ghcSpanToLocation base_dir sp)
                    Nothing
    os = concat $ map (mkConDeclOutlineDef base_dir sp2 n) cons
  in
    (o1:os)
mkOutlineDef base_dir (L sp (ClassDecl {tcdLName = cls_name, tcdSigs = sigs})) =
  let
    L sp2 n = cls_name
    o1 = OutlineDef (Left n) "class"
                    (ghcSpanToLocation base_dir sp2)
                    (ghcSpanToLocation base_dir sp)
                    Nothing
    os = [OutlineDef (Left n2) "function" 
                     (ghcSpanToLocation base_dir sp3)
                     (ghcSpanToLocation base_dir sp)
                     (Just (n,"class"))
          | L _ (TypeSig (L sp3 n2) _) <- sigs]
  in
    (o1:os)
mkOutlineDef base_dir (L sp t) = 
  let
    tN = foldl' (\tn (f, result) -> 
                     if null tn 
		     then if (f t) 
			  then result
			  else tn
		     else tn)
                "" typeToName
  in
    [OutlineDef (Left n) tN
                (ghcSpanToLocation base_dir sp2)
                (ghcSpanToLocation base_dir sp)
                Nothing
     | L sp2 n <- tyClDeclNames t]

#if __GLASGOW_HASKELL__ >= 700
-- Taken from http://www.haskell.org/ghc/docs/6.12.2/html/libraries/ghc-6.12.2/src/HsDecls.html#tyClDeclNames
tyClDeclNames :: Eq name => TyClDecl name -> [Located name]
-- ^ Returns all the /binding/ names of the decl, along with their SrcLocs.
-- The first one is guaranteed to be the name of the decl. For record fields
-- mentioned in multiple constructors, the SrcLoc will be from the first
-- occurence.  We use the equality to filter out duplicate field names

tyClDeclNames (TyFamily    {tcdLName = name})    = [name]
tyClDeclNames (TySynonym   {tcdLName = name})    = [name]
tyClDeclNames (ForeignType {tcdLName = name})    = [name]

tyClDeclNames (ClassDecl {tcdLName = cls_name, tcdSigs = sigs, tcdATs = ats})
  = cls_name :
    concatMap (tyClDeclNames . unLoc) ats ++ [n | L _ (TypeSig n _) <- sigs]

tyClDeclNames (TyData {tcdLName = tc_name, tcdCons = cons})
  = tc_name : hsConDeclsNames cons

-- Taken from http://www.haskell.org/ghc/docs/6.12.2/html/libraries/ghc-6.12.2/src/HsDecls.html#hsConDeclsNames
hsConDeclsNames :: (Eq name) => [LConDecl name] -> [Located name]
  -- See tyClDeclNames for what this does
  -- The function is boringly complicated because of the records
  -- And since we only have equality, we have to be a little careful
hsConDeclsNames cons
  = snd (foldl do_one ([], []) cons)
  where
    do_one (flds_seen, acc) (L _ (ConDecl { con_name = lname, con_details = RecCon flds }))
	= (map unLoc new_flds ++ flds_seen, lname : new_flds ++ acc)
	where
	  new_flds = filterOut (\f -> unLoc f `elem` flds_seen)
			       (map cd_fld_name flds)

    do_one (flds_seen, acc) (L _ (ConDecl { con_name = lname }))
	= (flds_seen, lname:acc)
#endif

valBinds :: FilePath -> HsGroup Name -> [OutlineDef]
valBinds base_dir grp =
    let ValBindsOut bind_grps _sigs = hs_valds grp
    in [ n | (_, binds0) <- bind_grps
           , L sp bind <- bagToList binds0
           , n <- case bind of
                    FunBind {fun_id = L sp2 n} ->
                      [OutlineDef (Left n) "function"
                                  (ghcSpanToLocation base_dir sp2)
                                  (ghcSpanToLocation base_dir sp)
                                  Nothing]
                    PatBind {pat_lhs = L sp2 p} ->
                      [OutlineDef (Left n) "pattern"
                                  (ghcSpanToLocation base_dir sp2)
                                  (ghcSpanToLocation base_dir sp)
                                  Nothing
                       | n <- pat_names p]
                    _ -> []
       ]
  where
    -- return names bound by pattern
    pat_names :: Pat Name -> [Name]
    pat_names pat = collectPatBinders (L noSrcSpan pat)

instBinds :: FilePath -> HsGroup Name -> [OutlineDef]
instBinds base_dir grp = 
  [OutlineDef (Right $ pretty n) "instance"
              (ghcSpanToLocation base_dir sp)
              (ghcSpanToLocation base_dir sp) Nothing
   | L sp n <- hs_instds grp]
 where
   pretty (InstDecl inst_ty _ _ _) = showSDocUnqual $ ppr inst_ty

-- | Generate outline view for the given module.
outline :: TypecheckedMod m => 
           FilePath
           -- ^ The base directory for relative source locations,
           -- typically the project root.
        -> m
        -> [OutlineDef]
outline base_dir m
  | Just grp <- renamedSourceGroup `fmap` renamedSource m =
     concatMap (mkOutlineDef base_dir)
#if __GLASGOW_HASKELL__ < 700
               (hs_tyclds grp)
#else
               (concat $ hs_tyclds grp)
#endif
       ++ valBinds base_dir grp
       ++ instBinds base_dir grp
outline _ _ = []

------------------------------------------------------------------------------


instance Uniplate a => Biplate a a where
  biplate = uniplate

instance Uniplate (Pat n) where
  uniplate pat = case pat of
    WildPat _         -> (Zero, \Zero -> pat)
    VarPat _          -> (Zero, \Zero -> pat)
    VarPatOut _n _     -> (Zero, \Zero -> pat) --down binds (VarPatOut n)
    LazyPat (L s p)   -> (One p, \(One p') -> LazyPat (L s p'))
    AsPat n (L s p)   -> (One p, \(One p') -> AsPat n (L s p'))
    ParPat (L s p)    -> (One p, \(One p') -> ParPat (L s p'))
    BangPat (L s p)   -> (One p, \(One p') -> BangPat (L s p'))
    ListPat ps t      -> down ps (\ps' -> ListPat ps' t)
    TuplePat ps b t   -> down ps (\ps' -> TuplePat ps' b t)
    PArrPat ps t      -> down ps (\ps' -> PArrPat ps' t)
    ConPatIn c details -> down details (ConPatIn c)
    ConPatOut dcon tvs pds binds args ty -> -- also look inside binds?
              down args (\args' -> ConPatOut dcon tvs pds binds args' ty)
    ViewPat e (L s p) t -> (One p, \(One p') -> ViewPat e (L s p') t)
    QuasiQuotePat _   -> (Zero, \Zero -> pat)
    LitPat _          -> (Zero, \Zero -> pat)
    NPat _ _ _        -> (Zero, \Zero -> pat)
    NPlusKPat _ _ _ _ -> (Zero, \Zero -> pat)
    TypePat _         -> (Zero, \Zero -> pat)
    SigPatIn (L s p) t -> (One p, \(One p') -> SigPatIn (L s p') t)
    SigPatOut (L s p) t -> (One p, \(One p') -> SigPatOut (L s p') t)
    CoPat w p t       -> (One p, \(One p') -> CoPat w p' t)

instance Biplate (HsConDetails (LPat id) (HsRecFields id (LPat id))) (Pat id) where
  biplate (PrefixCon ps) = down ps PrefixCon
  biplate (RecCon fs)    = down fs RecCon
  biplate (InfixCon (L sl l) (L sr r)) =
      (Two (One l) (One r),
      \(Two (One l') (One r')) -> InfixCon (L sl l') (L sr r'))

instance (Uniplate arg) => Biplate (HsRecFields id (Located arg)) arg where
  biplate (HsRecFields flds dotdot) =
      down flds (\flds' -> HsRecFields flds' dotdot)

instance (Uniplate arg) => Biplate (HsRecField id (Located arg)) arg where
  biplate (HsRecField lid (L sl arg) b) = 
      (One arg, \(One arg') -> HsRecField lid (L sl arg') b)

instance Biplate b a => Biplate (Bag b) a where
  biplate = uniplateOnBag biplate

--instance Biplate (HsBindLr n n) 

uniplateOnBag :: (a -> (U.Str b, U.Str b -> a))
              -> Bag a -> (U.Str b, U.Str b -> Bag a)
uniplateOnBag f bag = (as, \ns -> listToBag (bs ns))
                      where (as, bs) = uniplateOnList f (bagToList bag)

down :: Biplate from to => from -> (from -> c) -> (U.Str to, U.Str to -> c)
down b f = (ps, \ps' -> f (set ps'))
  where (ps, set) = biplate b

-- BiplateType from to = (Str to, Str to -> from)

instance Biplate b a => Biplate (Located b) a where
  biplate (L s b) = down b (L s)
{-
instance Uniplate a => Biplate (Located a) a where
  biplate (L s a) = (One a, \(One a') -> L s a')
-}
instance Biplate b a => Biplate [b] a where
  biplate = uniplateOnList biplate
{-                           
fmap (fst . biplate) (listStr bs),
                strList . fmap (snd . biplate))
-}
{-                
  -- biplate :: (Str a, Str a -> [b])
  -- biplate :: (Str a, Str a -> b)
-}
{-
instance Biplate [(Located a)] a where
  biplate las = (unLoc `fmap` listStr las,
                 zipWith (\(L s _) a -> L s a) las . strList)
-}
{-
instance Biplate a b => Biplate (Bag a) b where
  biplate b = (foldBag 
-}
