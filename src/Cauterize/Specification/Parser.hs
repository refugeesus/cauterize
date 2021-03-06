{-# LANGUAGE OverloadedStrings, PatternSynonyms  #-}
module Cauterize.Specification.Parser
  ( parseSpecification
  , parseSpecificationFromFile
  , formatSpecification
  ) where

import Control.Monad
import Data.SCargot
import Data.SCargot.Repr.WellFormed
import Data.Text (Text, pack, unpack)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Map as M
import Text.Parsec
import Text.Parsec.Text

import Cauterize.Specification.Types
import Cauterize.CommonTypes
import qualified Cauterize.Hash as H

defaultSpecification :: Specification
defaultSpecification = Specification
  { specName = "specification"
  , specVersion = "0.0.0.0"
  , specFingerprint = H.hashNull
  , specSize = mkConstSize 1
  , specDepth = 0
  , specTypeLength = 0
  , specLengthTag = T1
  , specTypes = []
  }

data Atom
  = Number Integer
  | Ident Text
  | Str Text
  | Hash H.Hash
  | Tag Tag
  deriving (Show)

data Component
  = Name Text
  | Version Text
  | Fingerprint H.Hash
  | SpecSize Size
  | Depth Integer
  | TypeLength Integer
  | LengthTag Tag
  | TypeDef Type
  deriving (Show)

pIdentLeading :: Parser Char
pIdentLeading = oneOf ['a'..'z']

pIdentTrailing :: Parser Char
pIdentTrailing = oneOf ['a'..'z'] <|> digit <|> char '_'

pAtom :: Parser Atom
pAtom = try pString <|> try pTag <|> try pHash <|> pNumber <|> pIdent
  where
    pString = do
      _ <- char '"'
      s <- many $ noneOf "\""
      _ <- char '"'
      (return . Str . pack) s
    pTag = do
      _ <- char 't'
      d <- oneOf "1248"
      return $ case d of
                '1' -> Tag T1
                '2' -> Tag T2
                '4' -> Tag T4
                '8' -> Tag T8
                _ -> error "pAtom: should never happen."
    pNumber = do
      sign <- option '+' (oneOf "-+")
      v <- fmap (read :: String -> Integer) (many1 digit)
      let v' = if sign == '-'
                then (-1) * v
                else v
      return (Number v')
    pIdent = do
      f <- pIdentLeading
      r <- many pIdentTrailing
      (return . Ident . pack) (f:r)
    pHash = let bytes = count 20 pHexByte
                htxt = liftM (pack . concat) bytes
            in liftM (Hash . H.mkHashFromHexString) htxt

    pHexByte = let pNibble = oneOf "abcdef0123456789"
               in count 2 pNibble

sAtom :: Atom -> Text
sAtom (Number n) = pack (show n)
sAtom (Ident i) = i
sAtom (Str s) = T.concat ["\"", s, "\""]
sAtom (Hash h) = H.hashToHex h
sAtom (Tag t) = unIdentifier $ tagToText t

pattern AI :: Text -> WellFormedSExpr Atom
pattern AI x = A (Ident x)
pattern AN :: Integer -> WellFormedSExpr Atom
pattern AN x = A (Number x)
pattern AS :: Text -> WellFormedSExpr Atom
pattern AS x = A (Str x)
pattern AH :: H.Hash -> WellFormedSExpr Atom
pattern AH x = A (Hash x)
pattern AT :: Tag -> WellFormedSExpr Atom
pattern AT x = A (Tag x)

toComponent :: WellFormedSExpr Atom -> Either String Component
toComponent = asList go
  where
    go [A (Ident "name"), AS name] = Right (Name name)
    go [A (Ident "version"), AS version] = Right (Version version)
    go [A (Ident "fingerprint"), AH h] = Right (Fingerprint h)
    go [A (Ident "size"), AN smin, AN smax] = Right (SpecSize $ mkSize smin smax)
    go [A (Ident "depth"), AN d] = Right (Depth d)
    go [A (Ident "typelength"), AN d] = Right (TypeLength d)
    go [A (Ident "lengthtag"), AT t] = Right (LengthTag t)

    go (A (Ident "type") : rs ) = toType rs

    go (A (Ident x) : _ ) = Left ("Unhandled component: " ++ show x)
    go y = Left ("Invalid component: " ++ show y)

toType :: [WellFormedSExpr Atom] -> Either String Component
toType [] = Left "Empty type expression."
toType [_] = Left "Type expression without prototype."
toType (AI name:AI tproto:tbody) =
  case tproto of
    "synonym" -> toSynonym tbody
    "range" -> toRange tbody
    "array" -> toArray tbody
    "vector" -> toVector tbody
    "enumeration" -> toEnumeration tbody
    "record" -> toRecord tbody
    "combination" -> toCombination tbody
    "union" -> toUnion tbody
    y -> Left ("Invalid type expression: " ++ show y)
  where
    umi = unsafeMkIdentifier . unpack

    mkTD :: Text
         -> WellFormedSExpr Atom -- Hash atom
         -> WellFormedSExpr Atom -- Size atom
         -> WellFormedSExpr Atom -- Depth atom
         -> TypeDesc
         -> Either String Component
    mkTD n f s d t = do
      f' <- toHash f
      s' <- toSize s
      d' <- toDepth d
      return (TypeDef $ Type (umi n) f' s' d' t)

    ueb p b = Left ("Unexpected " ++ p ++ " body: " ++ show b)

    toDepth (L [ AI "depth", AN d ]) = Right d
    toDepth x = ueb "depth" x

    toSize (L [ AI "size", AN smin, AN smax ]) = Right $ mkSize smin smax
    toSize x = ueb "size" x

    toHash (L [ AI "fingerprint", AH h]) = Right h
    toHash x = ueb "fingerprint" x

    toField (L [AI "field", AI fname, AN ix, AI ref]) = Right $ DataField (umi fname) ix (umi ref)
    toField (L [AI "empty", AI fname, AN ix]) = Right $ EmptyField (umi fname) ix
    toField x = ueb "field" x

    toSynonym [f, s, d, AI ref] =
      mkTD name f s d (Synonym $ umi ref)
    toSynonym x = ueb "synonym" x

    toRange [f, s, d, AN rmin, AN rmax, AT t, AI p] =
      case umi p `M.lookup` primMap of
        Nothing -> Left ("toRange: Not a primitive: '" ++ pstr ++ "'.")
        Just p' | p' `elem` badPrims -> Left ("toRange: Not a suitable primitve: '" ++ pstr ++ "'.")
                | otherwise -> mkTD name f s d (Range o l t p')
      where
        pstr = T.unpack p
        badPrims = [PBool, PF32, PF64]
        o = fromIntegral rmin
        l = fromIntegral rmax - fromIntegral rmin
    toRange x = ueb "range" x

    toArray [f, s, d, AI ref, AN l] =
      mkTD name f s d (Array (umi ref) (fromIntegral l))
    toArray x = ueb "array" x

    toVector [f, s, d, AI ref, AN l, AT t] =
      mkTD name f s d (Vector (umi ref) (fromIntegral l) t)
    toVector x = ueb "vector" x

    toEnumeration [f, s, d, AT t, L (AI "values":vs)] = do
        vs' <- mapM toValue vs
        mkTD name f s d (Enumeration vs' t)
      where
        toValue (L [AI "value", AI n, AN ix]) = Right $ EnumVal (umi n) ix
        toValue x = ueb "value" x
    toEnumeration x = ueb "enumeration" x

    toRecord [f, s, d, L (AI "fields":fs)] = do
        fs' <- mapM toField fs
        mkTD name f s d (Record fs')
    toRecord x = ueb "record" x

    toCombination [f, s, d, AT t, L (AI "fields":fs)] = do
        fs' <- mapM toField fs
        mkTD name f s d (Combination fs' t)
    toCombination x = ueb "combination" x

    toUnion [f, s, d, AT t, L (AI "fields":fs)] = do
        fs' <- mapM toField fs
        mkTD name f s d (Union fs' t)
    toUnion x = ueb "union" x
toType _ = Left "Unexpected atom types."

fromComponent :: Component -> WellFormedSExpr Atom
fromComponent c =
  case c of
    (Name n) -> L [ ident "name", A . Str $ n ]
    (Version v) -> L [ ident "version", A . Str $ v ]
    (Fingerprint h) -> L [ ident "fingerprint", hash h ]
    (SpecSize s) -> L [ ident "size", number (sizeMin s), number (sizeMax s) ]
    (Depth d) -> L [ ident "depth", number d ]
    (TypeLength l) -> L [ ident "typelength", number l ]
    (LengthTag t) -> L [ ident "lengthtag", tag t ]

    (TypeDef t) -> fromType t

  where
    ident = A . Ident
    hash = A . Hash
    number = A . Number
    tag = A . Tag

fromType :: Type -> WellFormedSExpr Atom
fromType (Type n f s depth desc) = L (A (Ident "type") : rest)
  where
    na = A (Ident (unIdentifier n))
    fl = L [ ai "fingerprint", ah f ]
    sl = L [ ai "size", an (sizeMin s), an (sizeMax s) ]
    dp = L [ ai "depth", an depth ]

    aiu = A . Ident . unIdentifier
    ai = A . Ident
    an = A . Number
    ah = A . Hash
    at = A . Tag

    fromField (DataField fn ix fr) = L [ai "field", aiu fn, an ix, aiu fr]
    fromField (EmptyField fn ix) = L [ai "empty", aiu fn, an ix]

    fromEnumVal (EnumVal v i) = L [ ai "value", aiu v, an i ]

    rest =
      case desc of
        Synonym r -> [na, ai "synonym", fl, sl, dp, aiu r]
        Range o l t p ->
          let rmin = fromIntegral o
              rmax = (fromIntegral o + fromIntegral l)
          in [na, ai "range", fl, sl, dp, an rmin, an rmax, at t, ai (unIdentifier . primToText $ p)]
        Array r l -> [na, ai "array", fl, sl, dp, aiu r, an (fromIntegral l)]
        Vector r l t -> [na, ai "vector", fl, sl, dp, aiu r, an (fromIntegral l), at t]
        Enumeration vs t ->
          [na, ai "enumeration", fl, sl, dp, at t, L (ai "values" : map fromEnumVal vs)]
        Record fs ->
          [na, ai "record", fl, sl, dp, L (ai "fields" : map fromField fs)]
        Combination fs t ->
          [na, ai "combination", fl, sl, dp, at t, L (ai "fields" : map fromField fs)]
        Union fs t ->
          [na, ai "union", fl, sl, dp, at t, L (ai "fields" : map fromField fs)]

cauterizeParser :: SExprParser Atom Component
cauterizeParser = setCarrier toComponent $ asWellFormed $ mkParser pAtom

componentsToSpec :: [Component] -> Specification
componentsToSpec cs = spec { specTypes = reverse $ specTypes spec }
  where
    spec = foldl go defaultSpecification cs
    go s (Name n) = s { specName = n }
    go s (Version v) = s { specVersion = v }
    go s (Fingerprint h) = s { specFingerprint = h }
    go s (SpecSize sz) = s { specSize = sz }
    go s (Depth d) = s { specDepth = d }
    go s (TypeLength l) = s { specTypeLength = l }
    go s (LengthTag t) = s { specLengthTag = t }
    go s (TypeDef t) = let ts = specTypes s
                        in s { specTypes = t:ts }

specToComponents :: Specification -> [Component]
specToComponents s =
    Name (specName s)
  : Version (specVersion s)
  : Fingerprint (specFingerprint s)
  : SpecSize (specSize s)
  : Depth (specDepth s)
  : TypeLength (specTypeLength s)
  : LengthTag (specLengthTag s)
  : map TypeDef (specTypes s)


parseSpecification :: Text -> Either String Specification
parseSpecification t = componentsToSpec `fmap` decode cauterizeParser t

formatSpecification :: Specification -> Text
formatSpecification s = let pp = encodeOne (basicPrint sAtom)
                            s' = map (pp . fromWellFormed . fromComponent) (specToComponents s)
                        in T.unlines s'

parseSpecificationFromFile :: FilePath -> IO (Either String Specification)
parseSpecificationFromFile p = liftM parseSpecification (T.readFile p)
