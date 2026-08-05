-module(erlsp_diag_compiler).

-behaviour(erlsp_job).

-include("erlsp.hrl").
-include_lib("kernel/include/logger.hrl").

-export([
  run/1
]).

%% Compiles Uri's file on disk with basic_validation (syntax + erl_lint
%% checks, no code generation) and returns LSP Diagnostic objects for any
%% errors/warnings found. Compiles the real saved path directlyrather than
%% the in-memory buffer: diagnostics reflect the last save.
%%  Returns no diagnostics (rather than possibly-wrong ones) if erlsp_config's
%% workspace hasn't been initialized yet.
%% Never raises otherwise: a file that can't even be parsed just yields diagnostics
%% describing where it broke.
-spec run(Uri) -> Result when
  Uri :: erlsp_documents:uri(),
  Result :: [erlsp_job:diagnostic()].
run(Uri) ->
  Path = erlsp_uri:to_path(Uri),
  case {erlsp_config:root_path(), filename:extension(Path)} of
    {undefined, _} ->
      %% initialize hasn't set up the workspace's include paths yet:
      %% compiling now would run epp with no -include search paths and
      %% produce false-positive "undefined macro"/"can't find include file".
      [];
    {_, ".erl"} ->
      compile_diagnostics(Path);
    {_, _OtherExtension} ->
      %% compile:file/2 assumes an .erl module handing it a .hrl or
      %% anything else produces "no such file or directory".
      []
  end.

-spec compile_diagnostics(Path) -> Result when
  Path :: file:filename(),
  Result :: [erlsp_job:diagnostic()].
compile_diagnostics(Path) ->
  ProjectRoot = erlsp_config:project_root_for_path(Path),
  IncludeOptions =
    [{i, IncludeDir} || IncludeDir <- erlsp_config:include_paths_for_root(ProjectRoot)],
  Options = [basic_validation, return_errors, return_warnings | IncludeOptions],
  EbinDirs = erlsp_config:ebin_paths_for_root(ProjectRoot),
  {Errors, Warnings} = case erlsp_host_erl:compile_file(Path, Options, EbinDirs) of
    {_, HostErrors, HostWarnings} ->
      {HostErrors, HostWarnings};
    {error, Reason} ->
      ?LOG_WARNING("falling back to in-process compile for ~s: ~p", [Path, Reason]),
      {_, InProcessErrors, InProcessWarnings} = compile:file(Path, Options),
      {InProcessErrors, InProcessWarnings}
  end,
  ErrorDiagnostics = file_infos_to_diagnostics(Errors, ?DIAGNOSTIC_SEVERITY_ERROR),
  WarningDiagnostics = file_infos_to_diagnostics(Warnings, ?DIAGNOSTIC_SEVERITY_WARNING),
  ErrorDiagnostics ++ WarningDiagnostics.

-spec file_infos_to_diagnostics(FileInfos, Severity) -> Result when
  FileInfos :: [{file:filename(), [{erl_anno:location(), module(), term()}]}],
  Severity :: erlsp_job:severity(),
  Result :: [erlsp_job:diagnostic()].
file_infos_to_diagnostics(FileInfos, Severity) ->
  [diagnostic(Location, Module:format_error(ErrorDescriptor), Severity)
  || {_File, Infos} <- FileInfos, {Location, Module, ErrorDescriptor} <- Infos].

-spec diagnostic(Location, Message, Severity) -> Result when
  Location :: erl_anno:location(),
  Message :: unicode:chardata(),
  Severity :: erlsp_job:severity(),
  Result :: erlsp_job:diagnostic().
diagnostic(Location, Message, Severity) ->
  #{
    range => range(Location),
    severity => Severity,
    source => <<"erlsp">>,
    message => unicode:characters_to_binary(Message)
  }.

%% LSP positions are 0-indexed, compiler locations are 1-indexed.
%% A single point location is reported as a zero-width range at that
%% position, since the compiler doesn't give us an end position. Some
%% erl_lint/epp errors (e.g. undefined_module) aren't tied to any
%% specific line and report location none instead of a line/column -
%% those fall back to the start of the file.
-spec range(Location) -> Result when
  Location :: erl_anno:location() | none,
  Result :: erlsp_job:range().
range({Line, Column}) ->
  Position = #{line => Line - 1, character => Column - 1},
  #{start => Position, 'end' => Position};
range(Line) when is_integer(Line) ->
  Position = #{line => Line - 1, character => 0},
  #{start => Position, 'end' => Position};
range(none) ->
  Position = #{line => 0, character => 0},
  #{start => Position, 'end' => Position}.
