{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Data.SplayTree
  ( SplayTree (..),
    Measured (..),
    null,
    empty,
    (|>),
    (<|),
    (><),
    singleton,
    size,
    split,
    query,
    memberSplay,
    rootElem,
    delete,
    insert,
    difference,
    intersection,
    balance,
    deepL,
    deepR,
    fromList,
    fromListBalance,
    fmap',
    traverse',
  )
where

import Control.Applicative hiding (empty)
import Control.DeepSeq
import Data.Data
import Data.Foldable hiding (null)
import Data.Kind (Type)
import Data.Maybe
import Data.Monoid
import Prelude hiding (foldr, null)

infixr 5 ><

infixr 5 <|

infixl 5 |>

{-# INLINE (><) #-}

{-# INLINE (<|) #-}

{-# INLINE (|>) #-}

class (Monoid (Measure a)) => Measured a where
  type Measure a :: Type
  measure :: a -> Measure a

data SplayTree a where
  Tip :: SplayTree a
  Branch :: Measure a -> !(SplayTree a) -> !a -> !(SplayTree a) -> SplayTree a
  deriving (Typeable)

instance (NFData a, NFData (Measure a)) => NFData (SplayTree a) where
  rnf Tip = ()
  rnf (Branch m l a r) = m `deepseq` l `deepseq` a `deepseq` rnf r

instance (Eq a) => Eq (SplayTree a) where
  xs == ys = toList xs == toList ys

instance (Ord a) => Ord (SplayTree a) where
  compare xs ys = compare (toList xs) (toList ys)

instance (Show a, Show (Measure a)) => Show (SplayTree a) where
  show Tip = "Tip"
  show (Branch v l a r) = "Branch {ann {" ++ show v ++ "}, lChild {" ++ show l ++ "}, value {" ++ show a ++ "}, rChild {" ++ show r ++ "}}"

instance (Measured a) => Semigroup (SplayTree a) where (<>) = (><)

instance (Measured a) => Monoid (SplayTree a) where
  mempty = Tip

instance (Measured a) => Measured (SplayTree a) where
  type Measure (SplayTree a) = Measure a
  measure Tip = mempty
  measure (Branch v _ _ _) = v

leaf :: (Measured a) => a -> SplayTree a
leaf a = Branch (measure a) Tip a Tip

branch :: (Measured a) => SplayTree a -> a -> SplayTree a -> SplayTree a
branch l a r = Branch mm l a r
  where
    mm = case (l, r) of
      (Tip, Tip) -> measure a
      (Tip, Branch rm _ _ _) -> measure a `mappend` rm
      (Branch lm _ _ _, Tip) -> lm `mappend` measure a
      (Branch lm _ _ _, Branch rm _ _ _) -> mconcat [lm, measure a, rm]

instance Foldable SplayTree where
  foldMap _ Tip = mempty
  foldMap f (Branch _ l a r) = mconcat [foldMap f l, f a, foldMap f r]
  {-# INLINE foldMap #-}
  foldl = myFoldl
  {-# INLINE foldl #-}

myFoldl :: (a -> b -> a) -> a -> SplayTree b -> a
myFoldl f = go
  where
    go !i Tip = i
    go !acc (Branch _ l a r) =
      let a1 = go acc l
          a2 = a1 `seq` f a1 a
       in a2 `seq` go a2 r
{-# INLINE myFoldl #-}

-- -------------------------------------------
-- Construction

empty :: SplayTree a
empty = Tip

singleton :: (Measured a) => a -> SplayTree a
singleton = leaf

-- the implementations for (<|) and (|>) are not quite correct.  Really
-- we should insert the new element properly and splay it up to the top,
-- as this can change the rest of the tree.  But it's much faster to just
-- add the new element at the root, and since we know half the tree will
-- be empty anyway the result is pretty similar.
(<|) :: (Measured a) => a -> SplayTree a -> SplayTree a
a <| t = branch Tip a t

{-
a <| Tip          = branch Tip a Tip
a <| t@(Branch{}) = desc $ descendL t []
 where
  desc (MZ Tip zp)           = ascendSplay (leaf a) zp
  desc (MZ b@(Branch {}) zp) = desc $ descendL b zp
  desc NoMZ                  = error "SplayTree.(<|): internal error"
-}

(|>) :: (Measured a) => SplayTree a -> a -> SplayTree a
t |> b = branch t b Tip

{-
Tip          |> b = leaf b
t@(Branch{}) |> b = desc $ descendR t []
 where
  desc (MZ Tip zp)           = ascendSplay (leaf b) zp
  desc (MZ b@(Branch {}) zp) = desc $ descendR b zp
  desc NoMZ                  = error "SplayTree.(|>): internal error"
-}

-- | Append two trees.
(><) :: (Measured a) => SplayTree a -> SplayTree a -> SplayTree a
(><) = go
  where
    go Tip ys = ys
    go xs Tip = xs
    go xs (Branch _ l y r) = branch (go xs l) y r

{-
l   >< r = desc $ descendL r []
 where
  desc (MZ Tip zp)          = ascendSplay l zp
  desc (MZ b@(Branch{}) zp) = desc $ descendL b zp
  desc NoMZ                 = error "SplayTree.(><): internal error"
-}

-- | /O(n)/.  Create a Tree from a finite list of elements.
fromList :: (Measured a) => [a] -> SplayTree a
fromList = foldl' (|>) Tip

-- | /O(n)/.  Create a Tree from a finite list of elements.
--
-- After the tree is created, it is balanced.  This is useful with sorted data,
-- which would otherwise create a completely unbalanced tree.
fromListBalance :: (Measured a) => [a] -> SplayTree a
fromListBalance = balance . fromList

-- -------------------------------------------
-- deconstruction

-- | Is the tree empty?
null :: SplayTree a -> Bool
null Tip = True
null _ = False

-- | Split a tree at the point where the predicate on the measure changes from
-- False to True.
split ::
  (Measured a) =>
  (Measure a -> Bool) ->
  SplayTree a ->
  (SplayTree a, SplayTree a)
split _p Tip = (Tip, Tip)
split p tree = case query p tree of
  Just (_, Branch _ l a r) -> (l, branch Tip a r)
  _ -> (Tip, Tip)

-- | find the first point where the predicate returns True.  Returns a tree
-- splayed with that node at the top.
query ::
  (Measured a, Measure a ~ Measure (SplayTree a)) =>
  (Measure a -> Bool) ->
  SplayTree a ->
  Maybe (a, SplayTree a)
query _p Tip = Nothing
query p t
  | p (measure t) = Just . asc $ desc mempty t []
  | otherwise = Nothing
  where
    asc (a, t', zp) = (a, ascendSplay t' zp)
    desc _i b@(Branch _ Tip a Tip) zp = (a, b, zp)
    desc i b@(Branch _ Tip a _r) zp
      | p mm = (a, b, zp)
      | otherwise = let MZ b' zp' = descendR b zp in desc mm b' zp'
      where
        mm = i `mappend` measure a
    desc i b@(Branch _ l a _r) zp
      | p ml = let MZ b' zp' = descendL b zp in desc i b' zp'
      | p mm = (a, b, zp)
      | otherwise = let MZ b' zp' = descendR b zp in desc mm b' zp'
      where
        ml = i `mappend` measure l
        mm = ml `mappend` measure a
    desc _ _ _ = error "desc: should not happen"
{-# INLINE query #-}

-- --------------------------
-- Basic interface

size :: SplayTree a -> Int
size = foldl' (\acc _ -> acc + 1) 0

memberSplay ::
  (Measured a, Ord (Measure a), Eq a) =>
  a ->
  SplayTree a ->
  (Bool, SplayTree a)
memberSplay a tree = case snd <$> query (>= measure a) tree of
  Nothing -> (False, tree)
  Just foc@(Branch _ _l a' _r) -> (a == a', foc)
  Just Tip -> error "memberSplay: should not happen"
{-# INLINE memberSplay #-}

-- | Return the root element, if the tree is not empty.
--
-- This, combined with @memberSplay@, can be used to create many lookup
-- functions
rootElem :: SplayTree a -> Maybe a
rootElem (Branch _ _l a _r) = Just a
rootElem _ = Nothing
{-# INLINE rootElem #-}

delete ::
  (Measured a, Ord (Measure a), Eq a) =>
  a ->
  SplayTree a ->
  SplayTree a
delete a tree = case memberSplay a tree of
  (False, t') -> t'
  (True, Branch _ l _ r) -> l >< r

insert ::
  (Measured a, Ord (Measure a), Eq a) =>
  a ->
  SplayTree a ->
  SplayTree a
insert a tree = case snd <$> query (>= measure a) tree of
  Nothing -> tree |> a
  Just t'@(Branch _ l a' r) ->
    if a == a'
      then t'
      else l >< (a <| a' <| r)

-- --------------------------
-- Set operations

difference ::
  (Measured a, Ord (Measure a), Eq a) =>
  SplayTree a ->
  SplayTree a ->
  SplayTree a
difference = foldl' (flip delete)

intersection ::
  (Measured a, Ord (Measure a), Eq a) =>
  SplayTree a ->
  SplayTree a ->
  SplayTree a
intersection l r = fst $ foldl' f (empty, l) r
  where
    f (acc, testSet) x = case memberSplay x testSet of
      (True, t') -> (insert x acc, t')
      (False, t') -> (acc, t')

-- --------------------------
-- Traversals

-- | Like fmap, but with a more restrictive type.
fmap' :: (Measured b) => (a -> b) -> SplayTree a -> SplayTree b
fmap' f Tip = Tip
fmap' f (Branch _ l a r) = branch (fmap' f l) (f a) (fmap' f r)

-- | Like traverse, but with a more restrictive type.
traverse' ::
  (Measured b, Applicative f) =>
  (a -> f b) ->
  SplayTree a ->
  f (SplayTree b)
traverse' f Tip = pure Tip
traverse' f (Branch _ l a r) =
  branch <$> traverse' f l <*> f a <*> traverse' f r

-- | descend to the deepest left-hand branch
deepL :: (Measured a) => SplayTree a -> SplayTree a
deepL = deep descendL

-- | descend to the deepest right-hand branch
deepR :: (Measured a) => SplayTree a -> SplayTree a
deepR = deep descendR

-- | Descend a tree using the provided `descender` descending function,
-- then recreate the tree.  The new focus will be the last node accessed
-- in the tree.
deep ::
  (Measured a) =>
  (SplayTree a -> [Thread a] -> MZ a) ->
  SplayTree a ->
  SplayTree a
deep descender tree = desc $ descender tree []
  where
    desc (MZ Tip zp) = ascendSplay Tip zp
    desc (MZ b@(Branch {}) zp) = desc $ descender b zp
    desc NoMZ = ascendSplay tree []
{-# INLINE deep #-}

-- -------------------------------------------
-- splay tree stuff...

-- use a zipper so descents/splaying can be done in a single pass
data Thread a
  = DescL a (SplayTree a)
  | DescR a (SplayTree a)

data MZ a
  = NoMZ
  | MZ (SplayTree a) [Thread a]

descendL :: SplayTree a -> [Thread a] -> MZ a
descendL (Branch _ l a r) zp = MZ l $ DescL a r : zp
descendL _ _ = NoMZ

descendR :: SplayTree a -> [Thread a] -> MZ a
descendR (Branch _ l a r) zp = MZ r $ DescR a l : zp
descendR _ _ = NoMZ

up :: (Measured a) => SplayTree a -> Thread a -> SplayTree a
up tree (DescL a r) = branch tree a r
up tree (DescR a l) = branch l a tree

rotateL :: (Measured a) => SplayTree a -> SplayTree a
rotateL (Branch annP (Branch annX lX aX rX) aP rP) =
  branch lX aX (branch rX aP rP)
rotateL tree = tree

-- actually a left rotation, but calling it a right rotation matches with
-- the descent terminology
rotateR :: (Measured a) => SplayTree a -> SplayTree a
rotateR (Branch annP lP aP (Branch annX lX aX rX)) =
  branch (branch lP aP lX) aX rX
rotateR tree = tree

ascendSplay :: (Measured a) => SplayTree a -> [Thread a] -> SplayTree a
ascendSplay = go
  where
    go !x [] = x
    go !x zp = uncurry go $ ascendSplay' x zp

    -- ascendSplay' :: Measured a => SplayTree a -> [Thread a] -> (SplayTree a, [Thread a])
    ascendSplay' x (pt@(DescL {}) : gt@(DescL {}) : zp') =
      let g = up (up x pt) gt in (rotateL (rotateL g), zp')
    ascendSplay' x (pt@(DescR {}) : gt@(DescR {}) : zp') =
      let g = up (up x pt) gt in (rotateR (rotateR g), zp')
    ascendSplay' x (pt@(DescR {}) : gt@(DescL {}) : zp') =
      (rotateL $ up (rotateR (up x pt)) gt, zp')
    ascendSplay' x (pt@(DescL {}) : gt@(DescR {}) : zp') =
      (rotateR $ up (rotateL (up x pt)) gt, zp')
    ascendSplay' x [pt@(DescL {})] = (rotateL (up x pt), [])
    ascendSplay' x [pt@(DescR {})] = (rotateR (up x pt), [])
    ascendSplay' _ [] = error "SplayTree: internal error, ascendSplay' called past root"

-- ---------------------------
-- A measure of tree depth
newtype ElemD a = ElemD {getElemD :: a} deriving (Show, Ord, Eq, Num, Enum)

newtype Depth = Depth {getDepth :: Int}
  deriving (Show, Ord, Eq, Num, Enum, Real, Integral)

instance Semigroup Depth where
  (Depth l) <> (Depth r) = Depth (max l r)

instance Monoid Depth where
  mempty = 0

instance Measured (ElemD a) where
  type Measure (ElemD a) = Depth
  measure _ = 1

-- | rebalance a splay tree.  The order of elements does not change.
balance :: (Measured a) => SplayTree a -> SplayTree a
balance = fmap' getElemD . balance' . fmap' ElemD

balance' :: SplayTree (ElemD a) -> SplayTree (ElemD a)
balance' Tip = Tip
balance' (Branch _ l a r) =
  let l' = balance' l
      r' = balance' r
      diff = measure l' - measure r'
      numRots = fromIntegral $ diff `div` 2
      b' = Branch (mconcat [1 + measure l', measure a, 1 + measure r']) l' a r'
   in case (numRots > 0, numRots < 0) of
        (True, _) -> iterate rotateL b' !! numRots
        (_, True) -> iterate rotateR b' !! abs numRots
        _ -> b'
