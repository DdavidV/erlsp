-module(erlsp_config).

-behaviour(gen_server).

-record(state, {}).

-type state() :: #state{}.

-export([
  start_link/0,
  init/1,
  handle_call/3,
  handle_cast/2,
  terminate/2
]).

-export([
  init_workspace/1,
  root_path/0,
  app_root_path/0,
  include_paths/0,
  build_tools/0
]).

-export_type([
  build_tool/0
]).

-type build_tool() :: rebar3 | mix.

-spec start_link() -> Result when
  Result :: {ok, pid()}.
start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec init(InitArgs) -> Result when
  InitArgs :: term(),
  Result :: {ok, state()}.
init(_InitArgs) ->
  ets:new(?MODULE, [set, public, named_table, {read_concurrency, true}]),
  {ok, #state{}}.

%% Resolves the initialize request's rootUri to a local workspace root
%% (rootUri may be null per the LSP spec, when no folder is open, in
%% which case the current working directory is used), then finds the actual
%% OTP app root, detects which build tool(s) it uses, and precomputes
%% the include search paths every diagnostics job should use.
%% Stores all of it for the rest of the session. Meant to be called
%% once, from the initialize request.
-spec init_workspace(RootUri) -> Result when
  RootUri :: erlsp_documents:uri() | null,
  Result :: ok.
init_workspace(RootUri) ->
  RootPath = root_path_from_uri(RootUri),
  true = ets:insert(?MODULE, {root_path, RootPath}),
  AppRootPath = find_app_root(RootPath),
  true = ets:insert(?MODULE, {app_root_path, AppRootPath}),
  true = ets:insert(?MODULE, {build_tools, detect_build_tools(AppRootPath)}),
  IncludePaths = resolve_paths(AppRootPath, include_dirs()),
  true = ets:insert(?MODULE, {include_paths, IncludePaths}),
  ok.

-spec root_path_from_uri(RootUri) -> Result when
  RootUri :: erlsp_documents:uri() | null,
  Result :: file:filename().
root_path_from_uri(null) ->
  {ok, Cwd} = file:get_cwd(),
  Cwd;
root_path_from_uri(RootUri) ->
  erlsp_uri:to_path(RootUri).

%% A rebar3/Mix project's build config normally sits at the LSP
%% workspace root, but a monorepo (e.g. erlsp itself: client/ + server/
%% as siblings under the repo root, with rebar.config only inside
%% server/) breaks that assumption. If RootPath itself has no
%% rebar.config/mix.exs, scan its immediate subdirectories for one and
%% use whichever is found first as the real app root; falls back to
%% RootPath unchanged if none is found anywhere.
-spec find_app_root(RootPath) -> Result when
  RootPath :: file:filename(),
  Result :: file:filename().
find_app_root(RootPath) ->
  case has_build_config(RootPath) of
    true ->
      RootPath;
    false ->
      Subdirs = [
        Path
      || Path <- filelib:wildcard(filename:join(RootPath, "*")),
         filelib:is_dir(Path)
      ],
      case lists:search(fun has_build_config/1, Subdirs) of
        {value, AppRoot} -> AppRoot;
        false -> RootPath
      end
  end.

-spec has_build_config(Path) -> Result when
  Path :: file:filename(),
  Result :: boolean().
has_build_config(Path) ->
  filelib:is_file(filename:join(Path, "rebar.config")) orelse
    filelib:is_file(filename:join(Path, "mix.exs")).

-spec root_path() -> Result when
  Result :: file:filename() | undefined.
root_path() ->
  case ets:lookup(?MODULE, root_path) of
    [{root_path, RootPath}] -> RootPath;
    [] -> undefined
  end.

-spec app_root_path() -> Result when
  Result :: file:filename() | undefined.
app_root_path() ->
  case ets:lookup(?MODULE, app_root_path) of
    [{app_root_path, AppRootPath}] -> AppRootPath;
    [] -> undefined
  end.

-spec include_paths() -> Result when
  Result :: [file:filename()].
include_paths() ->
  case ets:lookup(?MODULE, include_paths) of
    [{include_paths, IncludePaths}] -> IncludePaths;
    [] -> []
  end.

-spec build_tools() -> Result when
  Result :: [build_tool()].
build_tools() ->
  case ets:lookup(?MODULE, build_tools) of
    [{build_tools, BuildTools}] -> BuildTools;
    [] -> []
  end.

%% Which build tool config files are present at the app root.
-spec detect_build_tools(RootPath) -> Result when
  RootPath :: file:filename(),
  Result :: [build_tool()].
detect_build_tools(RootPath) ->
  Candidates = [
    {rebar3, "rebar.config"},
    {mix, "mix.exs"}
  ],
  [BuildTool || {BuildTool, ConfigFile} <- Candidates,
   filelib:is_file(filename:join(RootPath, ConfigFile))].

%% Tried unconditionally, regardless of which build tool(s) were
%% detected: rebar3 and Mix's own Erlang compiler task both default to
%% this same src/include layout and _build/<env>/lib/<app>/... output
%% shape, and a glob that doesn't match anything (e.g. no _build/
%% directory at all) is harmless - it just contributes no paths.
-spec include_dirs() -> Result when
  Result :: [file:filename()].
include_dirs() ->
  [
    "src",
    "include",
    "apps",
    "apps/*/include",
    "_build/*/lib/",
    "_build/*/lib/*/include"
  ].

%% Joins each Dir spec onto RootPath and expands any glob wildcards
%% (e.g. "apps/*/include") against the real filesystem.
-spec resolve_paths(RootPath, Dirs) -> Result when
  RootPath :: file:filename(),
  Dirs :: [file:filename()],
  Result :: [file:filename()].
resolve_paths(RootPath, Dirs) ->
  lists:append([filelib:wildcard(filename:join(RootPath, Dir)) || Dir <- Dirs]).

-spec handle_call(Request, From, State) -> Result when
  Request :: term(),
  From :: {pid(), term()},
  State :: state(),
  Result :: {reply, ok, state()}.
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

-spec handle_cast(Request, State) -> Result when
  Request :: term(),
  State :: state(),
  Result :: {noreply, state()}.
handle_cast(_Request, State) ->
  {noreply, State}.

-spec terminate(Reason, State) -> Result when
  Reason :: term(),
  State :: state(),
  Result :: ok.
terminate(_Reason, _State) ->
  ok.
