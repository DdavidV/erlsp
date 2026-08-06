-module(hover_edoc_fixture).

-export([legacy_documented/1]).

%% Doubles its argument, documented the legacy EDoc-comment way.
%% Second line of the same comment block.
-spec legacy_documented(Number) -> Result when
  Number :: integer(),
  Result :: integer().
legacy_documented(Number) ->
  Number * 2.
