-module(erlsp_index_otp_job).

-behaviour(erlsp_job).

-include_lib("kernel/include/logger.hrl").

-export([
  run/2
]).

%% Parses every OTP application's source under the HOST's Erlang
%% installation's lib/ directory and records where each module and
%% function is defined, so go-to-definition also works for stdlib/kernel/eunit/etc.
-spec run(Uri, Token) -> Result when
  Uri :: erlsp_documents:uri(),
  Token :: erlsp_report:token(),
  Result :: ok.
run(_Uri, Token) ->
  erlsp_report:report(Token, {'begin', <<"Indexing">>}),
  RootDir = host_otp_root_dir(),
  add_host_otp_to_code_path(RootDir),
  Paths = otp_erl_files(RootDir),
  ?LOG_INFO("indexing ~b OTP files", [length(Paths)]),
  erlsp_index:index_files(Paths, Token, <<"OTP files">>),
  ?LOG_INFO("OTP indexing complete"),
  erlsp_report:report(Token, done),
  ok.

-spec host_otp_root_dir() -> Result when
  Result :: file:filename().
host_otp_root_dir() ->
  case erlsp_config:otp_path() of
    undefined -> discover_host_otp_root_dir();
    ConfiguredPath -> ConfiguredPath
  end.

-spec discover_host_otp_root_dir() -> Result when
  Result :: file:filename().
discover_host_otp_root_dir() ->
  case erlsp_host_erl:root_dir() of
    {ok, RootDir} ->
      RootDir;
    {error, Reason} ->
      ?LOG_WARNING("falling back to erlsp's own OTP root for indexing: ~p", [Reason]),
      code:root_dir()
  end.

-spec add_host_otp_to_code_path(RootDir) -> Result when
  RootDir :: file:filename(),
  Result :: ok.
add_host_otp_to_code_path(RootDir) ->
  EbinDirs = filelib:wildcard(filename:join([RootDir, "lib", "*", "ebin"])),
  code:add_pathsz(EbinDirs),
  ok.

-spec otp_erl_files(RootDir) -> Result when
  RootDir :: file:filename(),
  Result :: [file:filename()].
otp_erl_files(RootDir) ->
  %% "**" recurses into subdirectories - some apps nest source further
  %% (e.g. wx's generated bindings live under lib/wx-*/src/gen/*.erl), not
  %% just directly under src/.
  AllFiles = filelib:wildcard(filename:join([RootDir, "lib", "*", "src", "**/*.erl"])),
  ExcludedApps = erlsp_config:otp_apps_exclude(),
  [Path || Path <- AllFiles, not lists:member(otp_app_name(RootDir, Path), ExcludedApps)].

%% Path is ".../lib/<app>-<vsn>/src/...", the app name being everything
%% up to (not including) the last "-" in the lib/ subdirectory's basename
%% - OTP application directory names are always "<app>-<vsn>".
-spec otp_app_name(RootDir, Path) -> Result when
  RootDir :: file:filename(),
  Path :: file:filename(),
  Result :: string().
otp_app_name(RootDir, Path) ->
  LibDir = filename:join([RootDir, "lib"]),
  Relative = string:prefix(Path, LibDir ++ "/"),
  [AppDir | _Rest] = string:split(Relative, "/"),
  case string:split(AppDir, "-", trailing) of
    [AppName, _Vsn] -> AppName;
    [AppName] -> AppName
  end.
