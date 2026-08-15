let expand_equals argv =
  Array.to_list argv
  |> List.concat_map (fun tok ->
       if String.length tok > 2 && String.sub tok 0 2 = "--" then
         match String.index_opt tok '=' with
         | Some k when k > 2 ->
           [ String.sub tok 0 k; String.sub tok (k + 1) (String.length tok - k - 1) ]
         | _ -> [ tok ]
       else [ tok ])
  |> Array.of_list
