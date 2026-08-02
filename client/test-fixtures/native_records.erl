-module(native_records).

-export([make_vec/2]).
-export_record([vec]).
-import_record(geom, [point]).

-record #vec{x = 0.0, y = 0.0}.

make_vec(X, Y) ->
  V = #vec{x = X, y = Y},
  W = #geom:vec{x = 0.0, y = 0.0},
  A = V#vec.x,
  B = W#geom:vec.y,
  C = V#_.x,
  V.
