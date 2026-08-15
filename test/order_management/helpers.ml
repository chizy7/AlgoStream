module Order = Algostream_domain_orders.Order
module Order_book = Algostream_domain_market.Order_book

let make_order ?(quantity = 1000.0) ?(side = Order.Buy) ?(order_type = Order.Market)
  ?(exchange = "test_venue") () =
  Order.create_order ~id:"oid-1" ~client_order_id:"cid-1" ~symbol:"BTCUSDT" ~side ~order_type
    ~quantity ~time_in_force:Order.Immediate_or_cancel ~exchange ()


let make_level ~price ~size = Order_book.Price_level.{ price; size; orders = 1 }

let make_book ?(symbol = "BTCUSDT") ?(bids = [||]) ?(asks = [||]) () =
  Order_book.create_order_book ~symbol
    ~timestamp:(Algostream_domain_common.Timestamp.now ())
    ~sequence:0L ~bids ~asks
