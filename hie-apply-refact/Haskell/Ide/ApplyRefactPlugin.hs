{-# OPTIONS_GHC -fno-warn-partial-type-signatures #-}

{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE DuplicateRecordFields #-}
module Haskell.Ide.ApplyRefactPlugin where

import           Control.Arrow
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Either
import           Data.Aeson hiding (Error)
import           Data.Monoid ( (<>) )
import qualified Data.Text as T
import qualified Data.Text.IO as T
import           Data.Vinyl
import           Haskell.Ide.Engine.MonadFunctions
import           Haskell.Ide.Engine.PluginDescriptor
import           Haskell.Ide.Engine.PluginUtils
import           Haskell.Ide.Engine.SemanticTypes
import           Language.Haskell.HLint3 as Hlint
import           Refact.Apply
-- import           System.Directory
import           System.IO.Extra
import           Language.Haskell.Exts.SrcLoc

-- ---------------------------------------------------------------------
{-# ANN module ("HLint: ignore Eta reduce"         :: String) #-}
{-# ANN module ("HLint: ignore Redundant do"       :: String) #-}
{-# ANN module ("HLint: ignore Reduce duplication" :: String) #-}
-- ---------------------------------------------------------------------

applyRefactDescriptor :: TaggedPluginDescriptor _
applyRefactDescriptor = PluginDescriptor
  {
    pdUIShortName = "ApplyRefact"
  , pdUIOverview = "apply-refact applies refactorings specified by the refact package. It is currently integrated into hlint to enable the automatic application of suggestions."
    , pdCommands =

        buildCommand applyOneCmd (Proxy :: Proxy "applyOne") "Apply a single hint"
                   [".hs"] (SCtxPoint :& RNil) RNil SaveAll

      :& buildCommand applyAllCmd (Proxy :: Proxy "applyAll") "Apply all hints to the file"
                   [".hs"] (SCtxFile :& RNil) RNil SaveAll

      :& buildCommand lintCmd (Proxy :: Proxy "lint") "Run hlint on the file to generate hints"
                   [".hs"] (SCtxFile :& RNil) RNil SaveAll

      :& RNil
  , pdExposedServices = []
  , pdUsedServices    = []
  }

-- ---------------------------------------------------------------------


applyOneCmd :: CommandFunc WorkspaceEdit
applyOneCmd = CmdSync $ \_ctxs req -> do
  case getParams (IdFile "file" :& IdPos "start_pos" :& RNil) req of
    Left err -> return err
    Right (ParamFile uri :& ParamPos pos :& RNil) ->
      applyOneCmd' uri pos

applyOneCmd' :: Uri -> Position -> IdeM (IdeResponse WorkspaceEdit)
applyOneCmd' uri pos = pluginGetFile "applyOne: " uri $ \file -> do
      res <- liftIO $ applyHint file (Just pos)
      logm $ "applyOneCmd:file=" ++ show file
      logm $ "applyOneCmd:res=" ++ show res
      case res of
        Left err -> return $ IdeResponseFail (IdeError PluginError
                      (T.pack $ "applyOne: " ++ show err) Null)
        Right fs -> return (IdeResponseOk fs)


-- ---------------------------------------------------------------------

applyAllCmd :: CommandFunc WorkspaceEdit
applyAllCmd = CmdSync $ \_ctxs req -> do
  case getParams (IdFile "file" :& RNil) req of
    Left err -> return err
    Right (ParamFile uri :& RNil) ->
      applyAllCmd' uri

applyAllCmd' :: Uri -> IdeM (IdeResponse WorkspaceEdit)
applyAllCmd' uri = pluginGetFile "applyAll: " uri $ \file -> do
      res <- liftIO $ applyHint file Nothing
      logm $ "applyAllCmd:res=" ++ show res
      case res of
        Left err -> return $ IdeResponseFail (IdeError PluginError
                      (T.pack $ "applyAll: " ++ show err) Null)
        Right fs -> return (IdeResponseOk fs)

-- ---------------------------------------------------------------------

lintCmd :: CommandFunc PublishDiagnosticsParams
lintCmd = CmdSync $ \_ctxs req -> do
  case getParams (IdFile "file" :& RNil) req of
    Left err -> return err
    Right (ParamFile uri :& RNil) -> lintCmd' uri

lintCmd' :: Uri -> IdeM (IdeResponse PublishDiagnosticsParams)
lintCmd' uri = pluginGetFile "applyAll: " uri $ \file -> do
      res <- liftIO $ runEitherT $ runLintCmd file []
      logm $ "lint:res=" ++ show res
      case res of
        Left diags -> return (IdeResponseOk (PublishDiagnosticsParams (filePathToUri file) $ List diags))
        Right fs   -> return (IdeResponseOk (PublishDiagnosticsParams (filePathToUri file) $ List (map hintToDiagnostic fs)))

runLintCmd :: FilePath -> [String] -> EitherT [Diagnostic] IO [Idea]
runLintCmd file args =
  do (flags,classify,hint) <- liftIO $ argsSettings args
     res <- bimapEitherT parseErrorToDiagnostic id $ EitherT $ parseModuleEx flags file Nothing
     pure $ applyHints classify hint [res]

parseErrorToDiagnostic :: Hlint.ParseError -> [Diagnostic]
parseErrorToDiagnostic (Hlint.ParseError l msg contents) =
  [Diagnostic
      { _range    = srcLoc2Range l
      , _severity = Just DsError
      , _code     = Just "parser"
      , _source   = Just "hlint"
      , _message  = T.unlines [T.pack msg,T.pack contents]
      }]

{-
-- | An idea suggest by a 'Hint'.
data Idea = Idea
    {ideaModule :: String -- ^ The module the idea applies to, may be @\"\"@ if the module cannot be determined or is a result of cross-module hints.
    ,ideaDecl :: String -- ^ The declaration the idea applies to, typically the function name, but may be a type name.
    ,ideaSeverity :: Severity -- ^ The severity of the idea, e.g. 'Warning'.
    ,ideaHint :: String -- ^ The name of the hint that generated the idea, e.g. @\"Use reverse\"@.
    ,ideaSpan :: SrcSpan -- ^ The source code the idea relates to.
    ,ideaFrom :: String -- ^ The contents of the source code the idea relates to.
    ,ideaTo :: Maybe String -- ^ The suggested replacement, or 'Nothing' for no replacement (e.g. on parse errors).
    ,ideaNote :: [Note] -- ^ Notes about the effect of applying the replacement.
    ,ideaRefactoring :: [Refactoring R.SrcSpan] -- ^ How to perform this idea
    }
    deriving (Eq,Ord)

-}

-- ---------------------------------------------------------------------

hintToDiagnostic :: Idea -> Diagnostic
hintToDiagnostic idea
  = Diagnostic
      { _range    = ss2Range (ideaSpan idea)
      , _severity = Just (severity2DisgnosticSeverity $ ideaSeverity idea)
      , _code     = Nothing
      , _source   = Just "hlint"
      , _message  = idea2Message idea
      }

-- ---------------------------------------------------------------------
{-

instance Show Idea where
    show = showEx id


showANSI :: IO (Idea -> String)
showANSI = do
    f <- hsColourConsole
    return $ showEx f

showEx :: (String -> String) -> Idea -> String
showEx tt Idea{..} = unlines $
    [showSrcLoc (getPointLoc ideaSpan) ++ ": " ++ (if ideaHint == "" then "" else show ideaSeverity ++ ": " ++ ideaHint)] ++
    f "Found" (Just ideaFrom) ++ f "Why not" ideaTo ++
    ["Note: " ++ n | let n = showNotes ideaNote, n /= ""]
    where
        f msg Nothing = []
        f msg (Just x) | null xs = [msg ++ " remove it."]
                       | otherwise = (msg ++ ":") : map ("  "++) xs
            where xs = lines $ tt x

-}

idea2Message :: Idea -> T.Text
idea2Message idea = T.unlines $ [T.pack $ ideaHint idea, "Found:", ("  " <> (T.pack $ ideaFrom idea))]
                               <> toIdea <> map (T.pack . show) (ideaNote idea)
  where
    toIdea :: [T.Text]
    toIdea = case ideaTo idea of
      Nothing -> []
      Just i  -> [T.pack "Why not:", T.pack $ "  " ++ i]

-- ---------------------------------------------------------------------

severity2DisgnosticSeverity :: Severity -> DiagnosticSeverity
severity2DisgnosticSeverity Ignore     = DsInfo
severity2DisgnosticSeverity Suggestion = DsHint
severity2DisgnosticSeverity Warning    = DsWarning
severity2DisgnosticSeverity Error      = DsError

-- ---------------------------------------------------------------------

srcLoc2Range :: SrcLoc -> Range
srcLoc2Range (SrcLoc _ l c) = Range ps pe
  where
    ps = Position (l-1) (c-1)
    pe = Position (l-1) 100000

-- ---------------------------------------------------------------------

ss2Range :: SrcSpan -> Range
ss2Range ss = Range ps pe
  where
    ps = Position (srcSpanStartLine ss - 1) (srcSpanStartColumn ss - 1)
    pe = Position (srcSpanEndLine ss - 1)   (srcSpanEndColumn ss - 1)

-- ---------------------------------------------------------------------

applyHint :: FilePath -> Maybe Position -> IO (Either String WorkspaceEdit)
applyHint file mpos = do
  withTempFile $ \f -> do
    let optsf = "-o " ++ f
        opts = case mpos of
                 Nothing -> optsf
                 Just (Position l c) -> optsf ++ " --pos " ++ show (l+1) ++ "," ++ show (c+1)
        hlintOpts = [file, "--quiet", "--refactor", "--refactor-options=" ++ opts ]
    runEitherT $ do
      ideas <- runHlint file hlintOpts
      liftIO $ logm $ "applyHint:ideas=" ++ show ideas
      let commands = map (show &&& ideaRefactoring) ideas
      appliedFile <- liftIO $ applyRefactorings (unPos <$> mpos) commands file
      diff <- liftIO $ makeDiffResult file (T.pack appliedFile)
      liftIO $ logm $ "applyHint:diff=" ++ show diff
      return diff


runHlint :: FilePath -> [String] -> EitherT String IO [Idea]
runHlint file args =
  do (flags,classify,hint) <- liftIO $ argsSettings args
     res <- bimapEitherT showParseError id $ EitherT $ parseModuleEx flags file Nothing
     pure $ applyHints classify hint [res]

showParseError :: Hlint.ParseError -> String
showParseError (Hlint.ParseError location message content) = unlines [show location, message, content]

makeDiffResult :: FilePath -> T.Text -> IO WorkspaceEdit
makeDiffResult orig new = do
  origText <- T.readFile orig
  return $ diffText (filePathToUri orig,origText) new