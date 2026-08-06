-module(test_dir_fixture_tests).

-include_lib("eunit/include/eunit.hrl").

add_test() ->
  ?assertEqual(3, test_dir_fixture:add(1, 2)).

%% References the test-profile-only dependency directly - only resolvable
%% (for erlsp's own indexing, not just rebar3's real compile) once
%% test_only_dep_fixture is actually built, exactly like a real suite
%% calling into meck/katt.
uses_test_only_dependency_test() ->
  ?assertEqual(ok, test_only_dep_fixture:stub()).
