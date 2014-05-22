{-# LANGUAGE FlexibleInstances #-}
module Cauterize.Schema.Arbitrary
 ( genTypeRuns
 , arbSchema
 , ValidSchema(unValidSchema)
 ) where

import Test.QuickCheck.Arbitrary
import Test.QuickCheck.Gen
import Control.Monad
import Data.Word

import Cauterize.Common.IndexedRef
import Cauterize.Common.Primitives
import Cauterize.Common.Types
import Cauterize.Schema.Types

newtype ValidSchema = ValidSchema { unValidSchema :: Schema Name }
  deriving (Show)

instance Arbitrary ValidSchema where
  arbitrary = liftM ValidSchema arbSchema

maxFields, maxRunTypes, maxRuns :: (Num a) => a
maxRuns = 100
maxRunTypes = 3
maxFields = 5

constRange :: (Num a, Enum a) => [a]
constRange = [1..10]

arbSchema :: Gen (Schema Name)
arbSchema = liftM3 Schema (elements schemaNames) (elements schemaNames) rs
  where
    rs = genTypeRuns maxRuns

genTypeRuns :: Word -> Gen [ScType Name]
genTypeRuns runs = liftM (biTys ++) $ go runs genNames (map show bis)
  where
    go 0 _ _ = return []
    go runs' ns ex = do
      tyCount <- elements [1..maxRunTypes]
      let (nowNames,laterNames) = splitAt tyCount ns
      ts <- genTypes nowNames ex
      rs <- go (runs' - 1) laterNames (ex ++ nowNames)
      return $ ts ++ rs

genTypes :: [Name] -> [Name] -> Gen [ScType Name]
genTypes [] _ = return []
genTypes (thisName:restNames) ex = do
  let arbs' = sequence (sequence arbs ex) thisName
  t <- oneof arbs'
  r <- genTypes restNames ex
  return $ t:r

arbs :: [[Name] -> Name -> Gen (ScType Name)]
arbs = [ arbScalar
       , arbConst
       , arbFixed
       , arbBounded
       , arbStruct
       , arbSet
       , arbEnum
       , arbPartial
       , arbPad
       ]

arbArraySize :: Gen Integer
arbArraySize = liftM fromIntegral (arbitrary :: Gen Word32)

arbScalar :: [Name] -> Name -> Gen (ScType Name)
arbScalar _ n = liftM (Scalar . TScalar n) arbBi

arbConst :: [Name] -> Name -> Gen (ScType Name)
arbConst _ n = liftM2 (\b i -> Const $ TConst n b i) arbBi (elements constRange)

arbFixed :: [Name] -> Name -> Gen (ScType Name)
arbFixed ts n = liftM2 (\t s -> FixedArray $ TFixedArray n t s) (elements ts) arbArraySize

arbBounded :: [Name] -> Name -> Gen (ScType Name)
arbBounded ts n = liftM2 (\t s -> BoundedArray $ TBoundedArray n t s) (elements ts) arbArraySize

arbStruct :: [Name] -> Name -> Gen (ScType Name)
arbStruct ts n = arbFielded ts n (\n' fs -> Struct $ TStruct n' fs)

arbSet ::  [Name] -> Name -> Gen (ScType Name)
arbSet ts n = arbFielded ts n (\n' fs -> Set $ TSet n' fs)

arbEnum ::  [Name] -> Name -> Gen (ScType Name)
arbEnum ts n = arbFielded ts n (\n' fs -> Enum $ TEnum n' fs)

arbPartial ::  [Name] -> Name -> Gen (ScType Name)
arbPartial ts n = arbFielded ts n (\n' fs -> Partial $ TPartial n' fs)

arbPad :: [Name] -> Name -> Gen (ScType Name)
arbPad _ n = liftM (Pad . TPad n) (elements [1..8])

arbFielded :: [Name] -> Name -> (Name -> [IndexedRef Name] -> a) -> Gen a
arbFielded ts n cstr = do
  fieldCount <- elements [1..maxFields] :: Gen Integer
  let fieldNames = take (fromIntegral fieldCount) genNames
  let arbIRef' = arbIRef ts
  fieldFs <- mapM arbIRef' fieldNames
  let fieldFs' = zipWith ($) fieldFs [0..(fieldCount - 1)]

  return $ cstr n fieldFs'

arbIRef :: [Name] -> Name -> Gen (Integer -> IndexedRef Name)
arbIRef ts n = liftM (IndexedRef n) $ elements ts

sequences :: [a] -> [[a]]
sequences ls = ls' ++ [i ++ [a] | i <- sequences ls, a <- ls]
  where
    ls' = map (:[]) ls

schemaNames :: [Name]
schemaNames = take 100 genNames

genNames :: [Name]
genNames = let syms = ["a","e","i","o","u","y"]
           in map concat $ sequences syms

bis :: [BuiltIn]
bis = [minBound..maxBound]

biTys :: [ScType Name]
biTys = map (BuiltIn . TBuiltIn) bis

arbBi :: Gen BuiltIn
arbBi = elements bis
