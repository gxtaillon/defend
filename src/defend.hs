import Paths_DefendTheKing (getDataFileName)
import Chess
import Font
import GameLogic
import Geometry
import NetEngine
import NetMatching
import Networking
import UI

import Control.Applicative (Applicative(..))
import Control.Monad (forM, join, when, unless)
import Data.Foldable (foldl', forM_)
import Data.Char (toLower)
import Data.List.Class (filter)
import Data.Map ((!))
import Data.Monoid
import Data.Time.Clock
import FRP.Peakachu
import FRP.Peakachu.Backend.GLUT
import FRP.Peakachu.Backend.Time
import Graphics.UI.GLUT
import System.Random (randomRIO)

import Prelude hiding (filter)

type Timer = EffectFunc Timeout ()

data DefEnv = DefEnv
  { defClientId :: Integer
  , defFont :: DefendFont
  , defSock :: PeakaSocket
  , defHttp :: EffectFunc String (Maybe String) ()
  , defSrvRetryTimer :: Timer ()
  , defGameIterTimer :: Timer ()
  , defTransmitTimer :: Timer ()
  }

piecePix :: DefendFont -> PieceType -> Pix
piecePix font x = font ! map toLower (show x)

screen2board :: DrawPos -> BoardPos
screen2board (cx, cy) =
  (r cx, r cy)
  where
    r ca = round (4 * ca + 3.5)

board2screen :: BoardPos -> DrawPos
board2screen (bx, by) =
  (r bx, r by)
  where
    r ba = (fromIntegral ba - 3.5) / 4

type Selection = (BoardPos, Maybe BoardPos)

glStyle :: IO ()
glStyle = do
  cursor $= None
  lineSmooth $= Enabled
  polygonSmooth $= Enabled
  hint LineSmooth $= Nicest
  hint PolygonSmooth $= Nicest
  blend $= Enabled

draw :: DefEnv -> (Board, (Selection, DrawPos)) -> Image
draw env (board, ((dragSrc, dragDst), (cx, cy))) =
  Image $ do
    glStyle
    blendFunc $= (SrcAlpha, OneMinusSrcAlpha)
    lighting $= Enabled
    light (Light 0) $= Enabled
    position (Light 0) $= Vertex4 0 0 (-1) 0
    cullFace $= Just Front
    drawBoard
    mapM_ drawPiece . filter ((`elem` vis) . piecePos) $ boardPieces board
    when (srcFirst dragDst) $ drawCursor dragSrc
    forM_ dragDst drawCursor
    unless (srcFirst dragDst) $ drawCursor dragSrc
  where
    font = defFont env
    me
      | 0 == defClientId env `mod` 2 = Black
      | otherwise = White
    srcFirst Nothing = True
    srcFirst (Just dst) = cursorDist dragSrc < cursorDist dst
    cursorDist = cursorDist' . board2screen
    cursorDist' (x, y) = (cx-x)^(2::Int) + (cy-y)^(2::Int)
    headingUp = normal $ Normal3 0 0 (-1 :: GLfloat)
    drawPiece piece = do
      let
        pix = piecePix font (pieceType piece)
        (px, py) = piecePos piece
        (sx, sy) = board2screen (px, py)
        white :: Color4 GLfloat
        white = Color4 1 1 1 1
        black = Color4 0 0 0 1
        (bodyCol, outlineCol)
          | pieceSide piece == White = (white, black)
          | otherwise = (black, white)
        vert m (vx, vy) =
          vertex $ Vertex4
            (sx + m*vx)
            (sy + m*vy) 0 1
      headingUp
      materialDiffuse Front $= bodyCol
      renderPrimitive Triangles .
        forM (pixBody pix) .
        mapM $ vert (pieceSize * 0.125)
      materialDiffuse Front $= outlineCol
      renderPrimitive Quads .
        forM (pixOutline pix) $ \outline ->
        forM (polygonEdges
          (zip outline (expandPolygon (-0.06) outline))) $
          \((a, b), (c, d)) ->
          forM [c, d, b, a] . vert $ pieceSize * 0.125
    pieceSize = 0.9
    vis = visibleSquares me board
    drawBoard =
      forM_ vis $ \(bx, by) -> do
        let
          col = 0.3 + 0.1 * fromIntegral ((bx + by) `mod` 2)
          r ba va = 0.125*((fromIntegral ba*2+va)-7)
        materialDiffuse Front $= Color4 col col col 1
        headingUp
        renderPrimitive Quads .
          forM square $ \(vx, vy) ->
            vertex $ Vertex4 (r bx vx) (r by vy) 0 1
    drawCursor boardPos = do
      cullFace $= Just Back
      drawCursor' boardPos
      cullFace $= Just Front
      drawCursor' boardPos
    drawCursor' boardPos =
      renderPrimitive Triangles .
      forM_ curPix $ \part ->
      forM_ (polygonEdges part) $
      \((ax, ay), (bx, by)) -> do
        let
          (rx, ry) = board2screen boardPos
          points =
            [[0.9*cx, 0.9*cy, 0.9]
            ,[rx + 0.125*ax, ry + 0.125*ay, 1]
            ,[rx + 0.125*bx, ry + 0.125*by, 1]
            ]
          norml = faceNormal points
          [nx, ny, nz]
            | last norml < 0 = norml
            | otherwise = map negate norml
        normal $ Normal3 nx ny nz
        materialDiffuse Front $=
          case pieceUnderCursor of
            Nothing -> Color4 1 1 0 0.5
            _ -> Color4 0 1 0 1
        forM_ (take 1 points) $ \[px, py, pz] ->
          vertex $ Vertex4 px py 0 pz
        materialDiffuse Front $=
          case pieceUnderCursor of
            Nothing -> Color4 1 1 0 0
            _ -> Color4 0 1 0 0.5
        forM_ (tail points) $ \[px, py, pz] ->
          vertex $ Vertex4 px py 0 pz
    pieceUnderCursor =
      filter ((== me) . pieceSide) $
      pieceAt board dragSrc
    curPix =
      case pieceUnderCursor of
        Nothing -> [square]
        Just p -> map (map t) . pixOutline . piecePix font $ pieceType p
      where
        t (x, y) = (pieceSize*x, pieceSize*y)
    square = [((-1), (-1)), ((-1), 1), (1, 1), (1, (-1))]

maybeMinimumOn :: Ord b => (a -> b) -> [a] -> Maybe a
maybeMinimumOn f =
  foldl' maybeMin Nothing
  where
    maybeMin Nothing x = Just x
    maybeMin (Just x) y
      | f y < f x = Just y
      | otherwise = Just x

chooseMove :: Board -> BoardPos -> DrawPos -> Maybe (BoardPos, Board)
chooseMove board src (dx, dy) =
  join .
  fmap (maybeMinimumOn (dist . fst) . possibleMoves board) $
  pieceAt board src
  where
    dist pos =
      (px-dx)^(2::Int) + (py-dy)^(2::Int)
      where
        (px, py) = board2screen pos

setTimerTime :: Timeout -> Timer a -> EffectFunc () () a
setTimerTime time timer =
  EffectFunc
  { efRun = efRun timer . fmap f
  , efOut = efOut timer
  }
  where
    f ((), x) = (time, x)

game :: DefEnv -> UI -> (Event Image, SideEffect)
game env ui =
  (image, effect)
  where
    drag (Down, (x, _)) (Down, c) =
      (Down, (x, Just c))
    drag _ (s, c) =
      (s, (spos, dst))
      where
        spos = screen2board c
        dst
          | s == Up = Nothing
          | otherwise = Just c
    selectionRaw =
      edrop (1::Int) .
      escanl drag (Up, undefined) $
      ezip (keyState (MouseButton LeftButton) ui) (mouseMotionEvent ui)
    neo = netEngine $ NetEngineInput
      { neiLocalMoveUpdates = fmap (:) queuedMoves
      , neiPeerId = defClientId env
      , neiSocket = defSock env
      , neiNewPeerAddrs = matchingAddrs
      , neiIterTimer = setTimerTime 50 (defGameIterTimer env)
      , neiTransmitTimer = setTimerTime 20 (defTransmitTimer env)
      }
    (matchingAddrs, matchingEffects) =
      netMatching (defSock env) (defHttp env)
      (setTimerTime 1000 (defSrvRetryTimer env))
      (neoIsConnected neo)
    board = escanl doMove chessStart . eFlatten . neoMove $ neo
    procDst brd src = join . fmap (chooseMove brd src)
    doMove brd (src, dst) =
      case procDst brd src dst of
        Nothing -> brd
        Just r -> snd r
    selection =
      fmap proc .
      ezip board $
      fmap snd selectionRaw
      where
        proc (brd, (src, dst)) =
          (src, fmap fst (procDst brd src dst))
    moveFilter ((Down, _), (Up, _)) = True
    moveFilter _ = False
    queuedMoves =
      fmap (snd . fst) .
      efilter moveFilter $
      eWithPrev selectionRaw
    image = fmap (draw env) .
      ezip board .
      ezip selection .
      mouseMotionEvent $ ui
    effect = mconcat
      [ neoSideEffect neo
      , matchingEffects
      ]

zipRelTime :: Event a -> Event (NominalDiffTime, a)
zipRelTime =
  fmap f .
  edrop (1 :: Int) .
  escanl step Nothing .
  zipTime
  where
    step Nothing (startTime, x) =
      Just (startTime, startTime, x)
    step (Just (startTime, _, _)) (now, x) =
      Just (startTime, now, x)
    f v =
      (diffUTCTime now startTime, x)
      where
        Just (startTime, now, x) = v

relTimeOf :: Event a -> Event NominalDiffTime
relTimeOf = fmap fst . zipRelTime

renderText :: DefendFont -> String -> [[DrawPos]]
renderText font text =
  concat . zipWith doLine lns $ zip rowCenters rowHeights
  where
    lns = lines text
    rowHeights = map ((2 /) . fromIntegral . length) lns
    top = sum rowHeights / 2
    rowTops = scanl (-) top rowHeights
    rowCenters = zipWith (flip (-) . (/ 2)) rowHeights rowTops
    doLine line (mid, size) =
      concat $ zipWith doLetter [(0 :: Int) ..] line
      where
        doLetter _ ' ' = []
        doLetter off letter =
          map (map (trans size (size * fromIntegral (2 * off + 1 - length line) / 2, mid))) . pixBody $ font ! [letter]
    trans s (dx, dy) (sx, sy) = (dx+s*sx/2, dy+s*sy/2)

intro :: DefendFont -> UI -> Event Image
intro font =
  fmap frame . relTimeOf
  where
    frame t =
      Image $ do
        glStyle
        lighting $= Disabled
        blendFunc $= (SrcAlpha, OneMinusSrcAlpha)
        color $ Color4 0 0 0 (max 0 (4-f*0.3))
        renderPrimitive Quads .
          forM_ [(-1, -1), (-1, 1), (1, 1), (1, -1)] $ \(x, y) ->
            vertex $ Vertex4 x y (0 :: Float) 1
        blendFunc $= (SrcAlpha, One)
        color $ Color4 1 0.5 0.25 (1 - abs (0.5+f*0.1-1))
        renderPrimitive Triangles .
          forM_ (expandPolygon e =<< renderText font "defend\nthe king\nfrom forces\nof different") $ \(x, y) ->
            vertex $ Vertex4 x y 0 (3-f/5)
      where
        f :: GLfloat
        f = 5 * realToFrac t
        e' = f/90-0.1
        e = min e' 0 + max (e'-0.02) 0

prog :: DefEnv -> UI -> (Event Image, SideEffect)
prog env = do
  (gameImage, gameEffect) <- game env
  introImage <- intro $ defFont env
  drawTime <- drawingTime 0.1
  let
    image =
      runEventZip $
      EventZip gameImage `mappend`
      EventZip introImage
    imageSamp =
      fmap snd $ eZipByFst drawTime image
  return (imageSamp, gameEffect)

-- more options at http://www.voip-info.org/wiki/view/STUN
stunServer :: String
stunServer = "stun.ekiga.net"

initEnv :: IO DefEnv
initEnv = do
  pure DefEnv
    <*> randomRIO (0, 2^(128::Int))
    <*> (fmap loadFont . readFile =<< getDataFileName "data/defend.font")
    <*> mkPeakaSocket stunServer
    <*> httpGet
    <*> setTimerEvent
    <*> setTimerEvent
    <*> setTimerEvent

main :: IO ()
main = do
  initialWindowSize $= Size 600 600
  initialDisplayCapabilities $=
    [With DisplayRGB
    ,Where DisplaySamples IsAtLeast 2
    ]
  initEnv >>= run . prog

