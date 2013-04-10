module CLaSH.Netlist where

import           Control.Lens            ((.=),_2)
import qualified Control.Lens            as Lens
import qualified Control.Monad           as Monad
import           Control.Monad.State     (runStateT)
import           Control.Monad.Writer    (runWriterT,listen)
import qualified Data.ByteString.Lazy.Char8 as LZ
import           Data.Either             (partitionEithers)
import           Data.HashMap.Lazy       (HashMap)
import qualified Data.HashMap.Lazy       as HashMap
import           Data.List               (elemIndex,nub)
import           Data.Maybe              (fromMaybe)
import qualified Data.Text.Lazy          as Text
import           Unbound.LocallyNameless (Embed(..),name2String,runFreshMT,unembed)

import CLaSH.Core.DataCon   (DataCon(..))
import CLaSH.Core.Literal   (Literal(..))
import CLaSH.Core.Prim      (Prim(..))
import qualified CLaSH.Core.Term as Core
import CLaSH.Core.Term      (Term(..),TmName)
import CLaSH.Core.Type      (Type)
import CLaSH.Core.Util      (collectArgs,isVar,termType)
import CLaSH.Core.Var       (Id,Var(..))
import CLaSH.Netlist.BlackBox
import CLaSH.Netlist.Id
import CLaSH.Netlist.Types as HW
import CLaSH.Netlist.Util
import CLaSH.Primitives.Types as P
import CLaSH.Util

genNetlist ::
  HashMap TmName (Type,Term)
  -> PrimMap
  -> TmName
  -> IO ([Component],VHDLState)
genNetlist globals primMap topEntity = do
  (_,s) <- runNetlistMonad globals primMap $ genComponent topEntity Nothing
  return $ (HashMap.elems $ _components s, _vhdlMState s)

runNetlistMonad ::
  HashMap TmName (Type,Term)
  -> PrimMap
  -> NetlistMonad a
  -> IO (a,NetlistState)
runNetlistMonad s p
  = runFreshMT
  . (flip runStateT) s'
  . (fmap fst . runWriterT)
  . runNetlist
  where
    s' = NetlistState s HashMap.empty 0 0 HashMap.empty p (0,Text.empty,HashMap.empty)

genComponent ::
  TmName
  -> Maybe Integer
  -> NetlistMonad Component
genComponent compName mStart = do
  compExprM <- fmap (HashMap.lookup compName) $ Lens.use bindings
  case compExprM of
    Nothing -> error "no normalized expression found"
    Just (_,expr) -> makeCached compName components $
                      genComponent' compName expr mStart

genComponent' ::
  TmName
  -> Term
  -> Maybe Integer
  -> NetlistMonad Component
genComponent' compName componentExpr mStart = do
  varCount .= fromMaybe 0 mStart
  componentNumber <- cmpCount <%= (+1)

  let componentName' = (`Text.append` (Text.pack $ show componentNumber))
                     . ifThenElse Text.null
                          (`Text.append` (Text.pack "Component_"))
                          (`Text.append` (Text.pack "_"))
                     . mkBasicId
                     . Text.pack
                     $ name2String compName

  (vhdlMState . _2) .= componentName'

  (arguments,binders,result) <- splitNormalized componentExpr >>=
                                mkUniqueNormalized

  let ids = HashMap.fromList
          $ map (\(Id v (Embed t)) -> (v,t))
          $ arguments ++ (map fst binders)

  gamma <- (ids `HashMap.union`) . (HashMap.map fst)
           <$> Lens.use bindings

  varEnv .= gamma

  let resType  = coreTypeToHWType_fail $ ids HashMap.! result
  let argTypes = map (\(Id _ (Embed t)) -> coreTypeToHWType_fail t) arguments

  let netDecls = map (\(id_,_) ->
                        NetDecl (mkBasicId . Text.pack . name2String $ varName id_)
                                (coreTypeToHWType_fail . unembed $ varType id_)
                                Nothing
                     ) $ filter ((/= result) . varName . fst) binders
  (decls,clks) <- listen $ concat <$> mapM (uncurry mkConcSm . second unembed) binders

  let compInps       = zip (map (Text.pack . name2String . varName) arguments) argTypes
  let compOutp       = (Text.pack $ name2String result, resType)
  let component      = Component componentName' (nub clks) compInps compOutp (netDecls ++ decls)
  return component

mkConcSm ::
  Id
  -> Term
  -> NetlistMonad [Declaration]
mkConcSm bndr (Var _ v) = mkApplication bndr v []

mkConcSm bndr (Data dc) = mkDcApplication bndr dc []

mkConcSm bndr app@(App _ _) = do
  let (appF,(args,tyArgs)) = second partitionEithers $ collectArgs app
  args' <- Monad.filterM (fmap representableType . termType) args
  case appF of
    Var _ f
      | all isVar args' && null tyArgs -> mkApplication bndr f args'
      | otherwise                      -> error "Not in normal form: Var-application with non-Var arguments"
    Data dc
      | all isVar args' -> mkDcApplication bndr dc args'
      | otherwise       -> error "Not in normal form: DataCon-application with non-Var arguments"
    Prim (PrimFun nm _) -> do
      bbM <- fmap (HashMap.lookup . LZ.pack $ name2String nm) $ Lens.use primitives
      case bbM of
        Just p@(P.BlackBox {}) -> do
          bbCtx <- mkBlackBoxContext bndr args
          mkBlackBoxDecl (template p) bbCtx
        _ -> error $ "No blackbox found: " ++ show bbM
    _ -> error $ "Not in normal form: application of a Let/Lam/Case" ++ show app

mkConcSm bndr (Core.Literal lit) = do
  let dstId = mkBasicId . Text.pack . name2String $ varName bndr
  let bndrHWType = coreTypeToHWType_fail . unembed $ varType bndr
  let i = case lit of
            (IntegerLiteral i') -> i'
            _ -> error "not an integer literal"
  return [Assignment dstId Nothing bndrHWType
           [HW.Literal Nothing . NumLit $ fromInteger i]
         ]

mkConcSm _ e = error $ "Not in normal form: let-bound expr is a Let or TyApp: " ++ show e

mkApplication ::
  Id
  -> TmName
  -> [Term]
  -> NetlistMonad [Declaration]
mkApplication dst fun args = do
  normalized <- Lens.use bindings
  case HashMap.lookup fun normalized of
    Just _ -> do
      vCnt <- Lens.use varCount
      vEnv <- Lens.use varEnv
      cN   <- Lens.use (vhdlMState . _2)
      (Component compName hidden compInps compOutp _) <- genComponent fun Nothing
      varCount .= vCnt
      varEnv .= vEnv
      (vhdlMState . _2) .= cN
      case length args == length compInps of
        True  -> do
          let dstId = mkBasicId . Text.pack . name2String $ varName dst
          let args' = map varToExpr args
          let hiddenAssigns = map (\(i,_) -> (i,Identifier i Nothing)) hidden
          let inpAssigns = zip (map fst compInps) args'
          let outpAssign = (fst compOutp,Identifier dstId Nothing)
          let instDecl = InstDecl compName dstId (outpAssign:hiddenAssigns ++ inpAssigns)
          return [instDecl]
        False -> error "under-applied normalized function"
    Nothing -> case args of
      [] -> do
        let dstId     = mkBasicId . Text.pack . name2String $ varName dst
        let dstHWType = coreTypeToHWType_fail . unembed $ varType dst
        return [Assignment dstId Nothing dstHWType [Identifier (mkBasicId . Text.pack $ name2String fun) Nothing]]
      _ -> error "Unknown function"

mkDcApplication ::
  Id
  -> DataCon
  -> [Term]
  -> NetlistMonad [Declaration]
mkDcApplication dst dc args = do
  let dstHType = coreTypeToHWType_fail . unembed $ varType dst
  let dstId    = mkBasicId . Text.pack . name2String $ varName dst
  case dstHType of
    SP _ dcArgPairs -> do
      let dcNameBS = Text.pack . name2String $ dcName dc
      let dcI      = fromMaybe (error "SP: dc not found") $ elemIndex dcNameBS $ map fst dcArgPairs
      let argTys   = snd $ dcArgPairs !! dcI
      nonEmptyArgs <- fmap (map varToExpr) $ Monad.filterM
                        (return . not . isEmptyType <=< termHWType) args
      case (compare (length argTys) (length nonEmptyArgs)) of
        EQ -> return [Assignment dstId (Just $ DC dcI) dstHType nonEmptyArgs]
        LT -> error "Over-applied constructor"
        GT -> error "Under-applied constructor"
    Product _ dcArgs -> do
      nonEmptyArgs <- fmap (map varToExpr) $ Monad.filterM
                        (return . not . isEmptyType <=< termHWType) args
      case (compare (length dcArgs) (length nonEmptyArgs)) of
        EQ -> return [Assignment dstId (Just $ DC 0) dstHType nonEmptyArgs]
        LT -> error "Over-applied constructor"
        GT -> error "Under-applied constructor"
    Sum _ dcs -> do
      let dcNameBS = Text.pack . name2String $ dcName dc
      let dcI = fromMaybe (error "Sum: dc not found") $ elemIndex dcNameBS dcs
      return [Assignment dstId (Just $ DC dcI) dstHType []]
    Bool -> do
      let dc' = case (name2String $ dcName dc) of
                 "True"  -> [HW.Literal Nothing (BoolLit True)]
                 "False" -> [HW.Literal Nothing (BoolLit False)]
                 _ -> error $ "unknown bool literal: " ++ show dc
      return [Assignment dstId Nothing dstHType dc']
    Bit -> do
      let dc' = case (name2String $ dcName dc) of
                 "H" -> [HW.Literal Nothing (BitLit H)]
                 "L" -> [HW.Literal Nothing (BitLit L)]
                 _ -> error $ "unknown bit literal: " ++ show dc
      return [Assignment dstId Nothing dstHType dc']
    _ -> error $ "mkDcApplication undefined: " ++ show dstHType
