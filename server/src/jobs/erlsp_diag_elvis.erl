-module(erlsp_diag_elvis).

-behaviour(erlsp_job).

-include("erlsp.hrl").
-include_lib("kernel/include/logger.hrl").

-export([
  run/1
]).

%% Runs elvis (github.com/inaka/elvis_core) against Uri's file on disk
%% using the project's own elvis.config, if one exists at the project
%% root.  A project with no elvis.config gets no elvis diagnostics at all.
%%
%% The actual elvis run happens on the HOST's own erl, not in-process:
%% elvis_config:from_file/1 and elvis_core:do_rock/2 both resolve file
%% globs/paths relative to the CALLING PROCESS's current working directory,
%% and file:set_cwd/1 is process-global for the whole VM.
%% Delegating to a disposable host erl subprocess, whose own cwd is set only
%% for that one child process, avoids the this hazard entirely.
-spec run(Uri) -> Result when
  Uri :: erlsp_documents:uri(),
  Result :: [erlsp_job:diagnostic()].
run(Uri) ->
  Path = erlsp_utils:uri_to_path(Uri),
  case filename:extension(Path) of
    ".erl" -> elvis_diagnostics(Path);
    _OtherExtension -> []
  end.

-spec elvis_diagnostics(Path) -> Result when
  Path :: file:filename(),
  Result :: [erlsp_job:diagnostic()].
elvis_diagnostics(Path) ->
  ProjectRoot = erlsp_config:project_root_for_path(Path),
  ConfigPath = filename:join(ProjectRoot, "elvis.config"),
  case filelib:is_regular(ConfigPath) of
    false ->
      [];
    true ->
      RelativePath = relative_to(ProjectRoot, Path),
      PaDirs =
        [filename:join(code:lib_dir(App), "ebin") || App <- [erlsp, elvis_core, katana_code]],
      Result = erlsp_host_erl:run(
        erlsp_host_rpc, run_elvis, PaDirs, [ConfigPath, RelativePath], [{cd, ProjectRoot}]
      ),
      case Result of
        {ok, RuleGroups} ->
          rules_to_diagnostics(RuleGroups, source_lines(Path));
        {error, Reason} ->
          ?LOG_WARNING("elvis diagnostics unavailable for ~s: ~p", [Path, Reason]),
          []
      end
  end.

-spec source_lines(Path) -> Result when
  Path :: file:filename(),
  Result :: [binary()].
source_lines(Path) ->
  case file:read_file(Path) of
    {ok, Bytes} -> string:split(unicode:characters_to_binary(Bytes), <<"\n">>, all);
    {error, _Reason} -> []
  end.

-spec relative_to(Root, Path) -> Result when
  Root :: file:filename(),
  Path :: file:filename(),
  Result :: file:filename().
relative_to(Root, Path) ->
  AbsRoot = filename:absname(Root),
  AbsPath = filename:absname(Path),
  case string:prefix(AbsPath, AbsRoot ++ "/") of
    nomatch -> AbsPath;
    Suffix -> Suffix
  end.

-spec rules_to_diagnostics(Rules, Lines) -> Result when
  Rules :: [elvis_result:rule()],
  Lines :: [binary()],
  Result :: [erlsp_job:diagnostic()].
rules_to_diagnostics(Rules, Lines) ->
  lists:append([
    [item_to_diagnostic(Rule, Item, Lines) || Item <- elvis_result:get_items(Rule)]
  || Rule <- Rules
  ]).

-spec item_to_diagnostic(Rule, Item, Lines) -> Result when
  Rule :: elvis_result:rule(),
  Item :: elvis_result:item(),
  Lines :: [binary()],
  Result :: erlsp_job:diagnostic().
item_to_diagnostic(Rule, Item, Lines) ->
  #{ns := Namespace, name := RuleName} = Rule,
  Message = unicode:characters_to_binary(elvis_result:get_message(Item)),
  Info = elvis_result:get_info(Item),
  Formatted = format_message(Message, Info),
  #{
    range => range(elvis_result:get_line_num(Item), Lines),
    severity => ?DIAGNOSTIC_SEVERITY_WARNING,
    source => rule_source(Namespace, RuleName),
    message => Formatted
  }.

-spec rule_source(Namespace, RuleName) -> Result when
  Namespace :: module(),
  RuleName :: atom(),
  Result :: binary().
rule_source(Namespace, RuleName) ->
  unicode:characters_to_binary(io_lib:format("elvis(~p/~p)", [Namespace, RuleName])).

-spec format_message(Message, Info) -> Result when
  Message :: unicode:chardata(),
  Info :: [term()],
  Result :: binary().
format_message(Message, Info) ->
  try unicode:characters_to_binary(io_lib:format(binary_to_list(Message), Info)) of
    Formatted -> Formatted
  catch
    error:badarg ->
      %% Message already has its placeholders filled in some
      %% elvis_result:item() call sites - format/2 on a plain string
      %% with no matching ~ specifiers still succeeds, so this only
      %% catches a genuine Message/Info mismatch.
      Message
  end.

-spec range(LineNum, Lines) -> Result when
  LineNum :: -1 | non_neg_integer(),
  Lines :: [binary()],
  Result :: erlsp_job:range().
range(LineNum, Lines) when LineNum > 0, LineNum =< length(Lines) ->
  Line = lists:nth(LineNum, Lines),
  LeadingWhitespace = string:length(Line) - string:length(string:trim(Line, leading)),
  StartPosition = #{line => LineNum - 1, character => LeadingWhitespace},
  EndPosition = #{line => LineNum - 1, character => string:length(Line)},
  #{start => StartPosition, 'end' => EndPosition};
range(LineNum, _Lines) when LineNum > 0 ->
  Position = #{line => LineNum - 1, character => 0},
  #{start => Position, 'end' => Position};
range(_NoLine, _Lines) ->
  Position = #{line => 0, character => 0},
  #{start => Position, 'end' => Position}.
