(** Tabular export: CSV and JSON from one column description.

    {1 Why quoting matters here}

    The CSV writers that already existed ([Backtest.Result.write_blotter_csv]) emit [strategy_id]
    and [tag] with a bare [%s]. Both are strategy-supplied free text — [tag] exists precisely so a
    fill can be traced back to the reason it was placed — so a comma or a newline in either silently
    corrupts the file, shifting every later column by one. This module quotes properly, per RFC
    4180: a field containing a comma, a double quote, CR or LF is wrapped in quotes with internal
    quotes doubled.

    {1 Not xlsx}

    Excel export is {b not implemented}. A real [.xlsx] is a ZIP container of OOXML parts, which is
    a meaningful amount of machinery for a format Excel opens from CSV anyway. It is listed as a
    deferral rather than quietly dropped. *)

type value =
  | S of string
  | F of float  (** non-finite values render as an empty CSV cell and JSON [null] *)
  | I of int
  | I64 of int64
  | B of bool

type column = {
  header : string;
  extract : unit -> value;  (** re-evaluated per row by {!rows_of} *)
}

(** Quote one field for CSV. Exposed because [Backtest.Result] needs the same rule without taking a
    dependency on this library. *)
val csv_escape : string -> string

val value_to_csv : value -> string

(** [to_csv ~headers ~rows] — [rows] are already-extracted values, one list per row. *)
val to_csv : headers:string list -> rows:value list list -> string

(** Same data as a JSON array of objects. Keys come from [headers]; non-finite floats become [null],
    so the output is always parseable. *)
val to_json : headers:string list -> rows:value list list -> string

type format =
  | Csv
  | Json

val format_of_string : string -> (format, string) result

val format_to_string : format -> string

val content_type : format -> string

val render : format -> headers:string list -> rows:value list list -> string

(** Write to a path, creating or truncating. *)
val to_file : string -> format -> headers:string list -> rows:value list list -> unit
