module Core.Context

import Core.CompileExpr
import public Core.Error
import public Core.Options
import public Core.TT
import public Core.Context.Ctxt
import public Core.Context.Def

import Data.Either
import Data.List
import Data.List1
import Data.Maybe
import Data.Nat

import Libraries.Data.NameMap
import Libraries.Data.UserNameMap
import Libraries.Text.Distance.Levenshtein

import System.Directory

getVisibility : {auto c : Ref Ctxt Defs} ->
                FC -> Name -> Core Visibility
getVisibility fc n
    = do defs <- get Ctxt
         Just def <- lookupCtxtExact n (gamma defs)
              | Nothing => throw (UndefinedName fc n)
         pure $ visibility def

-- Find similar looking names in the context
export
getSimilarNames : {auto c : Ref Ctxt Defs} ->
                   Name -> Core (Maybe (String, List (Name, Visibility, Nat)))
getSimilarNames nm = case show <$> userNameRoot nm of
  Nothing => pure Nothing
  Just str => if length str <= 1 then pure (Just (str, [])) else
    do defs <- get Ctxt
       let threshold : Nat := max 1 (assert_total (divNat (length str) 3))
       let test : Name -> Core (Maybe (Visibility, Nat)) := \ nm => do
               let (Just str') = show <$> userNameRoot nm
                   | _ => pure Nothing
               dist <- coreLift $ Levenshtein.compute str str'
               let True = dist <= threshold
                   | False => pure Nothing
               Just def <- lookupCtxtExact nm (gamma defs)
                   | Nothing => pure Nothing -- should be impossible
               pure (Just (visibility def, dist))
       kept <- mapMaybeM @{CORE} test (resolvedAs (gamma defs))
       pure $ Just (str, toList kept)

export
showSimilarNames : Namespace -> Name -> String ->
                   List (Name, Visibility, Nat) -> List String
showSimilarNames ns nm str kept
  = let (loc, priv) := partitionEithers $ kept <&> \ (nm', vis, n) =>
                         let False = fst (splitNS nm') `isParentOf` ns
                               | _ => Left (nm', n)
                             Private = vis
                               | _ => Left (nm', n)
                         in Right (nm', n)
        sorted      := sortBy (compare `on` snd)
        roots1      := mapMaybe (showNames nm str False . fst) (sorted loc)
        roots2      := mapMaybe (showNames nm str True  . fst) (sorted priv)
    in nub roots1 ++ nub roots2

  where

  showNames : Name -> String -> Bool -> Name -> Maybe String
  showNames target str priv nm = do
    let adj  = if priv then " (not exported)" else ""
    let root = nameRoot nm
    let True = str == root
      | _ => pure (root ++ adj)
    let full = show nm
    let True = (str == full || show target == full) && not priv
      | _ => pure (full ++ adj)
    Nothing

export
isPrimName : List Name -> Name -> Bool
isPrimName prims given = let (ns, nm) = splitNS given in go ns nm prims where

  go : Namespace -> Name -> List Name -> Bool
  go ns nm [] = False
  go ns nm (p :: ps)
    = let (ns', nm') = splitNS p in
      (nm' == nm && (ns' `isApproximationOf` ns))
      || go ns nm ps

parameters {auto c : Ref Ctxt Defs}
  maybeMisspelling : Error -> Name -> Core a
  maybeMisspelling err nm = do
    ns <- currentNS <$> get Ctxt
    Just (str, kept) <- getSimilarNames nm
      | Nothing => throw err
    let candidates = showSimilarNames ns nm str kept
    case candidates of
      [] => throw err
      (x::xs) => throw (MaybeMisspelling err (x ::: xs))

  -- Throw an UndefinedName exception. But try to find similar names first.
  export
  undefinedName : FC -> Name -> Core a
  undefinedName loc nm = maybeMisspelling (UndefinedName loc nm) nm

  -- Throw a NoDeclaration exception. But try to find similar names first.
  export
  noDeclaration : FC -> Name -> Core a
  noDeclaration loc nm = maybeMisspelling (NoDeclaration loc nm) nm

  export
  ambiguousName : FC -> Name -> List Name -> Core a
  ambiguousName fc n ns = do
    ns <- filterM (\x => pure $ !(getVisibility fc x) /= Private) ns
    case ns of
      [] =>         undefinedName fc n
      ns => throw $ AmbiguousName fc ns

  export
  aliasName : Name -> Core Name
  aliasName fulln
      = do defs <- get Ctxt
           let Just r = userNameRoot fulln
                  | Nothing => pure fulln
           let Just ps = lookup r (possibles (gamma defs))
                  | Nothing => pure fulln
           findAlias ps
    where
      findAlias : List PossibleName -> Core Name
      findAlias [] = pure fulln
      findAlias (Alias as full i :: ps)
          = if full == fulln
               then pure as
               else findAlias ps
      findAlias (_ :: ps) = findAlias ps

  export
  checkUndefined : FC -> Name -> Core ()
  checkUndefined fc n
      = do defs <- get Ctxt
           Nothing <- lookupCtxtExact n (gamma defs)
               | _ => throw (AlreadyDefined fc n)
           pure ()

  export
  getNextTypeTag : Core Int
  getNextTypeTag
      = do defs <- get Ctxt
           put Ctxt ({ nextTag $= (+1) } defs)
           pure (nextTag defs)

  -- Add a new nested namespace to the current namespace for new definitions
  -- e.g. extendNS ["Data"] when namespace is "Prelude.List" leads to
  -- current namespace of "Prelude.List.Data"
  -- Inner namespaces go first, for ease of name lookup
  export
  extendNS : Namespace -> Core ()
  extendNS ns = update Ctxt { currentNS $= (<.> ns) }

  export
  withExtendedNS : Namespace -> Core a -> Core a
  withExtendedNS ns act
      = do defs <- get Ctxt
           let cns = currentNS defs
           put Ctxt ({ currentNS := cns <.> ns } defs)
           ma <- catch (Right <$> act) (pure . Left)
           defs <- get Ctxt
           put Ctxt ({ currentNS := cns } defs)
           case ma of
             Left err => throw err
             Right a  => pure a

  -- Get the name as it would be defined in the current namespace
  -- i.e. if it doesn't have an explicit namespace already, add it,
  -- otherwise leave it alone
  export
  inCurrentNS : Name -> Core Name
  inCurrentNS (UN n)
      = do defs <- get Ctxt
           pure (NS (currentNS defs) (UN n))
  inCurrentNS n@(WithBlock _ _)
      = do defs <- get Ctxt
           pure (NS (currentNS defs) n)
  inCurrentNS n@(Nested _ _)
      = do defs <- get Ctxt
           pure (NS (currentNS defs) n)
  inCurrentNS n@(MN _ _)
      = do defs <- get Ctxt
           pure (NS (currentNS defs) n)
  inCurrentNS n@(DN _ _)
      = do defs <- get Ctxt
           pure (NS (currentNS defs) n)
  inCurrentNS n = pure n

  export
  setVisible : Namespace -> Core ()
  setVisible nspace = update Ctxt { gamma->visibleNS $= (nspace ::) }

  export
  getVisible : Core (List Namespace)
  getVisible
      = do defs <- get Ctxt
           pure (visibleNS (gamma defs))

  -- Return True if the given namespace is visible in the context (meaning
  -- the namespace itself, and any namespace it's nested inside)
  export
  isVisible : Namespace -> Core Bool
  isVisible nspace
      = do defs <- get Ctxt
           pure (any visible (allParents (currentNS defs) ++
                              nestedNS defs ++
                              visibleNS (gamma defs)))

    where
      -- Visible if any visible namespace is a parent of the namespace we're
      -- asking about
      visible : Namespace -> Bool
      visible visns = isParentOf visns nspace

  -- Get the next entry id in the context (this is for recording where to go
  -- back to when backtracking in the elaborator)
  export
  getNextEntry : Core Int
  getNextEntry
      = do defs <- get Ctxt
           pure (nextEntry (gamma defs))

  export
  setNextEntry : Int -> Core ()
  setNextEntry i = update Ctxt { gamma->nextEntry := i }

  -- Set the 'first entry' index (i.e. the first entry in the current file)
  -- to the place we currently are in the context
  export
  resetFirstEntry : Core ()
  resetFirstEntry
      = do defs <- get Ctxt
           put Ctxt ({ gamma->firstEntry := nextEntry (gamma defs) } defs)

  export
  getFullName : Name -> Core Name
  getFullName (Resolved i)
      = do defs <- get Ctxt
           Just gdef <- lookupCtxtExact (Resolved i) (gamma defs)
                | Nothing => pure (Resolved i)
           pure (fullname gdef)
  getFullName n = pure n

-- Dealing with various options

  export
  checkUnambig : FC -> Name -> Core Name
  checkUnambig fc n
      = do defs <- get Ctxt
           case !(lookupDefName n (gamma defs)) of
                [(fulln, i, _)] => pure (Resolved i)
                ns => ambiguousName fc n (map fst ns)

  export
  lazyActive : Bool -> Core ()
  lazyActive a = update Ctxt { options->elabDirectives->lazyActive := a }

  export
  setUnboundImplicits : Bool -> Core ()
  setUnboundImplicits a = update Ctxt { options->elabDirectives->unboundImplicits := a }

  export
  setPrefixRecordProjections : Bool -> Core ()
  setPrefixRecordProjections b = update Ctxt { options->elabDirectives->prefixRecordProjections := b }

  export
  setDefaultTotalityOption : TotalReq -> Core ()
  setDefaultTotalityOption tot = update Ctxt { options->elabDirectives->totality := tot }

  export
  setAmbigLimit : Nat -> Core ()
  setAmbigLimit max = update Ctxt { options->elabDirectives->ambigLimit := max }

  export
  setAutoImplicitLimit : Nat -> Core ()
  setAutoImplicitLimit max = update Ctxt { options->elabDirectives->autoImplicitLimit := max }

  export
  setNFThreshold : Nat -> Core ()
  setNFThreshold max = update Ctxt { options->elabDirectives->nfThreshold := max }

  export
  setSearchTimeout : Integer -> Core ()
  setSearchTimeout t = update Ctxt { options->session->searchTimeout := t }

  export
  isLazyActive : Core Bool
  isLazyActive
      = do defs <- get Ctxt
           pure (lazyActive (elabDirectives (options defs)))

  export
  isUnboundImplicits : Core Bool
  isUnboundImplicits
      = do defs <- get Ctxt
           pure (unboundImplicits (elabDirectives (options defs)))

  export
  isPrefixRecordProjections : Core Bool
  isPrefixRecordProjections =
    prefixRecordProjections . elabDirectives . options <$> get Ctxt

  export
  getDefaultTotalityOption : Core TotalReq
  getDefaultTotalityOption
      = do defs <- get Ctxt
           pure (totality (elabDirectives (options defs)))

  export
  getAmbigLimit : Core Nat
  getAmbigLimit
      = do defs <- get Ctxt
           pure (ambigLimit (elabDirectives (options defs)))

  export
  getAutoImplicitLimit : Core Nat
  getAutoImplicitLimit
      = do defs <- get Ctxt
           pure (autoImplicitLimit (elabDirectives (options defs)))

  export
  setPair : FC -> (pairType : Name) -> (fstn : Name) -> (sndn : Name) ->
            Core ()
  setPair fc ty f s
      = do ty' <- checkUnambig fc ty
           f' <- checkUnambig fc f
           s' <- checkUnambig fc s
           update Ctxt { options $= setPair ty' f' s' }

  export
  setRewrite : FC -> (eq : Name) -> (rwlemma : Name) -> Core ()
  setRewrite fc eq rw
      = do rw' <- checkUnambig fc rw
           eq' <- checkUnambig fc eq
           update Ctxt { options $= setRewrite eq' rw' }

  -- Don't check for ambiguity here; they're all meant to be overloadable
  export
  setFromInteger : Name -> Core ()
  setFromInteger n = update Ctxt { options $= setFromInteger n }

  export
  setFromString : Name -> Core ()
  setFromString n = update Ctxt { options $= setFromString n }

  export
  setFromChar : Name -> Core ()
  setFromChar n = update Ctxt { options $= setFromChar n }

  export
  setFromDouble : Name -> Core ()
  setFromDouble n = update Ctxt { options $= setFromDouble n }

  export
  addNameDirective : FC -> Name -> List String -> Core ()
  addNameDirective fc n ns
      = do n' <- checkUnambig fc n
           update Ctxt { namedirectives $= insert n' ns  }

  -- Checking special names from Options

  export
  isPairType : Name -> Core Bool
  isPairType n
      = do defs <- get Ctxt
           case pairnames (options defs) of
                Nothing => pure False
                Just l => pure $ !(getFullName n) == !(getFullName (pairType l))

  export
  fstName : Core (Maybe Name)
  fstName
      = do defs <- get Ctxt
           pure $ maybe Nothing (Just . fstName) (pairnames (options defs))

  export
  sndName : Core (Maybe Name)
  sndName
      = do defs <- get Ctxt
           pure $ maybe Nothing (Just . sndName) (pairnames (options defs))

  export
  getRewrite : Core (Maybe Name)
  getRewrite
      = do defs <- get Ctxt
           pure $ maybe Nothing (Just . rewriteName) (rewritenames (options defs))

  export
  isEqualTy : Name -> Core Bool
  isEqualTy n
      = do defs <- get Ctxt
           case rewritenames (options defs) of
                Nothing => pure False
                Just r => pure $ !(getFullName n) == !(getFullName (equalType r))

  export
  fromIntegerName : Core (Maybe Name)
  fromIntegerName
      = do defs <- get Ctxt
           pure $ fromIntegerName (primnames (options defs))

  export
  fromStringName : Core (Maybe Name)
  fromStringName
      = do defs <- get Ctxt
           pure $ fromStringName (primnames (options defs))

  export
  fromCharName : Core (Maybe Name)
  fromCharName
      = do defs <- get Ctxt
           pure $ fromCharName (primnames (options defs))

  export
  fromDoubleName : Core (Maybe Name)
  fromDoubleName
      = do defs <- get Ctxt
           pure $ fromDoubleName (primnames (options defs))

  export
  getPrimNames : Core PrimNames
  getPrimNames = [| MkPrimNs fromIntegerName fromStringName fromCharName fromDoubleName |]

  export
  getPrimitiveNames : Core (List Name)
  getPrimitiveNames = primNamesToList <$> getPrimNames

  export
  addLogLevel : Maybe LogLevel -> Core ()
  addLogLevel Nothing  = update Ctxt { options->session->logEnabled := False, options->session->logLevel := defaultLogLevel }
  addLogLevel (Just l) = update Ctxt { options->session->logEnabled := True, options->session->logLevel $= insertLogLevel l }

  export
  withLogLevel : LogLevel -> Core a -> Core a
  withLogLevel l comp = do
    defs <- get Ctxt
    let logs = logLevel (session (options defs))
    put Ctxt ({ options->session->logLevel := insertLogLevel l logs } defs)
    r <- comp
    defs <- get Ctxt
    put Ctxt ({ options->session->logLevel := logs } defs)
    pure r

  export
  setLogTimings : Nat -> Core ()
  setLogTimings n = update Ctxt { options->session->logTimings := Just n }

  export
  setDebugElabCheck : Bool -> Core ()
  setDebugElabCheck b = update Ctxt { options->session->debugElabCheck := b }

  export
  getSession : CoreE err Session
  getSession
      = do defs <- get Ctxt
           pure (session (options defs))

  export
  setSession : Session -> CoreE err ()
  setSession sopts = update Ctxt { options->session := sopts }

  export
  updateSession : (Session -> Session) -> CoreE err ()
  updateSession f = setSession (f !getSession)

  export
  recordWarning : Warning -> Core ()
  recordWarning w = update Ctxt { warnings $= (w ::) }

  export
  getDirs : CoreE err Dirs
  getDirs
      = do defs <- get Ctxt
           pure (dirs (options defs))

  export
  addExtraDir : String -> CoreE err ()
  addExtraDir dir = update Ctxt { options->dirs->extra_dirs $= (++ [dir]) }

  export
  addPackageDir : String -> CoreE err ()
  addPackageDir dir = update Ctxt { options->dirs->package_dirs $= (++ [dir]) }

  export
  addDataDir : String -> CoreE err ()
  addDataDir dir = update Ctxt { options->dirs->data_dirs $= (++ [dir]) }

  export
  addLibDir : String -> CoreE err ()
  addLibDir dir = update Ctxt { options->dirs->lib_dirs $= (++ [dir]) }

  export
  setBuildDir : String -> CoreE err ()
  setBuildDir dir = update Ctxt { options->dirs->build_dir := dir }

  export
  setDependsDir : String -> CoreE err ()
  setDependsDir dir = update Ctxt { options->dirs->depends_dir := dir }

  export
  setOutputDir : Maybe String -> CoreE err ()
  setOutputDir dir = update Ctxt { options->dirs->output_dir := dir }

  export
  setSourceDir : Maybe String -> CoreE err ()
  setSourceDir mdir = update Ctxt { options->dirs->source_dir := mdir }

  export
  setWorkingDir : String -> CoreFile ()
  setWorkingDir dir
      = do coreLift_ $ changeDir dir
           Just cdir <- coreLift $ currentDir
                | Nothing => throw (TTFileErr "Can't get current directory")
           update Ctxt { options->dirs->working_dir := cdir }

  export
  getWorkingDir : CoreFile String
  getWorkingDir
      = do Just d <- coreLift $ currentDir
                | Nothing => throw (TTFileErr "Can't get current directory")
           pure d

  export
  toFullNames : HasNames a =>
                a -> Core a
  toFullNames t
      = do defs <- get Ctxt
           full (gamma defs) t

  export
  toResolvedNames : HasNames a =>
                    a -> Core a
  toResolvedNames t
      = do defs <- get Ctxt
           resolved (gamma defs) t

  -- Set the default namespace for new definitions
  export
  setNS : Namespace -> Core ()
  setNS ns = update Ctxt { currentNS := ns }

  -- Set the nested namespaces we're allowed to look inside
  export
  setNestedNS : List Namespace -> Core ()
  setNestedNS ns = update Ctxt { nestedNS := ns }

  -- Get the default namespace for new definitions
  export
  getNS : Core Namespace
  getNS
      = do defs <- get Ctxt
           pure (currentNS defs)

  -- Get the nested namespaces we're allowed to look inside
  export
  getNestedNS : Core (List Namespace)
  getNestedNS
      = do defs <- get Ctxt
           pure (nestedNS defs)

  -- Add the module name, and namespace, of an imported module
  -- (i.e. for "import X as Y", it's (X, Y)
  -- "import public X" is, when rexported, the same as
  -- "import X as [current namespace]")
  export
  addImported : (ModuleIdent, Bool, Namespace) -> Core ()
  addImported mod = update Ctxt { imported $= (mod ::) }

  export
  getImported : Core (List (ModuleIdent, Bool, Namespace))
  getImported
      = do defs <- get Ctxt
           pure (imported defs)

  export
  addDirective : String -> String -> Core ()
  addDirective c str
      = do defs <- get Ctxt
           case getCG (options defs) c of
                Nothing => -- warn, rather than fail, because the CG may exist
                           -- but be unknown to this particular instance
                           coreLift $ putStrLn $ "Unknown code generator " ++ c
                Just cg => put Ctxt ({ cgdirectives $= ((cg, str) ::) } defs)

  export
  getDirectives : CG -> Core (List String)
  getDirectives cg
      = do defs <- get Ctxt
           pure $ defs.options.session.directives ++
                   mapMaybe getDir (cgdirectives defs)
    where
      getDir : (CG, String) -> Maybe String
      getDir (x', str) = if cg == x' then Just str else Nothing

reducibleIn : Namespace -> Name -> Visibility -> Bool
reducibleIn nspace (NS ns (UN n)) Export = isParentOf ns nspace
reducibleIn nspace (NS ns (UN n)) Private = isParentOf ns nspace
reducibleIn nspace n _ = True

export
reducibleInAny : List Namespace -> Name -> Visibility -> Bool
reducibleInAny nss n vis = any (\ns => reducibleIn ns n vis) nss
