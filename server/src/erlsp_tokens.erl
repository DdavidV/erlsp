-module(erlsp_tokens).

-export([
  module_attribute/1
]).

%% Reads Tokens' own -module(Name) attribute, wherever it appears.
-spec module_attribute(Tokens) -> Result when
  Tokens :: [erl_scan:token()],
  Result :: {ok, module()} | error.
module_attribute([{'-', _}, {atom, _, module}, {'(', _}, {atom, _, Module}, {')', _} | _Rest]) ->
  {ok, Module};
module_attribute([_Token | Rest]) ->
  module_attribute(Rest);
module_attribute([]) ->
  error.
