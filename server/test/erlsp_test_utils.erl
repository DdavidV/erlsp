-module(erlsp_test_utils).

-export([
  fixtures_root/0,
  fixture/1,
  fixture_compiled/1,
  rebar3_compile/2,
  ensure_checkout_symlink/2
]).

%% rebar3 eunit always runs with cwd = server/ (rebar3's own convention),
%% so test-fixtures/ - a sibling of server/, not server/test/ itself - is
%% just one level up. Fixture *projects* live outside server/ entirely so
%% rebar3's test/ auto-discovery never mistakes their .erl files for
%% erlsp's own test suites.
-spec fixtures_root() -> Result when
  Result :: file:filename().
fixtures_root() ->
  filename:absname(filename:join(["..", "test-fixtures"])).

-spec fixture(Name) -> Result when
  Name :: file:filename(),
  Result :: file:filename().
fixture(Name) ->
  filename:join(fixtures_root(), Name).

-spec fixture_compiled(Name) -> Result when
  Name :: file:filename(),
  Result :: file:filename().
fixture_compiled(Name) ->
  Root = fixture(Name),
  ok = rebar3_compile(Root, []),
  ok = erlsp_config:init_workspace(erlsp_utils:path_to_uri(Root)),
  Root.

-spec rebar3_compile(Root, ExtraArgs) -> Result when
  Root :: file:filename(),
  ExtraArgs :: [string()],
  Result :: ok.
rebar3_compile(Root, ExtraArgs) ->
  Cmd = lists:flatten(io_lib:format("cd ~s && rebar3 ~s compile",
    [Root, string:join(ExtraArgs, " ")])),
  _ = os:cmd(Cmd),
  ok.

-spec ensure_checkout_symlink(Root, AppName) -> Result when
  Root :: file:filename(),
  AppName :: string(),
  Result :: ok.
ensure_checkout_symlink(Root, AppName) ->
  CheckoutsDir = filename:join(Root, "_checkouts"),
  ok = filelib:ensure_dir(filename:join(CheckoutsDir, "placeholder")),
  LinkPath = filename:join(CheckoutsDir, AppName),
  SourcePath = filename:join([Root, "_checkout_source", AppName]),
  case file:read_link(LinkPath) of
    {ok, _Existing} -> ok;
    {error, enoent} ->
      ok = file:make_symlink(SourcePath, LinkPath)
  end.
