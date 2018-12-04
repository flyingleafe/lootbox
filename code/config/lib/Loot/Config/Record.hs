{- SPDX-License-Identifier: MPL-2.0 -}

{-# LANGUAGE ConstraintKinds      #-}
{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE GADTs                #-}
{-# LANGUAGE KindSignatures       #-}
{-# LANGUAGE OverloadedLabels     #-}
{-# LANGUAGE PolyKinds            #-}
{-# LANGUAGE StandaloneDeriving   #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE TypeOperators        #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Vinyl records for configuration.
module Loot.Config.Record
       ( ConfigKind (Partial, Final)

       , ItemKind
       , (:::)
       , (::<)
       , (::+)
       , (::-)

       , SumSelection
       , ToBranches

       , ConfigRec

       , Item'
       , Item (..)

       , ItemType

       , finalise
       , finaliseDeferredUnsafe
       , complement
       , upcast

       , HasOption
       , option

       , HasSub
       , sub

       , HasSum
       , tree

       , HasBranch
       , branch

       , selection
       ) where

import Data.Default (Default (..))
import Data.Validation (Validation (Failure, Success), toEither)
import Data.Vinyl (Label, Rec ((:&), RNil))
import Data.Vinyl.Lens (RecElem, rlens, rreplace, type (<:))
import Data.Vinyl.TypeLevel (RIndex)
import GHC.TypeLits (AppendSymbol, ErrorMessage ((:<>:), ShowType, Text),
    KnownSymbol, Symbol, symbolVal, TypeError)

import qualified Text.Show (Show (show))


data ConfigKind
    = Partial
    -- ^ In a partial configuration some of the fields migh be missing, in case
    -- they will be initialised later.
    | Final
    -- ^ A final configuratoin must have all its fields initialised.


-- | Closed kind for items that can be stored in a config.
data ItemKind
    = OptionType Symbol Type
    | SubsectionType Symbol [ItemKind]
    | SumType Symbol [ItemKind]
    | BranchType Symbol [ItemKind]

-- | Type for ordinary configuration options.
--
-- Example: @"timeout" ::: Int@
type (:::) = 'OptionType

-- | Type for configurations subsections.
--
-- Example: @"constants" ::< '[ ... ]@
type (::<) = 'SubsectionType

-- | Type for a tree of configuration possibilities (like a sum-type)
--
-- Example: @"connection" ::+ '[ ... ]@
type (::+) = 'SumType

-- | Type for a branch of a configuration tree (like a sum-type constructor)
--
-- Example: @"ftpConnection" ::- '[ ... ]@
type (::-) = 'BranchType

-- | Type of configuration records of 'ConfigKind' @k@.
type ConfigRec k = Rec (Item k)


-- | Type family that interprets configuration items for vinyl records.
type family Item' (k :: ConfigKind) (i :: ItemKind) where
    Item' 'Partial (l ::: t)  = Maybe t
    Item' 'Final   (l ::: t)  = t
    Item' k        (l ::< is) = ConfigRec k is
    Item' 'Partial (l ::+ is) = ConfigRec 'Partial (SumSelection l : ToBranches is)
    Item' 'Final   (l ::+ is) = ConfigRec 'Final   (SumSelection l : ToBranches is)
    Item' 'Partial (l ::- is) = ConfigRec 'Partial is
    Item' 'Final   (l ::- is) = Maybe (ConfigRec 'Final is)

-- | Defines the tree selection option label from the tree label
type SumSelectionLabel l = AppendSymbol l "Type"

-- | Defines the tree selection option from the tree label
type SumSelection l = SumSelectionLabel l ::: String

-- | Type family that maps an ItemKind to its BranchType version
type family ToBranches (is :: [ItemKind]) :: [ItemKind] where
    ToBranches '[] = '[]
    ToBranches ((l ::: t) ': xs) = (l ::- '[(l ::: t)]) ': (ToBranches xs)
    ToBranches ((l ::< t) ': xs) = (l ::- t) ': (ToBranches xs)
    ToBranches ((l ::+ t) ': xs) = (l ::- '[(l ::+ t)]) ': (ToBranches xs)
    ToBranches ((l ::- t) ': xs) = (l ::- t) ': (ToBranches xs)

-- | Technical first-class wrapper around the type family to make it possible
-- to pattern-match on its constructors.
data Item (k :: ConfigKind) (i :: ItemKind) where
    ItemOptionP   :: Item' 'Partial (l ::: t)  -> Item 'Partial (l ::: t)
    ItemOptionF   :: Item' 'Final   (l ::: t)  -> Item 'Final   (l ::: t)
    ItemSub       :: Item' k        (l ::< is) -> Item k        (l ::< is)
    ItemSumP      :: Item' 'Partial (l ::+ is) -> Item 'Partial (l ::+ is)
    ItemSumF      :: Item' 'Final   (l ::+ is) -> Item 'Final   (l ::+ is)
    ItemBranchP   :: Item' 'Partial (l ::- is) -> Item 'Partial (l ::- is)
    ItemBranchF   :: Item' 'Final   (l ::- is) -> Item 'Final   (l ::- is)   

-- | Lens to focus onto the data actually stored inside 'Item'.
cfgItem :: Functor f => (Item' k d -> f (Item' k d)) -> Item k d -> f (Item k d)
cfgItem f (ItemOptionP x)   = ItemOptionP <$> f x
cfgItem f (ItemOptionF x)   = ItemOptionF <$> f x
cfgItem f (ItemSub rec)     = ItemSub <$> f rec
cfgItem f (ItemSumP rec)    = ItemSumP <$> f rec
cfgItem f (ItemSumF rec)    = ItemSumF <$> f rec
cfgItem f (ItemBranchP rec) = ItemBranchP <$> f rec
cfgItem f (ItemBranchF rec) = ItemBranchF <$> f rec

-- | Internal helper used to get the name of an option given the option.
itemOptionLabel :: forall k l t. KnownSymbol l => Item k (l ::: t) -> String
itemOptionLabel _ = symbolVal (Proxy :: Proxy l)

-- | Internal helper used to get the name of a subsection given the subsection.
itemSubLabel :: forall k l is. KnownSymbol l => Item k (l ::< is) -> String
itemSubLabel _ = symbolVal (Proxy :: Proxy l)

-- | Internal helper used to get the name of a sum-type given the sum-type.
itemSumLabel :: forall k l is. KnownSymbol l => Item k (l ::+ is) -> String
itemSumLabel _ = symbolVal (Proxy :: Proxy l)

-- | Internal helper used to get the name of a branch given the branch.
itemBranchLabel :: forall k l is. KnownSymbol l => Item k (l ::- is) -> String
itemBranchLabel _ = symbolVal (Proxy :: Proxy l)

-- | Require that all labels in the configuration are known.
type family LabelsKnown is :: Constraint where
    LabelsKnown '[]       = ()
    LabelsKnown ((l ::: _)  ': is) = (KnownSymbol l, LabelsKnown is)
    LabelsKnown ((l ::< us) ': is) = (KnownSymbol l, LabelsKnown us, LabelsKnown is)
    LabelsKnown ((l ::+ us) ': is) = (KnownSymbol l, LabelsKnown (ToBranches us),
                                      LabelsKnown is, KnownSymbol (SumSelectionLabel l))
    LabelsKnown ((l ::- us) ': is) = (KnownSymbol l, LabelsKnown us, LabelsKnown is)

-- | Require that all types of options satisfy a constraint.
type family ValuesConstrained c is :: Constraint where
    ValuesConstrained _ '[]       = ()
    ValuesConstrained c ((_ ::: v)  ': is) = (c v, ValuesConstrained c is)
    ValuesConstrained c ((_ ::< us) ': is) =
        ( ValuesConstrained c us
        , ValuesConstrained c is
        )
    ValuesConstrained c ((l ::+ us) ': is) =
        ( ValuesConstrained c (SumSelection l : ToBranches us)
        , ValuesConstrained c is
        )
    ValuesConstrained c ((_ ::- us) ': is) =
        ( ValuesConstrained c us
        , ValuesConstrained c is
        )

-- | Technical constraint that is needed for built-int instances for vinyl records
-- that are defined recursively using instances for indivifual fields.
-- Almost always it is satisfied automatically but needs to be listed nevertheless.
type family SubRecsConstrained c k is :: Constraint where
    SubRecsConstrained _ _ '[]       = ()
    SubRecsConstrained c k ((_ ::: _)  ': is) = SubRecsConstrained c k is
    SubRecsConstrained c k ((_ ::< us) ': is) =
        ( c (ConfigRec k us)
        , SubRecsConstrained c k us
        , SubRecsConstrained c k is
        )
    SubRecsConstrained c k ((l ::+ us) ': is) =
        ( c (ConfigRec k (SumSelection l : ToBranches us))
        , SubRecsConstrained c k (SumSelection l : ToBranches us)
        , SubRecsConstrained c k is
        )
    SubRecsConstrained c k ((_ ::- us) ': is) =
        ( c (ConfigRec k us)
        , c (Maybe (ConfigRec k us))
        , SubRecsConstrained c k us
        , SubRecsConstrained c k is
        )

-----------------------
-- Finalisation
-----------------------

-- | Make sure that all options in the configuration have values
-- and if not, return the list of missing options.
finalise :: forall is. LabelsKnown is
         => ConfigRec 'Partial is
         -> Either [String] (ConfigRec 'Final is)
finalise = toEither . finalise' ""
  where
    -- | This function essentially traverses the configuration, but it is not natural
    -- as a tranformation and it also keeps track of the prefix.
    finalise' :: forall gs. LabelsKnown gs
              => String                 -- ^ Option name prefix
              -> ConfigRec 'Partial gs
              -> Validation [String] (ConfigRec 'Final gs)
    finalise' _ RNil = pure RNil
    finalise' prf (ItemOptionP (Just x) :& xs)
        = (:&)
      <$> Success (ItemOptionF x)
      <*> finalise' prf xs
    finalise' prf (item@(ItemOptionP Nothing) :& xs)
        = (:&)
      <$> Failure [prf <> itemOptionLabel item]
      <*> finalise' prf xs
    finalise' prf (item@(ItemSub rec) :& xs)
        = (:&)
      <$> (ItemSub <$> finalise' (prf <> itemSubLabel item <> ".") rec)
      <*> finalise' prf xs
    finalise' prf (item@(ItemSumP rec) :& xs)
        = (:&)
      <$> (ItemSumF <$> finaliseSum (prf <> itemSumLabel item <> ".") rec)
      <*> finalise' prf xs
    finalise' prf (item@(ItemBranchP rec) :& xs)
        = (:&)
      <$> (ItemBranchF . Just <$> finalise' (prf <> itemBranchLabel item <> ".") rec)
      <*> finalise' prf xs

    -- | This function traverses a sum-type configuration, it essentially uses
    -- the selection option to call 'finaliseBranches' and keeps track of the prefix.
    finaliseSum
        :: forall gs l ms. (LabelsKnown gs, gs ~ (SumSelection l : ms))
        => String                 -- ^ Option name prefix
        -> ConfigRec 'Partial gs
        -> Validation [String] (ConfigRec 'Final gs)
    finaliseSum prf (item :& xs) = case item of
        ItemOptionP (Just x) -> (:&)
            <$> Success (ItemOptionF x)
            <*> finaliseBranches prf (Just x) xs
        ItemOptionP Nothing -> (:&)
            <$> Failure [prf <> itemOptionLabel item]
            <*> finaliseBranches prf Nothing xs

    -- | This function traverses a series of branches, finalizing to 'Nothing'
    -- all the ones that are not selected, effectively discarding them.
    finaliseBranches
        :: forall gs. LabelsKnown gs
        => String                 -- ^ Option name prefix
        -> Maybe String           -- ^ The selected branch to look for (if any)
        -> ConfigRec 'Partial gs
        -> Validation [String] (ConfigRec 'Final gs)
    finaliseBranches prf Nothing = \case
        RNil -> pure RNil
        (ItemBranchP _ :& xs) -> (:&)
            <$> Success (ItemBranchF Nothing)
            <*> finaliseBranches prf Nothing xs
        _ -> Failure [prf]
    finaliseBranches prf (Just sel) = \case
        RNil -> Failure [prf <> sel]
        (item@(ItemBranchP rec) :& xs) -> if sel == itemBranchLabel item
            then (:&)
                <$> (ItemBranchF . Just <$> finalise' (prf <> itemBranchLabel item <> ".") rec)
                <*> finaliseBranches prf Nothing xs
            else (:&)
                <$> Success (ItemBranchF Nothing)
                <*> finaliseBranches prf (Just sel) xs
        _ -> Failure [prf]
        -- This last catastrophic case (as well as the corresponding one before)
        -- will never happen as long as this function is used on a list of branches.
        -- It is here just because the type system cannot guarantee this.


-- | Similar to 'finalise', but does not instantly fail if some options are
-- missing, attempt to force them will fail instead.
finaliseDeferredUnsafe :: forall is. LabelsKnown is
                      => ConfigRec 'Partial is -> ConfigRec 'Final is
finaliseDeferredUnsafe RNil = RNil
finaliseDeferredUnsafe (item@(ItemOptionP opt) :& ps) =
    let failureMsg = toText $ "Undefined config item: " <> itemOptionLabel item
    in ItemOptionF (opt ?: error failureMsg) :& finaliseDeferredUnsafe ps
finaliseDeferredUnsafe (ItemSub part :& ps) =
    ItemSub (finaliseDeferredUnsafe part) :& finaliseDeferredUnsafe ps
finaliseDeferredUnsafe (ItemSumP part :& ps) =
    ItemSumF (finaliseDeferredUnsafeSum part) :& finaliseDeferredUnsafe ps
finaliseDeferredUnsafe (ItemBranchP part :& ps) =
    ItemBranchF (Just $ finaliseDeferredUnsafe part) :& finaliseDeferredUnsafe ps

-- | This is to 'finaliseDeferredUnsafe' what 'finalizeSum' is to 'finalise'
finaliseDeferredUnsafeSum
    :: forall gs l ms. (LabelsKnown gs, gs ~ (SumSelection l : ms))
    => ConfigRec 'Partial gs
    -> ConfigRec 'Final gs
finaliseDeferredUnsafeSum (item :& xs) = case item of
    ItemOptionP (Just x) -> ItemOptionF x :& finaliseDeferredUnsafeBranches (Just x) xs
    ItemOptionP Nothing -> error . toText $ "Undefined branch selection item: " <> itemOptionLabel item

-- | This is to 'finaliseDeferredUnsafe' what 'finalizeBranches' is to 'finalise'
finaliseDeferredUnsafeBranches
    :: forall is. LabelsKnown is
    => Maybe String
    -> ConfigRec 'Partial is
    -> ConfigRec 'Final is
finaliseDeferredUnsafeBranches Nothing = \case
    RNil -> RNil
    (ItemBranchP _ :& xs) ->
        ItemBranchF Nothing :& finaliseDeferredUnsafeBranches Nothing xs
    _ -> error "non-branch item as sum-type"
finaliseDeferredUnsafeBranches (Just sel) = \case
    RNil -> error $ toText $ "Branch was not found: " <> sel
    (item@(ItemBranchP rec) :& xs) -> if sel == itemBranchLabel item
        then (ItemBranchF . Just $ finaliseDeferredUnsafe rec) :&
             finaliseDeferredUnsafeBranches Nothing xs
        else ItemBranchF Nothing :& finaliseDeferredUnsafeBranches (Just sel) xs
    _ -> error "non-branch item as sum-type"
    -- NOTE: as for 'finaliseBranches' this should never happen, but the type
    -- system cannot prove it.

-- | Fill values absent in one config with values from another config.
-- Useful when total config of default values exists.
-- NOTE: A Sum-Type selected branch cannot be swapped for another one using this 
complement
    :: ConfigRec 'Partial is
    -> ConfigRec 'Final is
    -> ConfigRec 'Final is
complement RNil RNil
    = RNil
complement (ItemOptionP opt :& ps) (ItemOptionF sup :& fs)
    = ItemOptionF (fromMaybe sup opt) :& complement ps fs
complement (ItemSub part :& ps) (ItemSub final :& fs)
    = ItemSub (complement part final) :& complement ps fs
complement (ItemSumP (_ :& part) :& ps) (ItemSumF (f :& final) :& fs)
    = ItemSumF (f :& complement part final) :& complement ps fs
complement (ItemBranchP part :& ps) (ItemBranchF final :& fs)
    = ItemBranchF (complement part <$> final) :& complement ps fs

-- | Cast partial config to another partial config which is
-- a superset of the former.
upcast
    :: (Monoid (ConfigRec 'Partial xs), ys <: xs)
    => ConfigRec 'Partial ys
    -> ConfigRec 'Partial xs
upcast ys = rreplace ys mempty

-----------------------
-- Configuration lenses
-----------------------

-- | Get the type of the item by its label.
type family ItemType l is where
      ItemType l '[] = TypeError
          ( 'Text "Cannot find label " ':<>: 'ShowType l
            ':<>: 'Text " in config items"
          )
      ItemType l ((l  ::: v)  ': _) = l ::: v
      ItemType l ((l  ::< us) ': _) = l ::< us
      ItemType l ((l  ::+ us) ': _) = l ::+ us
      ItemType l ((l  ::- us) ': _) = l ::- us
      ItemType l (_  ': is) = ItemType l is


-- | Check whether a configuration of kind @k@ contains an item of type @l ::: v@.
type HasOption l is v =
    ( RecElem Rec (l ::: v) is (RIndex (l ::: v) is)
    , ItemType l is ~ (l ::: v)
    )

-- | Lens that focuses on the configuration option with the given label.
option :: forall k l v g is a. (Functor g, a ~ Item' k (l ::: v), HasOption l is v)
    => Label l
    -> (a -> g a)
    -> ConfigRec k is
    -> g (ConfigRec k is)
option _ = rlens (Proxy :: Proxy (l ::: v)) . cfgItem


-- | Check whether the configuration has the subsection.
type HasSub l is us =
    ( RecElem Rec (l ::< us) is (RIndex (l ::< us) is)
    , ItemType l is ~ (l ::< us)
    )

-- | Lens that focuses on the subsection option with the given label.
sub :: forall k l us g is a. (Functor g, a ~ Item' k (l ::< us), HasSub l is us)
    => Label l
    -> (a -> g a)
    -> ConfigRec k is
    -> g (ConfigRec k is)
sub _ = rlens (Proxy :: Proxy (l ::< us)) . cfgItem

-- | Check whether the configuration has the sum-type.
type HasSum l is us =
    ( RecElem Rec (l ::+ us) is (RIndex (l ::+ us) is)
    , ItemType l is ~ (l ::+ us)
    )

-- | Lens that focuses on the sum-type option with the given label.
tree :: forall k l us g is a. (Functor g, a ~ Item' k (l ::+ us), HasSum l is us)
    => Label l
    -> (a -> g a)
    -> ConfigRec k is
    -> g (ConfigRec k is)
tree _ = rlens (Proxy :: Proxy (l ::+ us)) . cfgItem

-- | Check whether the configuration has the branch.
type HasBranch l is us =
    ( RecElem Rec (l ::- us) is (RIndex (l ::- us) is)
    , ItemType l is ~ (l ::- us)
    )

-- | Lens that focuses on the branch option with the given label.
branch :: forall k l us g is a. (Functor g, a ~ Item' k (l ::- us), HasBranch l is us)
    => Label l
    -> (a -> g a)
    -> ConfigRec k is
    -> g (ConfigRec k is)
branch _ = rlens (Proxy :: Proxy (l ::- us)) . cfgItem

-- | Lens that focuses on the selection option of a sum-type
selection
    :: forall k l v g is a lp ms.
        ( Functor g
        , a ~ Item' k (l ::: v)
        , HasOption l is v
        , is ~ (SumSelection lp : ms)
        , l ~ SumSelectionLabel lp
        )
    => (a -> g a)
    -> ConfigRec k is
    -> g (ConfigRec k is)
selection = rlens (Proxy :: Proxy (l ::: v)) . cfgItem

-----------------------
-- Basic instances
-----------------------

deriving instance
    ( ValuesConstrained Eq '[i]
    , SubRecsConstrained Eq k '[i]
    ) => Eq (Item k i)


instance
    ( LabelsKnown '[i]
    , ValuesConstrained Show '[i]
    , SubRecsConstrained Show k '[i]
    )
    => Show (Item k i)
  where
    show item@(ItemOptionP (Just x))   = itemOptionLabel item ++ " =: " ++ show x
    show item@(ItemOptionP Nothing)    = itemOptionLabel item ++ " <unset>"
    show item@(ItemOptionF x)          = itemOptionLabel item ++ " =: " ++ show x
    show item@(ItemSub rec)            = itemSubLabel item    ++ " =< " ++ show rec
    show item@(ItemSumP rec)           = itemSumLabel item    ++ " =+ " ++ show rec
    show item@(ItemSumF rec)           = itemSumLabel item    ++ " =+ " ++ show rec
    show item@(ItemBranchP rec)        = itemBranchLabel item ++ " =- " ++ show rec
    show item@(ItemBranchF (Just rec)) = itemBranchLabel item ++ " =- " ++ show rec
    show item@(ItemBranchF Nothing)    = itemBranchLabel item ++ " <unselected>"

instance
    ( SubRecsConstrained Semigroup 'Partial '[i]
    ) => Semigroup (Item 'Partial i) where
    ItemOptionP x1 <> ItemOptionP x2 = ItemOptionP . getLast $ Last x1 <> Last x2
    ItemSub r1 <> ItemSub r2 = ItemSub $ r1 <> r2
    ItemSumP r1 <> ItemSumP r2 = ItemSumP $ r1 <> r2
    ItemBranchP r1 <> ItemBranchP r2 = ItemBranchP $ r1 <> r2


instance Monoid (Item 'Partial (l ::: t)) where
    mempty = ItemOptionP Nothing
    mappend = (<>)

instance
    ( SubRecsConstrained Semigroup 'Partial '[l ::< is]
    , SubRecsConstrained Monoid 'Partial '[l ::< is]
    ) => Monoid (Item 'Partial (l ::< is))
  where
    mempty = ItemSub mempty
    mappend = (<>)

instance
    ( SubRecsConstrained Semigroup 'Partial '[l ::+ is]
    , SubRecsConstrained Monoid 'Partial '[l ::+ is]
    ) => Monoid (Item 'Partial (l ::+ is))
  where
    mempty = ItemSumP mempty
    mappend = (<>)

instance
    ( SubRecsConstrained Semigroup 'Partial '[l ::- is]
    , SubRecsConstrained Monoid 'Partial '[l ::- is]
    ) => Monoid (Item 'Partial (l ::- is))
  where
    mempty = ItemBranchP mempty
    mappend = (<>)


instance Default (ConfigRec k '[]) where
    def = RNil

-- | Values are missing by default.
instance
    ( Default (ConfigRec 'Partial is)
    ) => Default (ConfigRec 'Partial ((i ::: t) : is)) where
    def = ItemOptionP Nothing :& def

instance
    ( Default (ConfigRec k t)
    , Default (ConfigRec k is)
    ) => Default (ConfigRec k ((i ::< t) : is)) where
    def = ItemSub def :& def

instance
    ( Default (ConfigRec 'Partial is)
    , Default (ConfigRec 'Partial (ToBranches t))
    ) => Default (ConfigRec 'Partial ((i ::+ t) : is)) where
    def = ItemSumP def :& def

instance
    ( Default (ConfigRec 'Partial t)
    , Default (ConfigRec 'Partial is)
    ) => Default (ConfigRec 'Partial ((i ::- t) : is)) where
    def = ItemBranchP def :& def
