{-# LANGUAGE CPP, UndecidableInstances #-}
-- |
-- The contents of this module may seem a bit overwhelming.
-- Don't worry,
-- all it does is just cover instances and datatypes of records and tuples of
-- huge arities.
--
-- You don't actually need to ever use this module,
-- since all the functionality you may need is presented
-- by the quasiquoters exported in the root module.
module Record.Types where

import BasePrelude hiding (Proxy)
import Data.Functor.Identity
import GHC.TypeLits
import Record.Lens (Lens)
import Language.Haskell.TH
import Foreign.Storable
import Foreign.Ptr (plusPtr)


-- *
-------------------------


-- |
-- Defines a lens to manipulate some value of a type by a type-level name,
-- using the string type literal functionality.
--
-- Instances are provided for all records and for tuples of arity of up to 24.
--
-- Here's how you can use it with tuples:
--
-- >trd :: Field "3" v v' a' a => a -> v
-- >trd = view . fieldLens (undefined :: FieldName "3")
-- The function above will get you the third item of any tuple, which has it.
class Field (n :: Symbol) a a' v v' | n a -> v, n a' -> v', n a v' -> a', n a' v -> a where
  -- |
  -- A polymorphic lens. E.g.:
  --
  -- >ageLens :: Field "age" v v' a' a => Lens a a' v v'
  -- >ageLens = fieldLens (undefined :: FieldName "age")
  fieldLens :: FieldName n -> Lens a a' v v'

-- |
-- A simplified field constraint,
-- which excludes the possibility of type-changing updates.
type Field' n a v =
  Field n a a v v

-- |
-- A specialised version of "Data.Proxy.Proxy".
-- Defined for compatibility with \"base-4.6\",
-- since @Proxy@ was only defined in \"base-4.7\".
data FieldName (t :: Symbol)


-- * Record Types
-------------------------

-- Generate Record types
return $ flip map [1 .. 24] $ \arity ->
  let
    typeName =
      mkName $ "Record" <> show arity
    varBndrs =
      do
        i <- [1 .. arity]
        let
          n = KindedTV (mkName ("n" <> show i)) (ConT ''Symbol)
          v = PlainTV (mkName ("v" <> show i))
          in [n, v]
    conTypes =
      do
        i <- [1 .. arity]
        return $ (,) (NotStrict) (VarT (mkName ("v" <> show i)))
    derivingNames =
#if MIN_VERSION_base(4,7,0)
      [''Show, ''Eq, ''Ord, ''Typeable, ''Generic]
#else
      [''Show, ''Eq, ''Ord, ''Generic]
#endif
    in
      DataD [] typeName varBndrs [NormalC typeName conTypes] derivingNames


-- Generate instances of Foreign.Storable
return $ flip map [1 .. 24] $ \arity ->
  let
    typeName = mkName $ "Record" <> show arity
    recordType =
      foldl (\a i -> AppT (AppT a (VarT (mkName ("n" <> show i))))
                          (VarT (mkName ("v" <> show i))))
            (ConT typeName)
            [1 .. arity]
#if MIN_VERSION_template_haskell(2,10,0)
    -- In TH with `ConstraintKinds` the context is just simply a type
    context = map (\i -> AppT (ConT (mkName "Storable")) (VarT (mkName ("v" <> show i))))
              [1 .. arity]
#else
    context = map (\i -> ClassP (mkName "Storable")  [VarT (mkName ("v" <> show i))])
              [1 .. arity]
#endif
    nameE = VarE . mkName
    -- The sum of the sizes of all types
    sizeOfFun' n = foldr (\a b -> AppE (AppE (nameE "+") a) b) (LitE (IntegerL 0)) $
                   map (\i -> AppE
                              (nameE "sizeOf")
                              (SigE (nameE "undefined")
                                    (VarT (mkName ("v" <> show i)))))
                   [1..n]
    sizeOfFun = FunD (mkName "sizeOf")
                [Clause [WildP]
                 (NormalB (sizeOfFun' arity)) []]
    -- Set the alignment to the maximum alignment of the types
    alignmentFun = FunD (mkName "alignment")
                   [(Clause [WildP]
                     (NormalB (AppE (nameE "maximum") $ ListE $
                               map (\i -> AppE
                                          (nameE "sizeOf")
                                          (SigE (nameE "undefined")
                                                (VarT (mkName ("v" <> show i)))))
                               [1..arity])) [])]
    -- Peek every variable, remember to add the size of the elements already seen to the ptr
    peekFun = FunD (mkName "peek")
              [(Clause [VarP (mkName "ptr")]
                  (NormalB (DoE $ map (\i -> BindS
                                             (BangP (VarP (mkName ("x" <> show i))))
                                                    (AppE (nameE "peek")
                                                          (AppE (AppE (nameE "plusPtr")
                                                                      (nameE "ptr"))
                                                                (sizeOfFun' (i - 1))))) [1..arity]
                                 ++ [NoBindS (AppE (nameE "return")
                                             (foldl (\a i -> AppE a (nameE ("x" <> show i)))
                                             (ConE typeName) [1 .. arity]))])) [])]
    typePattern = ConP typeName (map (\i -> VarP (mkName ("v" <> show i))) [1..arity])
    pokeFun = FunD (mkName "poke")
              [(Clause [VarP (mkName "ptr"), typePattern]
                 (NormalB (DoE $ map (\i -> NoBindS
                                            (AppE
                                             (AppE (VarE (mkName "poke"))
                                                   (AppE (AppE (nameE "plusPtr")
                                                                 (nameE "ptr"))
                                                          (sizeOfFun' (i - 1))))
                                             (nameE ("v" <> show i)))) [1..arity])) [])]
    inlineFun name = PragmaD $ InlineP (mkName name) Inline FunLike AllPhases
  in
    InstanceD context (AppT (ConT (mkName "Storable")) recordType)
              [sizeOfFun, inlineFun "sizeOf", alignmentFun, inlineFun "alignment"
              , peekFun, inlineFun "peek", pokeFun, inlineFun "poke"]

-- *
-------------------------

return $ do
  arity <- [1 .. 24]
  nIndex <- [1 .. arity]
  return $
    let
      typeName =
        mkName $ "Record" <> show arity
      selectedNVarName =
        mkName $ "n" <> show nIndex
      selectedVVarName =
        mkName $ "v" <> show nIndex
      selectedV'VarName =
        mkName $ "v" <> show nIndex <> "'"
      recordType =
        foldl (\a i -> AppT (AppT a (VarT (mkName ("n" <> show i))))
                            (VarT (mkName ("v" <> show i))))
              (ConT typeName)
              [1 .. arity]
      record'Type =
        foldl (\a i -> AppT (AppT a (VarT (mkName ("n" <> show i))))
                            (VarT (if i == nIndex then selectedV'VarName
                                                  else mkName ("v" <> show i))))
              (ConT typeName)
              [1 .. arity]
      fieldLensLambda =
        LamE [VarP fVarName, ConP typeName (fmap VarP indexedVVarNames)] exp
        where
          fVarName =
            mkName "f"
          indexedVVarNames =
            fmap (\i -> mkName ("v" <> show i)) [1..arity]
          exp =
            AppE (AppE (VarE 'fmap) (consLambda))
                 (AppE (VarE fVarName) (VarE selectedVVarName))
            where
              consLambda =
                LamE [VarP selectedV'VarName] exp
                where
                  exp =
                    foldl AppE (ConE typeName) $
                    map VarE $
                    map (\(i, n) -> if i == nIndex then selectedV'VarName
                                                   else mkName ("v" <> show i)) $
                    zip [1 .. arity] indexedVVarNames
      in
        head $ unsafePerformIO $ runQ $
        [d|
          instance Field $(varT selectedNVarName)
                         $(pure recordType)
                         $(pure record'Type)
                         $(varT selectedVVarName)
                         $(varT selectedV'VarName)
                         where
            {-# INLINE fieldLens #-}
            fieldLens = const $(pure fieldLensLambda)
        |]


instance Field "1" (Identity v1) (Identity v1') v1 v1' where
  fieldLens = const $ \f -> fmap Identity . f . runIdentity


-- Generate Field instances for tuples
return $ do
  arity <- [2 .. 24]
  nIndex <- [1 .. arity]
  return $
    let
      typeName =
        tupleTypeName arity
      conName =
        tupleDataName arity
      selectedVVarName =
        mkName $ "v" <> show nIndex
      selectedV'VarName =
        mkName $ "v" <> show nIndex <> "'"
      tupleType =
        foldl (\a i -> AppT a (VarT (mkName ("v" <> show i))))
              (ConT typeName)
              [1 .. arity]
      tuple'Type =
        foldl (\a i -> AppT a (VarT (if i == nIndex then selectedV'VarName
                                                    else mkName ("v" <> show i))))
              (ConT typeName)
              [1 .. arity]
      fieldLensLambda =
        LamE [VarP fVarName, ConP conName (fmap VarP indexedVVarNames)] exp
        where
          fVarName =
            mkName "f"
          indexedVVarNames =
            fmap (\i -> mkName ("v" <> show i)) [1..arity]
          exp =
            AppE (AppE (VarE 'fmap) (consLambda))
                 (AppE (VarE fVarName) (VarE selectedVVarName))
            where
              consLambda =
                LamE [VarP selectedV'VarName] exp
                where
                  exp =
                    foldl AppE (ConE conName) $
                    map VarE $
                    map (\(i, n) -> if i == nIndex then selectedV'VarName
                                                   else mkName ("v" <> show i)) $
                    zip [1 .. arity] indexedVVarNames
      in
        head $ unsafePerformIO $ runQ $
        [d|
          instance Field $(pure (LitT (StrTyLit (show nIndex))))
                         $(pure tupleType)
                         $(pure tuple'Type)
                         $(varT selectedVVarName)
                         $(varT selectedV'VarName)
                         where
            {-# INLINE fieldLens #-}
            fieldLens = const $(pure fieldLensLambda)
        |]
