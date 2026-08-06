-module(erlsp_host_rpc).

-export([
  compile_file/2,
  run_elvis/2,
  root_dir/0
]).

%% Compiles Path with Options.
-spec compile_file(Path, Options) -> Result when
  Path :: file:filename(),
  Options :: [compile:option()],
  Result :: compile:comp_ret().
compile_file(Path, Options) ->
  compile:file(Path, Options).

%% Loads ConfigPath's elvis config, keeps only the config group(s) whose
%% own `files` globs match RelativePath and runs elvis_core:do_rock/2 for each.
%% Returns {ok, RuleGroups} or {error, Reason}.
%%
%% Must run with the current process's cwd already set to the elvis
%% project's own root.
-spec run_elvis(ConfigPath, RelativePath) -> Result when
  ConfigPath :: file:filename(),
  RelativePath :: file:filename(),
  Result :: {ok, [elvis_result:rule()]} | {error, term()}.
run_elvis(ConfigPath, RelativePath) ->
  case elvis_config:from_file(ConfigPath) of
    {error, Reason} ->
      {error, Reason};
    ConfigGroups ->
      Matching = [
        ConfigGroup
      || ConfigGroup <- ConfigGroups, matches_config_group(ConfigGroup, RelativePath)
      ],
      RuleGroups = lists:append([
        rock_rules(ConfigGroup, RelativePath)
      || ConfigGroup <- Matching
      ]),
      {ok, RuleGroups}
  end.

-spec matches_config_group(ConfigGroup, RelativePath) -> Result when
  ConfigGroup :: elvis_config:t(),
  RelativePath :: file:filename(),
  Result :: boolean().
matches_config_group(ConfigGroup, RelativePath) ->
  Globs = maps:get(files, ConfigGroup, []),
  MatchedPaths = lists:append([filelib:wildcard(Glob) || Glob <- Globs]),
  lists:member(RelativePath, MatchedPaths).

-spec rock_rules(ConfigGroup, RelativePath) -> Result when
  ConfigGroup :: elvis_config:t(),
  RelativePath :: file:filename(),
  Result :: [elvis_result:rule()].
rock_rules(ConfigGroup, RelativePath) ->
  {ok, FileResult} = elvis_core:do_rock(#{path => RelativePath}, ConfigGroup),
  elvis_result:get_rules(FileResult).

%% The calling host's own OTP install root.
-spec root_dir() -> Result when
  Result :: file:filename().
root_dir() ->
  code:root_dir().
