module Main where

import Control.Coroutine (Producer, ($$), ($~))
import Control.Coroutine.Stalling (StallingProducer, stallF, emit, producerToStallingProducer)
import Control.Monad.Aff (Aff)
import Control.Monad.Aff.CouchDB.ChangeNotification as ChangeNotification
import Control.Monad.Aff.Free (class Affable)
import Control.Monad.Eff (Eff)
import Control.Monad.Free.Trans as FT
import Control.Monad.Rec.Class (class MonadRec, tailRecM)
import Control.Monad.Trans as TR
import Control.Parallel.Class (class MonadPar)
import Data.Argonaut ((.?), (:=), (~>), jsonEmptyObject)
import Data.Argonaut.Decode (class DecodeJson, decodeJson)
import Data.Argonaut.Encode (class EncodeJson, encodeJson)
import Data.Array as Array
import Data.Either as E
import Data.Functor (($>))
import Data.Maybe (Maybe(..))
import Data.String as String
import Data.Traversable (class Traversable, traverse)
import Halogen as H
import Halogen.HTML.Events.Indexed as HE
import Halogen.HTML.Indexed as HH
import Halogen.Query.EventSource as EventSource
import Halogen.Util (runHalogenAff, awaitBody)
import Network.HTTP.Affjax (AJAX, post_)
import Prelude

type State = { orders :: Array (Array Item), interface :: Interface, order :: Array Item }

data Item = Shake | Burger | Fries

data Interface = Till | Kitchen

instance eqItem :: Eq Item where
  eq Shake Shake = true
  eq Burger Burger = true
  eq Fries Fries = true
  eq _ _ = false

instance showItem :: Show Item where
  show Shake = "Shake"
  show Burger = "Burger"
  show Fries = "Fries"

instance decodeItem :: DecodeJson Item where
  decodeJson = decodeJson >=> case _ of
    "Shake" -> pure Shake
    "Burger" -> pure Burger
    "Fries" -> pure Fries
    _ -> E.Left "Invalid Item"

instance encodeItem :: EncodeJson Item where
  encodeJson = encodeJson <<< show

instance encodeQuery :: EncodeJson (Query Unit) where
  encodeJson (FulfillOrder order _) =
    "tag" := "FulfillOrder" ~> "order" := encodeJson order ~> jsonEmptyObject
  encodeJson (PlaceOrder order _) =
    "tag" := "PlaceOrder" ~> "order" := encodeJson order ~> jsonEmptyObject
  encodeJson _ = encodeJson unit

instance decodeQuery :: DecodeJson (Query Unit) where
  decodeJson = decodeJson >=> \obj -> do
    obj .? "tag" >>= case _ of
      "PlaceOrder" -> do
        order <- obj .? "order"
        pure $ PlaceOrder order unit
      "FulfillOrder" -> do
        order <- obj .? "order"
        pure $ FulfillOrder order unit
      _ -> E.Left "Invalid query"

data Query a
  = Init a
  | AddToOrder Item a
  | ClearOrder a
  | FulfillOrder (Array Item) a
  | PlaceOrder (Array Item) a
  | SwitchInterface a
  | SendFulfillOrder (Array Item) a
  | SendPlaceOrder (Array Item) a

type AppEffects eff = H.HalogenEffects (ajax :: AJAX | eff)

dbUri :: String
dbUri = "http://127.0.0.1:5984/burger-barn"

initialState :: State
initialState = { orders: [], interface: Till, order: [] }
switchInterface :: Interface -> Interface
switchInterface Kitchen = Till
switchInterface Till = Kitchen

ui :: forall eff. H.Component State Query (Aff (AppEffects eff))
ui =
  H.lifecycleComponent { initializer: Just (H.action Init), finalizer: Nothing, render, eval }
  where
  render :: State -> H.ComponentHTML Query
  render st =
    case st.interface of
      Kitchen ->
        HH.div_ $
          [ HH.h1
              [ HE.onClick (HE.input_ SwitchInterface) ]
              [ HH.text "Burger Barn Kitchen" ]
          , HH.h2_
              [ HH.text "Orders" ]
          , HH.p_ (renderOrder <$> st.orders)
          ]
      Till ->
        HH.div_ $
          [ HH.h1
              [ HE.onClick (HE.input_ SwitchInterface) ]
              [ HH.text "Burger Barn Till" ]
          , HH.h2_
              [ HH.text $ String.joinWith ", " $ show <$> st.order ]
          , HH.p_
              [ renderItem Shake, renderItem Burger, renderItem Fries ]
          , HH.button
              [ HE.onClick (HE.input_ ClearOrder) ]
              [ HH.text "Clear Order" ]
          , HH.button
              [ HE.onClick (HE.input_ $ SendPlaceOrder st.order) ]
              [ HH.text "Place Order" ]
          ]

  renderOrder :: Array Item -> H.ComponentHTML Query
  renderOrder order =
    HH.button
      [ HE.onClick (HE.input_ $ SendFulfillOrder order) ]
      [ HH.text $ String.joinWith ", " $ show <$> order ]

  renderItem :: Item -> H.ComponentHTML Query
  renderItem item =
    HH.button
      [ HE.onClick (HE.input_ $ AddToOrder item) ]
      [ HH.text $ show item ]


  produceQueries :: forall m. (Affable (AppEffects eff) m, Functor m, MonadRec m, MonadPar m) => Producer (Array (Query Unit)) m Unit
  produceQueries = ChangeNotification.produceChangedDocs dbUri 0

  eval :: Query ~> H.ComponentDSL State Query (Aff (AppEffects eff))
  eval (Init next) =
    (H.subscribe $ EventSource.EventSource $ flatten $ producerToStallingProducer produceQueries)
      $> next
  eval (AddToOrder item next) =
    H.modify (\st -> st { order = [item] <> st.order }) $> next
  eval (ClearOrder next) =
    H.modify (_ { order = [] }) $> next
  eval (FulfillOrder order next) =
    H.modify (\st -> st { orders = Array.delete order st.orders }) $> next
  eval (PlaceOrder order next) =
    H.modify (\st -> st { orders = [order] <> st.orders }) $> next
  eval (SwitchInterface next) =
    H.modify (\st -> st { interface = switchInterface st.interface }) $> next
  eval (SendFulfillOrder order next) =
    (H.fromAff $ post_ dbUri (encodeJson $ FulfillOrder order unit)) $> next
  eval (SendPlaceOrder order next) =
    (H.fromAff $ post_ dbUri (encodeJson $ PlaceOrder order unit))
      *> H.modify (_ { order = [] })
      $> next

main :: Eff (AppEffects ()) Unit
main = runHalogenAff do
  body <- awaitBody
  H.runUI ui initialState body

flatten
  :: forall o m a t
   . (Traversable t, MonadRec m)
  => StallingProducer (t o) m a
  -> StallingProducer o m a
flatten =
  tailRecM $
    FT.resume >>> TR.lift >=>
      E.either
        (E.Right >>> pure)
        (stallF
          (\mo t -> traverse emit mo $> E.Left t)
          (E.Left >>> pure))
