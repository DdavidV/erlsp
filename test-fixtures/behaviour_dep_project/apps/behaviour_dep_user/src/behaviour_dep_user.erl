-module(behaviour_dep_user).

%% Implements a BEHAVIOUR DEFINED IN A SIBLING APP (dep_a, listed as a
%% dependency in this app's own .app.src) - exercises the stale-profile-
%% shadowing bug: erl_lint calls dep_a_behaviour:behaviour_info/1 as a
%% real, loaded-module function call, so a stale/wrong dep_a.beam on the
%% code path (e.g. from a different rebar3 profile) produces an incorrect
%% "undefined callback" warning even though dep_a_behaviour genuinely
%% declares run/1.
-behaviour(dep_a_behaviour).

-export([run/1]).

-spec run(Arg) -> Result when
  Arg :: term(),
  Result :: term().
run(Arg) ->
  Arg.
