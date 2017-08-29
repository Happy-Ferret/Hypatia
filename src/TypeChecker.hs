module TypeChecker where

import Syntax
import Data.HashMap.Strict(HashMap, fromList, filterWithKey, insert)
import Control.Monad.Trans.Reader(ReaderT, runReaderT, ask, local)
import Control.Monad.Trans.Class(lift)
import Control.Arrow(first)
import Data.List(nub)
import Control.Monad(when, zipWithM)
import Data.IORef(readIORef, writeIORef, newIORef, modifyIORef, IORef)
import Data.Generics.Uniplate.Data(universe, para, descend)
import Data.Foldable(traverse_)


type Environment = HashMap Name Type

type Substitution = HashMap Id Type

data TypecheckerState = TypecheckerState Environment (IORef Integer) (IORef Substitution)

type Typechecker a = ReaderT TypecheckerState IO a

typecheckModule env m =
  do
    r <- newIORef 0
    s <- newIORef mempty
    runReaderT (inferModule m) (TypecheckerState env r s)

inferModule (ModuleDeclaration modName decls) =
  do
    info "---------------------------------"
    info ("Typechecking Module " ++ pretty modName)
    let enums = foldMap (gatherEnum (qualifyId modName)) decls
    let signatures = foldMap gatherTypeSig decls
    let types = mapKeys (qualifyId modName) (enums `mappend` signatures)
    binds <- with types (inferDecls (qualifyId modName) generalize decls)
    return (types `mappend` binds)

-- Typecheck Expressions
typecheck :: Expression -> Type -> Typechecker ()
typecheck (LiteralExpression lit) ty =
    typecheckLiteral lit ty
typecheck (Variable x) ty =
    typecheckVar x ty
typecheck (ConstructorExpression c) ty =
    typecheckVar c ty
typecheck (FunctionApplication e1 e2) ty =
  do
    alpha <- newTyVar
    typecheck e1 (TypeArrow alpha ty)
    typecheck e2 alpha
typecheck (CaseLambdaExpression alts) ty =
  do
    alpha <- newTyVar
    beta <- newTyVar
    traverse_ (typecheckAlt alpha beta) alts
    subsume (TypeArrow alpha beta) ty
typecheck (LambdaExpression [p] e) ty =
  do
    alpha <- newTyVar
    beta <- newTyVar
    info ("Typechecking lambda " ++ pretty p)
    typecheckAlt alpha beta (p, e)
    subsume (TypeArrow alpha beta) ty
typecheck (LetExpression decls e) ty =
  do
    let types = mapKeys fromId (foldMap gatherTypeSig decls)
    binds <- with types (inferDecls fromId return decls)
    with binds (typecheck e ty)
typecheck (IfExpression c th el) ty =
  do
    typecheck c (TypeConstructor (fromString "Prelude.Boolean"))
    typecheck th ty
    typecheck el ty
typecheck (ArrayExpression es) ty =
  do
    alpha <- newTyVar
    traverse_ (flip typecheck alpha) es
    unify (TypeApplication (TypeConstructor (fromString "Native.Array")) alpha) ty
typecheck other _ = fail ("Typecheck " ++ show other)

typecheckVar x ty =
  do
    env <- getEnv
    scheme <- mfind x env
    subsume scheme ty

typecheckAlt pty ety (pat, expr)  =
  do
    binds <- typecheckPattern pat pty
    let env = mapKeys fromId binds
    with env (typecheck expr ety)

-- Typecheck Constructors

-- capture enums from declarations for the type environment
gatherEnum qual (EnumDeclaration id vars constructors) =
    let enumName = TypeConstructor (qual id)
    in foldMap (constructorToType enumName vars) constructors
gatherEnum _ _ = mempty

-- convert a constructor declaration to a type
constructorToType ty vars (name, tys) =
    let
        res = foldl TypeApplication ty (fmap TypeVariable vars)
        resTy = foldr TypeArrow res tys
        frees = excluding vars (freeVars resTy)
    in case frees of
        [] -> singleton name (makeForAll vars resTy)
        _  -> error ("Type variables " ++ pretty frees
               ++ " appear free in " ++ pretty name )

arrowsToList (TypeArrow x xs) = x:arrowsToList xs
arrowsToList x = [x]

-- Typecheck Bindings
gatherTypeSig (TypeSignature name ty) =
    singleton name (makeForAll (freeVars ty) ty)
gatherTypeSig _ = mempty

-- the function assumes that the let bindings are already sorted
-- we have to sort the let bindings for the translation anyway
-- but we do not want to transform the bindings before type checking
-- TODO solve without sorting
-- TODO type annotations
inferDecls qual gen (ExpressionDeclaration p e:decls) =
  do
    info ("Typechecking declaration " ++ pretty p)

    ty <- newTyVar
    binds <- fmap (mapKeys qual) (typecheckPattern p ty)
    with binds (typecheck e ty)

    generalized <- traverse gen binds
    next <- with generalized (inferDecls qual gen decls)
    return (next `mappend` generalized)
inferDecls qual gen (_:decls) = inferDecls qual gen decls
inferDecls _ _ [] = return mempty

-- Typecheck Patterns
typecheckPattern (VariablePattern x) ty =
    return (singleton x ty)
typecheckPattern (AliasPattern x p) ty =
  do
    binds <- typecheckPattern p ty
    return (singleton x ty `mappend` binds)
typecheckPattern Wildcard _ =
    return mempty
typecheckPattern (LiteralPattern l) ty =
  do
    typecheckLiteral l ty
    return mempty
typecheckPattern (ConstructorPattern c ps) ty =
  do
    env <- getEnv
    scheme <- mfind c env
    consTy <- instantiate scheme

    let tys = arrowsToList consTy
    let resultTy = last tys
    let consTys = init tys

    when (length ps /= length consTys) 
        (fail ("Constructor " ++ pretty c ++ " was given wrong number of arguments"))
    binds <- zipWithM typecheckPattern ps consTys
    unify resultTy ty
    return (mconcat binds)
typecheckPattern (ArrayPattern ps) ty =
  do
    alpha <- newTyVar
    binds <- traverse (flip typecheckPattern alpha) ps
    unify (TypeApplication (TypeConstructor (fromString "Native.Array")) alpha) ty
    return (mconcat binds)
typecheckPattern other _ = fail ("Cannot typecheck pattern " ++ pretty other)

-- Typecheck Literals
typecheckLiteral (Numeral _) ty =
    unify (TypeConstructor (fromString "Native.Numeral")) ty
typecheckLiteral (Text _) ty =
    unify (TypeConstructor (fromString "Native.Text")) ty

-- Unification
unify x y =
  do
    subst <- getSubst
    unify' (apply subst x) (apply subst y)

unify' (SkolemConstant x) (SkolemConstant y) | x == y = return ()
unify' (TypeVariable x) (TypeVariable y) | x == y = return ()
unify' (TypeConstructor a) (TypeConstructor b) | a == b = return ()
unify' (TypeVariable x) ty = unifyVar x ty
unify' ty (TypeVariable x) = unifyVar x ty
unify' (TypeApplication f1 e1) (TypeApplication f2 e2) =
  do
    unify f1 f2
    unify e1 e2
unify' (TypeArrow a1 b1) (TypeArrow a2 b2) =
  do
    unify a1 a2
    unify b1 b2
unify' a b =
    fail ("Cannot unify " ++ pretty a ++ " and " ++ pretty b)

unifyVar x ty =
  do
    when (occurs x ty) (fail ("Occurs check: " ++ pretty x ++ " occurs in " ++ pretty ty))
    insertSubst x ty

-- Does a type variable occur in a type?
occurs x ty = elem x (freeVars ty)

-- substitute bound variables with unification variables
apply subst (ForAll vs ty) =
    let filteredSubst = filterWithKey (\k _ -> notElem k vs) subst
    in ForAll vs (apply filteredSubst ty)
apply subst ty@(TypeVariable x) = maybe ty (apply subst) (mfind x subst)
apply subst ty = descend (apply subst) ty

-- Environment
getEnv = fmap (\(TypecheckerState env _ _) -> env) ask

insertSubst k v =
  do
    r <- fmap (\(TypecheckerState _ _ s) -> s) ask
    modifyRef r (insert k v)

getSubst =
  do
    r <- fmap (\(TypecheckerState _ _ s) -> s) ask
    readRef r

with binds =
    local (\(TypecheckerState env r s) -> TypecheckerState (mappend binds env) r s)

-- Type Variables
newUnique =
  do
    TypecheckerState _ r _ <- ask
    i <- readRef r
    writeRef r (i + 1)
    return i

newTyVar = fmap TypeVariable newUniqueName

newUniqueName = fmap (makeId . ("t" ++) . show) newUnique

-- extract skolem constants
skolems ty = [c | SkolemConstant c <- universe ty]

-- extract free variables
freeVars ty =
    let
        f (ForAll vars _) cs = excluding vars (concat cs)
        f (TypeVariable v) _ = [v]
        f _ cs = concat cs
    in para f ty

generalize ty = do
    subst <- getSubst
    let ty' = apply subst ty
    env <- getEnv
    let envVars = foldMap freeVars env
    let qualVars = excluding envVars (freeVars ty')
    return (makeForAll qualVars ty')

instantiate (ForAll vars ty) =
  do
    subst <- traverse (\x -> fmap (\t -> (x, t)) newTyVar) vars
    return (apply (fromList subst) ty)
instantiate ty = return ty

subsume x y =
  do
    subst <- getSubst
    subsume' (apply subst x) (apply subst y)

subsume' scheme1 scheme2@(ForAll _ _) =
  do
    (skolVars, ty) <- skolemise scheme2
    subsume scheme1 ty
    let escVars = skolems scheme1 ++ skolems scheme2
    let escaped = including escVars skolVars
    when (null escaped) (fail ("Escape check: " ++ pretty escaped))
subsume' scheme@(ForAll _ _) t2 =
  do
    t1 <- instantiate scheme
    subsume t1 t2
subsume' (TypeArrow s1 s2) (TypeArrow s3 s4) =
  do
    subsume s3 s1
    subsume s2 s4
subsume' t1 t2 = unify' t1 t2

makeForAll tvs1 (ForAll tvs2 ty) =
    makeForAll (tvs1 ++ tvs2) ty
makeForAll tvs ty =
    case nub tvs of
        [] -> ty
        is -> ForAll is ty

skolemise (ForAll vars ty) =
  do
    skolVars <- traverse (const newUniqueName) vars
    let subs = fromList (zip vars (fmap SkolemConstant skolVars))
    return (skolVars, apply subs ty)
skolemise ty = return ([], ty)

info s = lift (putStrLn s)

writeRef s v = lift (writeIORef s v)

readRef s = lift (readIORef s)

newRef v = lift (newIORef v)

modifyRef s f = lift (modifyIORef s f)

mapKeys f m = fromList (fmap (first f) m)

singleton x y = pure (x, y)
