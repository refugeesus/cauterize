module Cauterize.Schema.Types
  ( Schema(..)
  , Type(..)
  , TypeDesc(..)
  , Field(..)
  , Offset
  , Length
  , IsSchema(..)
  ) where

import Cauterize.CommonTypes
import Data.Text (Text)

data Schema = Schema
  { schemaName :: Text
  , schemaVersion :: Text
  , schemaTypes :: [Type]
  } deriving (Show, Eq)

data Type = Type
  { typeName :: Identifier
  , typeDesc :: TypeDesc
  } deriving (Show, Eq)

data TypeDesc
  = Synonym { synonymRef :: Identifier }
  | Range { rangeOffset :: Offset, rangeLength :: Length }
  | Array { arrayRef :: Identifier, arrayLength :: Length }
  | Vector { vectorRef :: Identifier, vectorLength :: Length }
  | Enumeration { enumerationValues :: [Identifier] }
  | Record { recordFields :: [Field] }
  | Combination { combinationFields :: [Field] }
  | Union { unionFields :: [Field] }
  deriving (Show, Eq)

data Field
  = DataField { fieldName :: Identifier, fieldRef :: Identifier }
  | EmptyField { fieldName :: Identifier }
  deriving (Show, Eq)

class IsSchema a where
  getSchema :: a -> Schema

instance IsSchema Schema where
  getSchema = id
