module Eval where

import Data.List
import Data.Maybe (fromMaybe)
import Data.Map (Map,(!))
import qualified Data.Map as Map
-- import Data.Set (Set)
-- import qualified Data.Set as Set

import Connections
import CTT

look :: String -> Env -> Val
look x (Pair rho (y,u)) | x == y    = u
                        | otherwise = look x rho
look x r@(Def rho r1) = case lookup x rho of
  Just (_,t) -> eval r t
  Nothing    -> look x r1
look x (Sub rho _) = look x rho

lookType :: String -> Env -> Val
lookType x (Pair rho (y,VVar _ a)) | x == y    = a
                                   | otherwise = lookType x rho
lookType x r@(Def rho r1) = case lookup x rho of
  Just (a,_) -> eval r a
  Nothing -> lookType x r1
lookType x (Sub rho _) = lookType x rho

lookName :: Name -> Env -> Formula
lookName i (Pair rho _) = lookName i rho
lookName i (Def _ rho)  = lookName i rho
lookName i (Sub rho (j,phi)) | i == j    = phi
                             | otherwise = lookName i rho

-----------------------------------------------------------------------
-- Nominal instances

instance Nominal Env where
  support Empty             = []
  support (Pair rho (_,u))  = support u `union` support rho
  support (Sub rho (_,phi)) = support phi `union` support rho
  support (Def _ rho)       = support rho

  act e iphi = mapEnv (`act` iphi) (`act` iphi) e
  swap e ij  = mapEnv (`swap` ij) (`swap` ij) e

instance Nominal Val where
  support VU                            = []
  support (Ter _ e)                     = support e
  support (VPi v1 v2)                   = support [v1,v2]
  support (VComp a u ts)                = support (a,u,ts)
  support (VIdP a v0 v1)                = support [a,v0,v1]
  support (VPath i v)                   = i `delete` support v
  support (VTrans u v)                  = support (u,v)
  support (VSigma u v)                  = support (u,v)
  support (VSPair u v)                  = support (u,v)
  support (VFst u)                      = support u
  support (VSnd u)                      = support u
  support (VCon _ vs)                   = support vs
  support (VVar _ v)                    = support v
  support (VApp u v)                    = support (u,v)
  support (VAppFormula u phi)           = support (u,phi)
  support (VSplit u v)                  = support (u,v)

  act u (i, phi) =
    let acti :: Nominal a => a -> a
        acti u = act u (i, phi)
        sphi = support phi
    in case u of
         VU      -> VU
         Ter t e -> Ter t (acti e)
         VPi a f -> VPi (acti a) (acti f)
         VComp a v ts -> compLine (acti a) (acti v) (acti ts)
         VIdP a u v -> VIdP (acti a) (acti u) (acti v)
         VPath j v | j `notElem` sphi -> VPath j (acti v)
                   | otherwise -> VPath k (v `swap` (j,k))
              where k = fresh (v, Atom i, phi)
         VTrans u v -> transLine (acti u) (acti v)
         VSigma a f -> VSigma (acti a) (acti f)
         VSPair u v -> VSPair (acti u) (acti v)
         VFst u     -> VFst (acti u)
         VSnd u     -> VSnd (acti u)
         VCon c vs  -> VCon c (acti vs)
         VVar x v   -> VVar x (acti v)
         VAppFormula u psi -> acti u @@ acti psi
         VApp u v   -> app (acti u) (acti v)
         VSplit u v -> app (acti u) (acti v)

  -- This increases efficiency as it won't trigger computation.
  swap u ij@ (i,j) =
    let sw :: Nominal a => a -> a
        sw u = swap u ij
    in case u of
         VU      -> VU
         Ter t e -> Ter t (sw e)
         VPi a f -> VPi (sw a) (sw f)
         VComp a v ts -> VComp (sw a) (sw v) (sw ts)
         VIdP a u v -> VIdP (sw a) (sw u) (sw v)
         VPath k v -> VPath (swapName k ij) (sw v)
         VTrans u v -> VTrans (sw u) (sw v)
         VSigma a f -> VSigma (sw a) (sw f)
         VSPair u v -> VSPair (sw u) (sw v)
         VFst u     -> VFst (sw u)
         VSnd u     -> VSnd (sw u)
         VCon c vs  -> VCon c (sw vs)
         VVar x v           -> VVar x (sw v)
         VAppFormula u psi -> VAppFormula (sw u) (sw psi)
         VApp u v          -> VApp (sw u) (sw v)
         VSplit u v        -> VSplit (sw u) (sw v)

-----------------------------------------------------------------------
-- The evaluator

eval :: Env -> Ter -> Val
eval rho v = case v of
  U                   -> VU
  App r s             -> app (eval rho r) (eval rho s)
  Var i               -> look i rho
  Pi t@(Lam _ a _)    -> VPi (eval rho a) (eval rho t)
  Lam{}               -> Ter v rho
  Sigma t@(Lam _ a _) -> VSigma (eval rho a) (eval rho t)
  SPair a b           -> VSPair (eval rho a) (eval rho b)
  Fst a               -> fstVal (eval rho a)
  Snd a               -> sndVal (eval rho a)
  Where t decls       -> eval (Def decls rho) t
  Con name ts         -> VCon name (map (eval rho) ts)
  Split{}             -> Ter v rho
  Sum{}               -> Ter v rho
  Undef l             -> error $ "eval: undefined at " ++ show l
  IdP a e0 e1         -> VIdP (eval rho a) (eval rho e0) (eval rho e1)
  Path i t            ->
    let j = fresh rho
    in VPath j (eval (Sub rho (i,Atom j)) t)
  Trans u v        -> transLine (eval rho u) (eval rho v)
  AppFormula e phi -> (eval rho e) @@ (evalFormula rho phi)
  Comp a t0 ts     -> compLine (eval rho a) (eval rho t0) (evalSystem rho ts)

evalFormula :: Env -> Formula -> Formula
evalFormula rho phi = case phi of
  Atom i         -> lookName i rho
  NegAtom i      -> negFormula (lookName i rho)
  phi1 :/\: phi2 -> evalFormula rho phi1 `andFormula` evalFormula rho phi2
  phi1 :\/: phi2 -> evalFormula rho phi1 `orFormula` evalFormula rho phi2
  _              -> phi

evals :: Env -> [(Ident,Ter)] -> [(Ident,Val)]
evals env bts = [ (b,eval env t) | (b,t) <- bts ]

evalSystem :: Env -> System Ter -> System Val
evalSystem rho ts =
  let out = concat [ let betas = meetss [ invFormula (lookName i rho) d
                                        | (i,d) <- Map.assocs alpha ]
                     in [ (beta,eval (rho `face` beta) talpha) | beta <- betas ]
                   | (alpha,talpha) <- Map.assocs ts ]
  in mkSystem out

-- TODO: Write using case-of
app :: Val -> Val -> Val
app (Ter (Lam x _ t) e) u                  = eval (Pair e (x,u)) t
app (Ter (Split _ _ nvs) e) (VCon name us) = case lookup name nvs of
  Just (xs,t) -> eval (pairs e (zip xs us)) t
  Nothing     -> error $ "app: Split with insufficient arguments; " ++
                         " missing case for " ++ name
app u@(Ter (Split _ _ _) _) v | isNeutral v = VSplit u v

app kan@(VTrans (VPath i (VPi a f)) li0) ui1 =
    let j   = fresh (kan,ui1)
        (aj,fj) = (a,f) `swap` (i,j)
        u   = transFillNeg j aj ui1
        ui0 = transNeg j aj ui1
    in trans j (app fj u) (app li0 ui0)
app kan@(VComp (VPi a f) li0 ts) ui1 =
    let j   = fresh (kan,ui1)
        tsj = Map.map (@@ j) ts
    in comp j (app f ui1) (app li0 ui1)
              (Map.intersectionWith app tsj (border ui1 tsj))
app r s | isNeutral r = VApp r s
app _ _ = error "app"

fstVal, sndVal :: Val -> Val
fstVal (VSPair a b)    = a
fstVal u | isNeutral u = VFst u
sndVal (VSPair a b)    = b
sndVal u | isNeutral u = VSnd u

-- infer the type of a neutral value
inferType :: Val -> Val
inferType v = case v of
  VVar _ t -> t
  VFst t -> case inferType t of
    VSigma a _ -> a
    ty         -> error $ "inferType: expected Sigma type for " ++ show v
                  ++ ", got " ++ show ty
  VSnd t -> case inferType t of
    VSigma _ f -> app f (VFst t)
    ty         -> error $ "inferType: expected Sigma type for " ++ show v
                  ++ ", got " ++ show ty
  VSplit (Ter (Split _ f _) rho) v1 -> app (eval rho f) v1
  VApp t0 t1 -> case inferType t0 of
    VPi _ f -> app f t1
    ty      -> error $ "inferType: expected Pi type for " ++ show v
               ++ ", got " ++ show ty
  VAppFormula t phi -> case inferType t of
    VIdP a _ _ -> a @@ phi
    ty         -> error $ "inferType: expected IdP type for " ++ show v
                  ++ ", got " ++ show ty
  _ -> error "inferType: not neutral " ++ show v

(@@) :: ToFormula a => Val -> a -> Val
(VPath i u) @@ phi = u `act` (i,toFormula phi)
-- (KanUElem _ u) @@ phi = u @@ phi
v @@ phi | isNeutral v = case (inferType v,toFormula phi) of
  (VIdP  _ a0 _,Dir 0) -> a0
  (VIdP  _ _ a1,Dir 1) -> a1
  _  -> VAppFormula v (toFormula phi)
v @@ phi = error $ "(@@): " ++ show v ++ " should be neutral."

-----------------------------------------------------------
-- Transport

transLine :: Val -> Val -> Val
transLine u v = trans i (u @@ i) v
  where i = fresh (u,v)

trans, transNeg :: Name -> Val -> Val -> Val
trans i v0 v1 = case (v0,v1) of
  (VIdP a u v,w) ->
    let j   = fresh (Atom i, v0, w)
        ts' = mkSystem [(j ~> 0,u),(j ~> 1,v)]
    in VPath j $ genComp i (a @@ j) (w @@ j) ts'
  (VSigma a f,u) ->
    let (u1,u2) = (fstVal u,sndVal u)
        fill_u1 = transFill i a u1
        ui1     = trans i a u1
        comp_u2 = trans i (app f fill_u1) u2
    in VSPair ui1 comp_u2
  (VPi{},_) -> VTrans (VPath i v0) v1
  (Ter (Sum _ _ nass) env,VCon n us) -> case lookup n nass of
    Just as -> VCon n $ transps i as env us
    Nothing -> error $ "comp: missing constructor in labelled sum " ++ n
  _ | isNeutral v0 || isNeutral v1 -> VTrans (VPath i v0) v1
    | otherwise -> error "trans not implemented"
transNeg i a u = trans i (a `sym` i) u

transFill, transFillNeg :: Name -> Val -> Val -> Val
transFill i a u = trans j (a `conj` (i,j)) u
  where j = fresh (Atom i,a,u)
transFillNeg i a u = (transFill i (a `sym` i) u) `sym` i

transps :: Name -> [(Ident,Ter)] -> Env -> [Val] -> [Val]
transps i []         _ []     = []
transps i ((x,a):as) e (u:us) =
  let v   = transFill i (eval e a) u
      vi1 = trans i (eval e a) u
      vs  = transps i as (Pair e (x,v)) us
  in vi1 : vs
transps _ _ _ _ = error "transps: different lengths of types and values"

-----------------------------------------------------------
-- Composition

compLine :: Val -> Val -> System Val -> Val
compLine a u ts = comp i a u (Map.map (@@ i) ts)
  where i = fresh (a,u,ts)

genComp, genCompNeg :: Name -> Val -> Val -> System Val -> Val
genComp i a u ts | Map.null ts = trans i a u
genComp i a u ts = comp i ai1 (trans i a u) ts'
  where ai1 = a `face` (i ~> 1)
        j   = fresh (a,Atom i,ts,u)
        comp' alpha u = VPath i (trans j ((a `face` alpha) `disj` (i,j)) u)
        ts' = Map.mapWithKey comp' ts
genCompNeg i a u ts = genComp i (a `sym` i) u (ts `sym` i)

fill, fillNeg :: Name -> Val -> Val -> System Val -> Val
fill i a u ts = comp j a u (ts `conj` (i,j))
  where j = fresh (Atom i,a,u,ts)
fillNeg i a u ts = (fill i a u (ts `sym` i)) `sym` i

genFill, genFillNeg :: Name -> Val -> Val -> System Val -> Val
genFill i a u ts = genComp j (a `conj` (i,j)) u (ts `conj` (i,j))
  where j = fresh (Atom i,a,u,ts)
genFillNeg i a u ts = (genFill i (a `sym` i) u (ts `sym` i)) `sym` i

comps :: Name -> [(Ident,Ter)] -> Env -> [(System Val,Val)] -> [Val]
comps i []         _ []         = []
comps i ((x,a):as) e ((ts,u):tsus) =
  let v   = genFill i (eval e a) u ts
      vi1 = genComp i (eval e a) u ts
      vs  = comps i as (Pair e (x,v)) tsus
  in vi1 : vs
comps _ _ _ _ = error "comps: different lengths of types and values"

-- compNeg a u ts = comp a u (ts `sym` i)

-- i is independent of a and u
comp :: Name -> Val -> Val -> System Val -> Val
comp i a u ts | eps `Map.member` ts    = (ts ! eps) `face` (i ~> 1)
comp i a u ts | i `notElem` support ts = u
comp i a u ts | not (Map.null indep)   = comp i a u ts'
  where (ts',indep) = Map.partition (\t -> i `elem` support t) ts
comp i a u ts = let j = fresh (Atom i,a,u,ts) -- maybe only in vid??
                in case a of
  VIdP p _ _ -> VPath j $ comp i (p @@ j) (u @@ j) (Map.map (@@ j) ts)
  VSigma a f -> VSPair ui1 comp_u2
    where (t1s, t2s) = (Map.map fstVal ts, Map.map sndVal ts)
          (u1,  u2)  = (fstVal u, sndVal u)
          fill_u1    = fill i a u1 t1s
          ui1        = comp i a u1 t1s
          comp_u2    = genComp i (app f fill_u1) u2 t2s
  VPi{} -> VComp a u (Map.map (VPath i) ts)
  VU -> VComp VU u (Map.map (VPath i) ts)
  _ | isNeutral a || isNeutralSystem ts || isNeutral u ->
    VComp a u (Map.map (VPath i) ts)
  Ter (Sum _ _ nass) env -> case u of
    VCon n us -> case lookup n nass of
      Just as -> VCon n $ comps i as env tsus
        where tsus = transposeSystemAndList (Map.map unCon ts) us
      Nothing -> error $ "comp: missing constructor in labelled sum " ++ n
    _ -> error "comp ter sum"

-- fills :: Name -> [(Ident,Ter)] -> Env -> [(System Val,Val)] -> [Val]
-- fills i []         _ []         = []
-- fills i ((x,a):as) e ((ts,u):tsus) =
--   let v  = genFill i (eval e a) ts u
--       vs = fills i as (Pair e (x,v)) tsus
--   in v : vs
-- fills _ _ _ _ = error "fills: different lengths of types and values"


-------------------------------------------------------------------------------
-- | Conversion

isNeutralSystem :: System Val -> Bool
isNeutralSystem = any isNeutral . Map.elems

class Convertible a where
  conv :: Int -> a -> a -> Bool

isIndep :: (Nominal a, Convertible a) => Int -> Name -> a -> Bool
isIndep k i u = conv k u (u `face` (i ~> 0))

isCompSystem :: (Nominal a, Convertible a) => Int -> System a -> Bool
isCompSystem k ts = and [ conv k (getFace alpha beta) (getFace beta alpha)
                        | (alpha,beta) <- allCompatible (Map.keys ts) ]
    where getFace a b = face (ts ! a) (b `minus` a)

instance Convertible Val where
  conv k u v | u == v    = True
             | otherwise = let j = fresh (u,v) in case (u,v) of
    (Ter (Lam x a u) e,Ter (Lam x' a' u') e') ->
      let v = mkVar k (eval e a)
      in conv (k+1) (eval (Pair e (x,v)) u) (eval (Pair e' (x',v)) u')
    (Ter (Lam x a u) e,u') ->
      let v = mkVar k (eval e a)
      in conv (k+1) (eval (Pair e (x,v)) u) (app u' v)
    (u',Ter (Lam x a u) e) ->
      let v = mkVar k (eval e a)
      in conv (k+1) (app u' v) (eval (Pair e (x,v)) u)
    (Ter (Split p _ _) e,Ter (Split p' _ _) e') -> (p == p') && conv k e e'
    (Ter (Sum p _ _) e,Ter (Sum p' _ _) e')     -> (p == p') && conv k e e'
    (Ter (Undef p) e,Ter (Undef p') e')         -> (p == p') && conv k e e'
    (VPi u v,VPi u' v') ->
      let w = mkVar k u
      in conv k u u' && conv (k+1) (app v w) (app v' w)
    (VSigma u v,VSigma u' v') ->
      let w = mkVar k u
      in conv k u u' && conv (k+1) (app v w) (app v' w)
    (VCon c us,VCon c' us')   -> (c == c') && conv k us us'
    (VSPair u v,VSPair u' v') -> conv k u u' && conv k v v'
    (VSPair u v,w)            -> conv k u (fstVal w) && conv k v (sndVal w)
    (w,VSPair u v)            -> conv k (fstVal w) u && conv k (sndVal w) v
    (VFst u,VFst u')          -> conv k u u'
    (VSnd u,VSnd u')          -> conv k u u'
    (VApp u v,VApp u' v')     -> conv k u u' && conv k v v'
    (VSplit u v,VSplit u' v') -> conv k u u' && conv k v v'
    (VVar x _, VVar x' _)     -> x == x'
    (VIdP a b c,VIdP a' b' c') -> conv k a a' && conv k b b' && conv k c c'
    (VPath i a,VPath i' a')    -> conv k (a `swap` (i,j)) (a' `swap` (i',j))
    (VPath i a,p')             -> conv k (a `swap` (i,j)) (p' @@ j)
    (p,VPath i' a')            -> conv k (p @@ j) (a' `swap` (i',j))
    (VTrans p u,v) | isIndep k j (p @@ j) -> conv k u v
    (u,VTrans p v) | isIndep k j (p @@ j) -> conv k u v
    (VTrans p u,VTrans p' u') -> conv k p p' && conv k u u'
    (VAppFormula u x,VAppFormula u' x') -> conv k (u,x) (u',x')
    -- VComp
    _                         -> False

instance Convertible Env where
  conv k e e' =
    conv k (valAndFormulaOfEnv e) (valAndFormulaOfEnv e')

instance Convertible () where conv _ _ _ = True

instance (Convertible a, Convertible b) => Convertible (a, b) where
  conv k (u, v) (u', v') = conv k u u' && conv k v v'

instance (Convertible a, Convertible b, Convertible c)
      => Convertible (a, b, c) where
  conv k (u, v, w) (u', v', w') = conv k (u,(v,w)) (u',(v',w'))

instance (Convertible a,Convertible b,Convertible c,Convertible d)
      => Convertible (a,b,c,d) where
  conv k (u,v,w,x) (u',v',w',x') = conv k (u,v,(w,x)) (u',v',(w',x'))

instance Convertible a => Convertible [a] where
  conv k us us' = length us == length us' &&
                  and [conv k u u' | (u,u') <- zip us us']

instance Convertible Formula where
  conv _ phi psi = sort (invFormula phi 1) == sort (invFormula psi 1)
