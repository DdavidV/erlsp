-module(hover_nodoc_fixture).

-export([undocumented/1]).

-spec undocumented(Number) -> Result when
  Number :: integer(),
  Result :: integer().
undocumented(Number) ->
  Number * 2.
