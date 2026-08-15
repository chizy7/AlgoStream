type t =
  | Anonymous
  | Key of {
      kid : string;
      label : string;
      scopes : Scope.Set.t;
    }

let kid = function Anonymous -> "-" | Key k -> k.kid

let label = function Anonymous -> "anonymous" | Key k -> k.label

let scopes = function Anonymous -> Scope.Set.empty | Key k -> k.scopes

let has t scope = Scope.satisfies ~granted:(scopes t) ~required:scope

let to_assoc t = [ ("kid", kid t); ("label", label t); ("scopes", Scope.Set.to_string (scopes t)) ]

let to_string t = Printf.sprintf "%s (%s)" (kid t) (Scope.Set.to_string (scopes t))
