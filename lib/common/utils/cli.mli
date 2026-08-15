(** Shared argument-vector handling for the [bin/] entry points.

    Every binary here parses [Sys.argv] with a hand-rolled loop that matches flag names exactly and
    takes the following element as the value. That accepts [--http-port 8080] and rejects
    [--http-port=8080], which is the other conventional spelling and the one Kubernetes manifests,
    systemd units and compose files are usually written in.

    The cost of that gap was concrete: the manifests in [k8s/] used the [=] form throughout, passed
    [kubectl --dry-run] and [kubeconform] — neither of which knows what the container's arguments
    mean — and failed at container start with [unknown argument --http-host=0.0.0.0]. Nothing caught
    it until the manifests were applied to a real cluster. *)

(** Rewrite [--flag=value] into [--flag; value], leaving everything else untouched.

    Splits on the {i first} [=] only, so a value containing one — a path, a query string, a base64
    payload — survives intact. Tokens that do not begin with [--] pass through unchanged, so a
    positional argument containing [=] is not mangled. [--] itself, and a leading [--=], are left
    alone rather than producing an empty flag name. *)
val expand_equals : string array -> string array
