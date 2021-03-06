{-# LANGUAGE DataKinds #-}

module HLearn.DataStructures.SpaceTree.Algorithms.NearestNeighbor
    ( 

    -- * data types
    Neighbor (..)
    
    , KNN (..)
    , mkKNN

    , KNN2 (..)

    -- * functions
    , knn
    , knn_cata

    , knn_noprune
    , knn_cata_noprune

    , getknnL

    , knn2_single
    , knn2_single_parallel

    -- * tmp
    , knn_maxdist
    )
    where

import Debug.Trace

import Control.Monad
import Control.Monad.Primitive
import Control.Monad.ST
import Control.DeepSeq
import Data.Int
import Data.List
import Data.Maybe 
import qualified Data.Strict.Maybe as Strict
import qualified Data.Strict.Tuple as Strict
import Data.Monoid
import qualified Data.Foldable as F
import qualified Data.Map.Strict as Map
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as VU
import qualified Data.Vector.Generic as VG
import qualified Data.Vector.Mutable as VM
import qualified Data.Vector.Unboxed.Mutable as VUM
import qualified Data.Vector.Generic.Mutable as VGM

import Data.Function.Memoize

import HLearn.Algebra
import HLearn.DataStructures.SpaceTree
import qualified HLearn.DataStructures.StrictList as Strict
import HLearn.DataStructures.StrictList (List (..),strictlist2list)

-------------------------------------------------------------------------------
-- data types 

data Neighbor dp = Neighbor
    { neighbor         :: !dp
    , weight           :: !(Ring dp)
    , neighborDistance :: !(Ring dp)
    }

deriving instance (Read dp, Read (Ring dp)) => Read (Neighbor dp)
deriving instance (Show dp, Show (Ring dp)) => Show (Neighbor dp)

instance Eq (Ring dp) => Eq (Neighbor dp) where
    a == b = neighborDistance a == neighborDistance b

instance Ord (Ring dp) => Ord (Neighbor dp) where
    compare a b = compare (neighborDistance a) (neighborDistance b)

instance (NFData dp, NFData (Ring dp)) => NFData (Neighbor dp) where
    rnf n = deepseq (neighbor n) $ rnf (neighborDistance n)

---------------------------------------

-- newtype KNN (k::Nat) dp = KNN { getknn :: [Neighbor dp] }
newtype KNN (k::Nat) dp = KNN { getknn :: Strict.List (Neighbor dp) }

mkKNN :: Num (Ring dp) => dp -> Ring dp -> KNN k dp
mkKNN dp dist = KNN $ Neighbor dp 1 dist :. Strict.Nil

getknnL :: KNN k dp -> [Neighbor dp]
getknnL = strictlist2list . getknn

deriving instance (Read dp, Read (Ring dp)) => Read (KNN k dp)
deriving instance (Show dp, Show (Ring dp)) => Show (KNN k dp)
deriving instance (NFData dp, NFData (Ring dp)) => NFData (KNN k dp)

-- knn_maxdist :: forall k dp. (SingI k, Fractional (Ring dp)) => KNN k dp -> Ring dp
-- knn_maxdist (KNN [ ]) = infinity
-- knn_maxdist (KNN [x]) = neighborDistance x
-- knn_maxdist (KNN xs ) = neighborDistance $ last xs
knn_maxdist :: forall k dp. (SingI k, Fractional (Ring dp)) => KNN k dp -> Ring dp
knn_maxdist (KNN Strict.Nil) = infinity
knn_maxdist (KNN (x:.Strict.Nil)) = neighborDistance x
knn_maxdist (KNN xs ) = neighborDistance $ Strict.last xs

---------------------------------------

newtype KNN2 (k::Nat) dp = KNN2 
    { getknn2 :: Map.Map dp (KNN k dp)
    }

deriving instance (Read dp, Read (Ring dp), Ord dp, Read (KNN k dp)) => Read (KNN2 k dp)
deriving instance (Show dp, Show (Ring dp), Ord dp, Show (KNN k dp)) => Show (KNN2 k dp)
deriving instance (NFData dp, NFData (Ring dp)) => NFData (KNN2 k dp)

-------------------------------------------------------------------------------
-- algebra

instance (SingI k, MetricSpace dp, Eq dp) => Monoid (KNN k dp) where
    {-# INLINE mempty #-}
    {-# INLINE mappend #-}

    mempty = KNN Strict.Nil 
    mappend (KNN Strict.Nil     ) (KNN Strict.Nil     ) = {-# SCC mappend_KNN #-} KNN Strict.Nil
    mappend (KNN (x:.Strict.Nil)) (KNN Strict.Nil     ) = {-# SCC mappend_KNN #-} KNN $ x:.Strict.Nil
    mappend (KNN Strict.Nil     ) (KNN (y:.Strict.Nil)) = {-# SCC mappend_KNN #-} KNN $ y:.Strict.Nil
    mappend (KNN (x:.xs)  ) (KNN (y:.ys)  ) = {-# SCC mappend_KNN #-} case k of
        1 -> if x < y then KNN (x:.Strict.Nil) else KNN (y:.Strict.Nil)
        otherwise -> KNN $ Strict.take k $ interleave (x:.xs) (y:.ys)
        where
            k=fromIntegral $ fromSing (sing :: Sing k)

            interleave !xs Strict.Nil = xs
            interleave Strict.Nil !ys = ys
            interleave (x:.xs) (y:.ys) = case compare x y of
                LT -> x:.(interleave xs (y:.ys))
                GT -> y:.(interleave (x:.xs) ys)
                EQ -> if neighbor x == neighbor y
                    then x:.interleave xs ys
                    else x:.(y:.(interleave xs ys))


--     mempty = KNN mempty 
--     mappend (KNN [ ]) (KNN [ ]) = {-# SCC mappend_KNN #-} KNN [ ]
--     mappend (KNN [x]) (KNN [ ]) = {-# SCC mappend_KNN #-} KNN [x]
--     mappend (KNN [ ]) (KNN [y]) = {-# SCC mappend_KNN #-} KNN [y]
--     mappend (KNN (x:xs)) (KNN (y:ys)) = {-# SCC mappend_KNN #-} case k of
--         1 -> if x < y then KNN [x] else KNN [y]
--         otherwise -> KNN $ take k $ interleave (x:xs) (y:ys)
-- 
--         where
--             k=fromIntegral $ fromSing (sing :: Sing k)
-- 
--             interleave :: (Eq a, Ord (Ring a)) => [Neighbor a] -> [Neighbor a] -> [Neighbor a]
--             interleave !xs [] = xs
--             interleave [] !ys = ys
--             interleave (x:xs) (y:ys) = case compare x y of
--                 LT -> x:(interleave xs (y:ys))
--                 GT -> y:(interleave (x:xs) ys)
--                 EQ -> if neighbor x == neighbor y
--                     then x:interleave xs ys
--                     else x:y:interleave xs ys

instance (SingI k, MetricSpace dp, Ord dp) => Monoid (KNN2 k dp) where
    {-# INLINE mempty #-}
    {-# INLINE mappend #-}

    mempty = KNN2 mempty
    mappend (KNN2 x) (KNN2 y) = {-# SCC mappend_KNN2 #-} KNN2 $ Map.unionWith (<>) x y

-------------------------------------------------------------------------------
-- dual tree

-------------------------------------------------------------------------------
-- single tree

{-# INLINABLE knn #-}
knn :: (SingI k, SpaceTree t dp, Eq dp) => dp -> t dp -> KNN k dp
knn query t = prunefoldA (knn_cata query) mempty t

{-# INLINABLE knn_cata #-}
knn_cata :: forall k t dp. 
    ( SingI k
    , SpaceTree t dp
    , Eq dp
    ) => dp -> t dp -> KNN k dp -> Strict.Maybe (KNN k dp)

knn_cata !query !t !res@(KNN Strict.Nil) = if stNode t == query
    then Strict.Just res
    else Strict.Just $ KNN $ (Neighbor (stNode t) (stWeight t) (distance (stNode t) query)):.Strict.Nil

-- knn_cata !query !t !res@(KNN (x:.Strict.Nil)) =  
knn_cata !query !t !res@(KNN (x:.xs)) =  
    case stIsMinDistanceDpFartherThanWithDistance t query (knn_maxdist res) of
        Strict.Nothing -> Strict.Nothing
        Strict.Just dist -> if stWeight t==0 || stNode t==query -- || neighborDistance x<=dist
            then Strict.Just res
--             else Strict.Just $ KNN $ (Neighbor (stNode t) (stWeight t) dist):.Strict.Nil
            else Strict.Just $ res <> (KNN $ (Neighbor (stNode t) (stWeight t) dist):.Strict.Nil)

---------------------------------------

knn_noprune :: (SingI k, SpaceTree t dp, Eq dp) => dp -> t dp -> KNN k dp
knn_noprune query t = prunefoldA (knn_cata query) mempty t

knn_cata_noprune :: forall k t dp. 
    ( SingI k
    , SpaceTree t dp
    , Eq dp
    ) => dp -> t dp -> KNN k dp -> Strict.Maybe (KNN k dp)
knn_cata_noprune !query !t !res@(KNN (x:.xs)) =  
    Strict.Just $ res <> (KNN $ (Neighbor (stNode t) (stWeight t) (distance (stNode t) query)):.Strict.Nil)

---------------------------------------

{-# INLINABLE knn2_single #-}
knn2_single :: (SingI k, SpaceTree t dp, Eq dp, F.Foldable t, Ord dp) => DualTree (t dp) -> KNN2 k dp
knn2_single dual = F.foldMap (\dp -> KNN2 $ Map.singleton dp $ knn dp $ reference dual) (query dual)

{-# INLINABLE knn2_single_parallel #-}
knn2_single_parallel :: 
    ( SingI k
    , SpaceTree t dp
    , Ord dp
    , NFData (Ring dp)
    , NFData dp
    ) => DualTree (t dp) -> KNN2 k dp
knn2_single_parallel dual = {-# SCC knn2_single_parallel #-} (parallel reduce) $ map (\dp -> KNN2 $ Map.singleton dp $ knn dp $ reference dual) (stToList $ query dual)

