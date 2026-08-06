-module(hover_doc_fixture).

-moduledoc "A fixture module documented with the modern -doc/-moduledoc attributes.".

-export([documented/1]).
-export_type([documented_type/0]).

-doc "A type documented with -doc.".
-type documented_type() :: ok | error.

-doc "Doubles its argument.".
-spec documented(Number) -> Result when
  Number :: integer(),
  Result :: integer().
documented(Number) ->
  Number * 2.
