type subscription_id = int

module Filter = struct
  type t = Event_types.Event.t -> bool

  let any _ = true

  let by_priority p e = Event_types.Priority.compare e.Event_types.Event.priority p = 0

  let min_priority p e =
    Event_types.Priority.to_int e.Event_types.Event.priority <= Event_types.Priority.to_int p


  let by_source s e = String.equal e.Event_types.Event.source s

  let by_message_type code e =
    Int32.equal (Event_types.Event.message_type_of_payload e.Event_types.Event.payload) code


  let by_symbol s e =
    match Event_types.Event.symbol_of_payload e.Event_types.Event.payload with
    | Some sym -> String.equal sym s
    | None -> false


  let and_ a b e = a e && b e

  let or_ a b e = a e || b e

  let not_ a e = not (a e)

  let custom f = f

  let matches f e = f e
end

type t = {
  id : subscription_id;
  filter : Filter.t;
  handler : Event_types.Event.t -> unit;
}

let create ~id ~filter ~handler = { id; filter; handler }

module Id_allocator = struct
  type t = int Atomic.t

  let create () = Atomic.make 0

  let rec next t =
    let cur = Atomic.get t in
    let n = cur + 1 in
      if Atomic.compare_and_set t cur n then n else next t
end

let id_to_int id = id
