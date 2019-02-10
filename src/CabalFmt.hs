{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
-- | This is a demo application of how you can make Cabal-like
-- file formatter.
--
module CabalFmt (cabalFmt) where

import Control.Monad        (join)
import Control.Monad.Except (catchError)
import Control.Monad.Reader (asks, local)
import Data.Maybe           (fromMaybe)

import qualified Data.ByteString                              as BS
import qualified Distribution.CabalSpecVersion                as C
import qualified Distribution.FieldGrammar.Parsec             as C
import qualified Distribution.Fields                          as C
import qualified Distribution.Fields.ConfVar                  as C
import qualified Distribution.Fields.Pretty                   as C
import qualified Distribution.PackageDescription.FieldGrammar as C
import qualified Distribution.Parsec                          as C
import qualified Distribution.Pretty                          as C
import qualified Distribution.Simple.Utils                    as C
import qualified Distribution.Types.Condition                 as C
import qualified Distribution.Types.GenericPackageDescription as C
import qualified Distribution.Types.PackageDescription        as C
import qualified Distribution.Types.Version                   as C
import qualified Text.PrettyPrint                             as PP

import CabalFmt.Comments
import CabalFmt.Fields
import CabalFmt.Fields.BuildDepends
import CabalFmt.Fields.Extensions
import CabalFmt.Fields.Modules
import CabalFmt.Fields.TestedWith
import CabalFmt.Monad
import CabalFmt.Options
import CabalFmt.Parser
import CabalFmt.PrettyField

-------------------------------------------------------------------------------
-- Main
-------------------------------------------------------------------------------

cabalFmt :: FilePath -> BS.ByteString -> CabalFmt String
cabalFmt filepath contents = do
    indentWith  <- asks optIndent
    gpd         <- parseGpd filepath contents
    inputFields' <- parseFields contents
    let inputFields = attachComments contents inputFields'

    let v = C.cabalSpecFromVersionDigits
          $ C.versionNumbers
          $ C.specVersion
          $ C.packageDescription gpd

    local (\opts -> opts { optSpecVersion = v }) $ do

        outputPrettyFields <- genericFromParsecFields
            prettyFieldLines
            prettySectionArgs
            inputFields

        return $ showFields fromComments indentWith outputPrettyFields

fromComments :: Comments -> [String]
fromComments (Comments bss) = map C.fromUTF8BS bss

-------------------------------------------------------------------------------
-- Field prettyfying
-------------------------------------------------------------------------------

prettyFieldLines :: C.FieldName -> [C.FieldLine ann] -> CabalFmt PP.Doc
prettyFieldLines fn fls =
    fromMaybe (C.prettyFieldLines fn fls) <$> knownField fn fls

knownField :: C.FieldName -> [C.FieldLine ann] -> CabalFmt (Maybe PP.Doc)
knownField fn fls = do
    v <- asks optSpecVersion
    return $ join $ fieldDescrLookup (fieldDescrs v) fn $ \p pp ->
        case C.runParsecParser' v p "<input>" (C.fieldLinesToStream fls) of
            Right x -> Just (pp x)
            Left _  -> Nothing

fieldDescrs :: C.CabalSpecVersion -> FieldDescrs () ()
fieldDescrs v
    =  buildDependsF v
    <> setupDependsF v
    <> defaultExtensionsF
    <> otherExtensionsF
    <> exposedModulesF
    <> otherModulesF
    <> testedWithF
    <> coerceFieldDescrs C.packageDescriptionFieldGrammar
    <> coerceFieldDescrs C.buildInfoFieldGrammar

-------------------------------------------------------------------------------
-- Sections
-------------------------------------------------------------------------------

prettySectionArgs :: C.FieldName -> [C.SectionArg ann] -> CabalFmt [PP.Doc]
prettySectionArgs x args =
    prettySectionArgs' x args `catchError` \_ ->
        return (C.prettySectionArgs x args)

prettySectionArgs' :: a -> [C.SectionArg ann] -> CabalFmt [PP.Doc]
prettySectionArgs' _ args = do
    c <- runParseResult "<args>" "" $ C.parseConditionConfVar (map (C.zeroPos <$) args)
    return [ppCondition c]

-------------------------------------------------------------------------------
-- PrettyPrint condition
-------------------------------------------------------------------------------

-- This is originally from Cabal

ppCondition :: C.Condition C.ConfVar -> PP.Doc
ppCondition (C.Var x)      = ppConfVar x
ppCondition (C.Lit b)      = PP.text (show b)
ppCondition (C.CNot c)     = PP.char '!' PP.<> ppCondition c
ppCondition (C.COr c1 c2)  = PP.parens (PP.hsep [ppCondition c1, PP.text "||", ppCondition c2])
ppCondition (C.CAnd c1 c2) = PP.parens (PP.hsep [ppCondition c1, PP.text "&&", ppCondition c2])

ppConfVar :: C.ConfVar -> PP.Doc
ppConfVar (C.OS os)     = PP.text "os"   PP.<> PP.parens (C.pretty os)
ppConfVar (C.Arch arch) = PP.text "arch" PP.<> PP.parens (C.pretty arch)
ppConfVar (C.Flag name) = PP.text "flag" PP.<> PP.parens (C.pretty name)
ppConfVar (C.Impl c v)  = PP.text "impl" PP.<> PP.parens (C.pretty c PP.<+> C.pretty v)
