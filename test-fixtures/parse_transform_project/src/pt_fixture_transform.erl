-module(pt_fixture_transform).

-export([parse_transform/2]).

%% Identity transform - deliberately does nothing to Forms. It only needs
%% to exist and be a real, loadable parse_transform/2 export so that
%% pt_fixture_user.erl's -compile({parse_transform, pt_fixture_transform})
%% has something real to resolve against.
-spec parse_transform(Forms, Options) -> Forms when
  Forms :: [erl_parse:abstract_form()],
  Options :: [compile:option()].
parse_transform(Forms, _Options) ->
  Forms.
