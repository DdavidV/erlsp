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

%% Workspace/project discovery.
-export([
  init_workspace/1,
  root_path/0,
  clear_project_caches/0,
  project_roots/0,
  project_root_for_path/1,
  include_paths_for_root/1,
  source_dirs_for_root/1,
  dep_source_dirs_for_root/1,
  ebin_paths_for_root/1,
  build_tools_for_root/1
]).

%% erlsp.config-sourced settings.
-export([
  otp_path/0,
  otp_apps_exclude/0,
  deps_exclude/0,
  rebar_profile/0
]).

-export_type([
  build_tool/0
]).

-type build_tool() :: rebar3 | mix.

-define(CONFIG_FILE_NAME, "erlsp.config").

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
%% Also loads erlsp.config from the workspace root, if present.
-spec init_workspace(RootUri) -> Result when
  RootUri :: erlsp_documents:uri() | null,
  Result :: ok.
init_workspace(RootUri) ->
  RootPath = root_path_from_uri(RootUri),
  true = ets:insert(?MODULE, {root_path, RootPath}),
  true = ets:insert(?MODULE, {user_config, load_user_config(RootPath)}),
  ok.

-spec load_user_config(WorkspaceRoot) -> Result when
  WorkspaceRoot :: file:filename(),
  Result :: [{atom(), term()}].
load_user_config(WorkspaceRoot) ->
  ConfigPath = filename:join(WorkspaceRoot, ?CONFIG_FILE_NAME),
  case filelib:is_regular(ConfigPath) of
    false ->
      [];
    true ->
      case file:consult(ConfigPath) of
        {ok, [Terms]} when is_list(Terms) ->
          Terms;
        {ok, Terms} when is_list(Terms) ->
          %% file:consult/1 returns one list element per top-level term; a
          %% well-formed erlsp.config is a single proplist, but tolerate a
          %% file with the proplist's entries written as separate
          %% top-level terms too (no ok = ... wrapping needed by the user).
          lists:append([T || T <- Terms, is_list(T)]);
        {error, Reason} ->
          logger:warning("failed to read/parse ~s: ~p", [ConfigPath, Reason]),
          []
      end
  end.

-spec user_config() -> Result when
  Result :: [{atom(), term()}].
user_config() ->
  case ets:lookup(?MODULE, user_config) of
    [{user_config, Config}] -> Config;
    [] -> []
  end.

-spec root_path_from_uri(RootUri) -> Result when
  RootUri :: erlsp_documents:uri() | null,
  Result :: file:filename().
root_path_from_uri(null) ->
  {ok, Cwd} = file:get_cwd(),
  Cwd;
root_path_from_uri(RootUri) ->
  erlsp_utils:uri_to_path(RootUri).

-spec root_path() -> Result when
  Result :: file:filename() | undefined.
root_path() ->
  case ets:lookup(?MODULE, root_path) of
    [{root_path, RootPath}] -> RootPath;
    [] -> undefined
  end.

%% Drops every cached {project_root, _}/{include_paths, _}/{build_tools, _}
%% entry, keeping root_path and the loaded user_config itself (reindexing
%% shouldn't require the user to have kept the same erlsp.config open, but
%% it also shouldn't silently drop settings they've already configured).
-spec clear_project_caches() -> Result when
  Result :: ok.
clear_project_caches() ->
  RootPath = root_path(),
  UserConfig = user_config(),
  ets:delete_all_objects(?MODULE),
  case RootPath of
    undefined -> ok;
    _Path -> true = ets:insert(?MODULE, {root_path, RootPath})
  end,
  true = ets:insert(?MODULE, {user_config, UserConfig}),
  ok.

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
      IncludePaths = resolve_paths(ProjectRoot, include_dirs()) ++ own_app_parent_dirs(ProjectRoot),
      true = ets:insert(?MODULE, {{include_paths, ProjectRoot}, IncludePaths}),
      IncludePaths
  end.

-spec source_dirs_for_root(ProjectRoot) -> Result when
  ProjectRoot :: file:filename(),
  Result :: [file:filename()].
source_dirs_for_root(ProjectRoot) ->
  ConfiguredSourceDirs = proplists:get_value(source_dirs, user_config(), []),
  resolve_paths(ProjectRoot, ["src", "apps/*/src", "test", "apps/*/test"] ++ ConfiguredSourceDirs).

-spec dep_source_dirs_for_root(ProjectRoot) -> Result when
  ProjectRoot :: file:filename(),
  Result :: [file:filename()].
dep_source_dirs_for_root(ProjectRoot) ->
  OwnAppNames = [atom_to_list(AppName) || AppName <- own_app_names(ProjectRoot)],
  ExcludedApps = deps_exclude(),
  BuildDirs = filelib:wildcard(filename:join(ProjectRoot, "_build/*/lib/*")) ++
    filelib:wildcard(filename:join(ProjectRoot, "_build/*/checkouts/*")),
  [filename:join(Dir, "src")
  || Dir <- BuildDirs,
     filelib:is_dir(filename:join(Dir, "src")),
     not lists:member(filename:basename(Dir), OwnAppNames),
     not lists:member(filename:basename(Dir), ExcludedApps)].

%% Dependency app names (as strings, matching filename:basename/1's
%% return shape) to skip when indexing dependencies.
-spec deps_exclude() -> Result when
  Result :: [string()].
deps_exclude() ->
  [atom_to_list(App) || App <- proplists:get_value(deps_exclude, user_config(), [])].

%% Every built app's ebin directory under ProjectRoot's _build/ - own
%% app(s) and dependencies alike, since code:lib_dir/1 is name-keyed with
%% no correctness distinction between the two. Used to put a real, already
%% -built project's compiled modules on a code path so they can actually be loaded,
%% rather than erlsp only ever seeing source it can't run.
-spec ebin_paths_for_root(ProjectRoot) -> Result when
  ProjectRoot :: file:filename(),
  Result :: [file:filename()].
ebin_paths_for_root(ProjectRoot) ->
  AllEbinDirs = filelib:wildcard(filename:join(ProjectRoot, "_build/*/lib/*/ebin")) ++
    filelib:wildcard(filename:join(ProjectRoot, "_build/*/checkouts/*/ebin")),
  PreferredProfile = rebar_profile(),
  ByAppName = lists:foldl(fun(EbinDir, Acc) ->
    AppName = filename:basename(filename:dirname(EbinDir)),
    maps:update_with(AppName,
      fun(Existing) -> prefer_profile(Existing, EbinDir, PreferredProfile) end, EbinDir, Acc)
  end, #{}, AllEbinDirs),
  maps:values(ByAppName).

%% erlsp.config's rebar_profile key - which _build/<profile>/... tree to
%% prefer when the same app is built under more than one profile.
-spec rebar_profile() -> Result when
  Result :: string().
rebar_profile() ->
  atom_to_list(proplists:get_value(rebar_profile, user_config(), default)).

-spec prefer_profile(EbinDirA, EbinDirB, PreferredProfile) -> Result when
  EbinDirA :: file:filename(),
  EbinDirB :: file:filename(),
  PreferredProfile :: string(),
  Result :: file:filename().
prefer_profile(EbinDirA, EbinDirB, PreferredProfile) ->
  case profile_of(EbinDirA) =:= PreferredProfile of
    true -> EbinDirA;
    false ->
      case profile_of(EbinDirB) =:= PreferredProfile of
        true -> EbinDirB;
        false -> EbinDirA
      end
  end.

-spec profile_of(EbinDir) -> Result when
  EbinDir :: file:filename(),
  Result :: string().
profile_of(EbinDir) ->
  %% EbinDir is ".../_build/<profile>/lib/<app>/ebin" - walk up three
  %% levels from ebin/ to reach <profile>.
  filename:basename(filename:dirname(filename:dirname(filename:dirname(EbinDir)))).

-spec own_app_names(ProjectRoot) -> Result when
  ProjectRoot :: file:filename(),
  Result :: [atom()].
own_app_names(ProjectRoot) ->
  [AppName || {AppName, _SrcDir} <- own_apps(ProjectRoot)].

%% Every app.src belonging to ProjectRoot itself (not a dependency),
%% paired with the directory its own src/ lives in - either ProjectRoot
%% itself (single-app layout) or ProjectRoot/apps/<name> (an umbrella
%% sub-app).
-spec own_apps(ProjectRoot) -> Result when
  ProjectRoot :: file:filename(),
  Result :: [{atom(), file:filename()}].
own_apps(ProjectRoot) ->
  TopLevel = [
    {list_to_atom(filename:basename(AppSrcFile, ".app.src")), ProjectRoot}
  || AppSrcFile <- filelib:wildcard(filename:join(ProjectRoot, "src/*.app.src"))
  ],
  Umbrella = [
    {list_to_atom(filename:basename(AppSrcFile, ".app.src")),
     filename:dirname(filename:dirname(AppSrcFile))}
  || AppSrcFile <- filelib:wildcard(filename:join(ProjectRoot, "apps/*/src/*.app.src"))
  ],
  TopLevel ++ Umbrella.

%% For each of ProjectRoot's own apps whose source directory's basename
%% matches the app's own name, the parent of that source directory - e.g.
%% for a single-app project rooted at ".../myapp" with app name myapp,
%% this adds ".../" (myapp's parent); for an umbrella sub-app at
%% ".../apps/myapp" with app name myapp, this adds ".../apps/".
%%
%% Lets epp's own -include_lib("myapp/include/foo.hrl") resolution
%% succeed for a project's own (non-dependency) headers before any real
%% build exists, i.e. before ebin_paths_for_root/1 has anything to offer
%% code:lib_dir/1. Only ever adds ProjectRoot's own ancestor directories,
%% never an arbitrary path, so this introduces no new false-positive
%% match surface - it only works when the directory-name-matches-app-name
%% coincidence holds, which is common but not guaranteed.
-spec own_app_parent_dirs(ProjectRoot) -> Result when
  ProjectRoot :: file:filename(),
  Result :: [file:filename()].
own_app_parent_dirs(ProjectRoot) ->
  lists:usort([
    filename:dirname(SrcDir)
  || {AppName, SrcDir} <- own_apps(ProjectRoot),
     atom_to_list(AppName) =:= filename:basename(SrcDir)
  ]).

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
    "test",
    "apps",
    "apps/*/include",
    "apps/*/test",
    "_build/*/lib/",
    "_build/*/lib/*/include"
  ] ++ proplists:get_value(include_dirs, user_config(), []).

%% erlsp.config's otp_path key - a host OTP root to use instead of
%% auto-discovering one via PATH (erlsp_host_erl:root_dir/0). Meant for a
%% host with multiple Erlang installs (asdf/kerl) or one not on PATH at
%% all, where auto-discovery would pick the wrong (or no) install.
-spec otp_path() -> Result when
  Result :: file:filename() | undefined.
otp_path() ->
  proplists:get_value(otp_path, user_config(), undefined).

%% OTP application names (as strings) to skip when indexing the host's
%% OTP install - erlsp.config's otp_apps_exclude key. Trims indexing cost
%% for apps a project never touches.
-spec otp_apps_exclude() -> Result when
  Result :: [string()].
otp_apps_exclude() ->
  [atom_to_list(App) || App <- proplists:get_value(otp_apps_exclude, user_config(), [])].

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
