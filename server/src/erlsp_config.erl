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
  project_roots/0,
  project_root_for_path/1,
  include_paths_for_root/1,
  source_dirs_for_root/1,
  dep_source_dirs_for_root/1,
  build_tools_for_root/1
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
%% which case the current working directory is used) and stores it.
%% Unlike a single app root, individual project roots (and their include
%% paths) are discovered lazily and cached, per file, via project_root_for_path/1.
-spec init_workspace(RootUri) -> Result when
  RootUri :: erlsp_documents:uri() | null,
  Result :: ok.
init_workspace(RootUri) ->
  RootPath = root_path_from_uri(RootUri),
  true = ets:insert(?MODULE, {root_path, RootPath}),
  ok.

-spec root_path_from_uri(RootUri) -> Result when
  RootUri :: erlsp_documents:uri() | null,
  Result :: file:filename().
root_path_from_uri(null) ->
  {ok, Cwd} = file:get_cwd(),
  Cwd;
root_path_from_uri(RootUri) ->
  erlsp_uri:to_path(RootUri).

-spec root_path() -> Result when
  Result :: file:filename() | undefined.
root_path() ->
  case ets:lookup(?MODULE, root_path) of
    [{root_path, RootPath}] -> RootPath;
    [] -> undefined
  end.

%% Every distinct project root found under the workspace root, i.e. every
%% directory (searched recursively) that itself contains a
%% rebar.config/mix.exs.
-spec project_roots() -> Result when
  Result :: [file:filename()].
project_roots() ->
  case root_path() of
    undefined ->
      [];
    RootPath ->
      case has_build_config(RootPath) of
        true -> [RootPath];
        false -> find_build_config_dirs(RootPath)
      end
  end.

-spec find_build_config_dirs(Dir) -> Result when
  Dir :: file:filename(),
  Result :: [file:filename()].
find_build_config_dirs(Dir) ->
  case filename:basename(Dir) of
    "_build" ->
      [];
    _Basename ->
      Subdirs = [
        Path
      || Path <- filelib:wildcard(filename:join(Dir, "*")),
         filelib:is_dir(Path)
      ],
      {WithConfig, WithoutConfig} = lists:partition(fun has_build_config/1, Subdirs),
      WithConfig ++ lists:append([find_build_config_dirs(Subdir) || Subdir <- WithoutConfig])
  end.

%% The nearest ancestor of Path (a file or directory) that contains a
%% rebar.config/mix.exs, mirroring how rebar3/Mix themselves resolve
%% which project a file belongs to. Falls back to the workspace root if
%% no ancestor has one (e.g. a loose .erl file with no build config at
%% all). Cached per resolved starting directory, since this walk happens
%% on every index/diagnostics job for every file.
-spec project_root_for_path(Path) -> Result when
  Path :: file:filename(),
  Result :: file:filename().
project_root_for_path(Path) ->
  StartDir = case filelib:is_dir(Path) of
    true -> filename:absname(Path);
    false -> filename:dirname(filename:absname(Path))
  end,
  case ets:lookup(?MODULE, {project_root, StartDir}) of
    [{{project_root, StartDir}, ProjectRoot}] ->
      ProjectRoot;
    [] ->
      ProjectRoot = discover_project_root(StartDir),
      true = ets:insert(?MODULE, {{project_root, StartDir}, ProjectRoot}),
      ProjectRoot
  end.

-spec discover_project_root(Dir) -> Result when
  Dir :: file:filename(),
  Result :: file:filename().
discover_project_root(Dir) ->
  case has_build_config(Dir) of
    true ->
      Dir;
    false ->
      Parent = filename:dirname(Dir),
      case Parent =:= Dir of
        true ->
          %% Reached the filesystem root without finding one.
          case root_path() of
            undefined -> Dir;
            RootPath -> RootPath
          end;
        false ->
          discover_project_root(Parent)
      end
  end.

-spec has_build_config(Path) -> Result when
  Path :: file:filename(),
  Result :: boolean().
has_build_config(Path) ->
  filelib:is_file(filename:join(Path, "rebar.config")) orelse
    filelib:is_file(filename:join(Path, "mix.exs")).

-spec include_paths_for_root(ProjectRoot) -> Result when
  ProjectRoot :: file:filename(),
  Result :: [file:filename()].
include_paths_for_root(ProjectRoot) ->
  case ets:lookup(?MODULE, {include_paths, ProjectRoot}) of
    [{{include_paths, ProjectRoot}, IncludePaths}] ->
      IncludePaths;
    [] ->
      IncludePaths = resolve_paths(ProjectRoot, include_dirs()),
      true = ets:insert(?MODULE, {{include_paths, ProjectRoot}, IncludePaths}),
      IncludePaths
  end.

-spec source_dirs_for_root(ProjectRoot) -> Result when
  ProjectRoot :: file:filename(),
  Result :: [file:filename()].
source_dirs_for_root(ProjectRoot) ->
  resolve_paths(ProjectRoot, ["src", "apps/*/src"]).

-spec dep_source_dirs_for_root(ProjectRoot) -> Result when
  ProjectRoot :: file:filename(),
  Result :: [file:filename()].
dep_source_dirs_for_root(ProjectRoot) ->
  OwnAppNames = own_app_names(ProjectRoot),
  BuildLibDirs = filelib:wildcard(filename:join(ProjectRoot, "_build/*/lib/*")),
  [filename:join(Dir, "src")
  || Dir <- BuildLibDirs,
     filelib:is_dir(filename:join(Dir, "src")),
     not lists:member(filename:basename(Dir), OwnAppNames)].

-spec own_app_names(ProjectRoot) -> Result when
  ProjectRoot :: file:filename(),
  Result :: [file:filename()].
own_app_names(ProjectRoot) ->
  AppSrcFiles = filelib:wildcard(filename:join(ProjectRoot, "src/*.app.src")) ++
    filelib:wildcard(filename:join(ProjectRoot, "apps/*/src/*.app.src")),
  [filename:basename(AppSrcFile, ".app.src") || AppSrcFile <- AppSrcFiles].

-spec build_tools_for_root(ProjectRoot) -> Result when
  ProjectRoot :: file:filename(),
  Result :: [build_tool()].
build_tools_for_root(ProjectRoot) ->
  case ets:lookup(?MODULE, {build_tools, ProjectRoot}) of
    [{{build_tools, ProjectRoot}, BuildTools}] ->
      BuildTools;
    [] ->
      BuildTools = detect_build_tools(ProjectRoot),
      true = ets:insert(?MODULE, {{build_tools, ProjectRoot}, BuildTools}),
      BuildTools
  end.

-spec detect_build_tools(ProjectRoot) -> Result when
  ProjectRoot :: file:filename(),
  Result :: [build_tool()].
detect_build_tools(ProjectRoot) ->
  Candidates = [
    {rebar3, "rebar.config"},
    {mix, "mix.exs"}
  ],
  [BuildTool || {BuildTool, ConfigFile} <- Candidates,
   filelib:is_file(filename:join(ProjectRoot, ConfigFile))].

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
