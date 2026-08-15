module RB = Algostream_common_utils.Data_structures.RingBuffer

type 'a t = { bands : 'a RB.t array }

let create ~capacity_per_band ~dummy =
  let bands =
    Array.init Event_types.Priority.num_bands (fun _ -> RB.create ~capacity:capacity_per_band dummy)
  in
    { bands }


let try_push t priority value =
  let i = Event_types.Priority.to_int priority in
    RB.try_push t.bands.(i) value


let try_pop t =
  let rec loop i =
    if i >= Array.length t.bands then None
    else
      match RB.try_pop t.bands.(i) with
      | Some v -> Some (v, Event_types.Priority.of_int_exn i)
      | None -> loop (i + 1) in
    loop 0


let size t = Array.fold_left (fun acc rb -> acc + RB.size rb) 0 t.bands

let is_empty t = Array.for_all RB.is_empty t.bands

let depth_per_band t = Array.map RB.size t.bands
