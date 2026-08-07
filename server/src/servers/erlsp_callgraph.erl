-module(erlsp_callgraph).

-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-record(state, {graph :: digraph:graph(), status :: status()}).

-type state() :: #state{}.
-type status() :: not_built | built.

-type mfa_json() :: #{module := binary(), function := binary(), arity := arity()}.
-type node_json() :: #{
  module := binary(),
  function := binary(),
  arity := arity(),
  origin := workspace | external,
  uri => erlsp_documents:uri(),
  line => non_neg_integer()
}.
-type edge_json() :: #{caller := mfa_json(), callee := mfa_json()}.

-export([
  start_link/0,
  init/1,
  handle_call/3,
  handle_cast/2,
  terminate/2
]).

-export([
  clear/0,
  ensure_built/1,
  snapshot/0,
  status/0
]).

-spec start_link() -> Result when
  Result :: {ok, pid()}.
start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec init(InitArgs) -> Result when
  InitArgs :: term(),
  Result :: {ok, state()}.
init(_InitArgs) ->
  {ok, #state{graph = digraph:new([cyclic, protected]), status = not_built}}.

%% Discards the current graph and resets to not_built, so the next
%% ensure_built/1 recomputes from scratch rather than reusing stale
%% vertices/edges.
-spec clear() -> Result when
  Result :: ok.
clear() ->
  gen_server:call(?MODULE, clear).

%% Builds the whole-workspace call graph if it isn't already built,
%% reporting progress against Token as each workspace file is walked.
-spec ensure_built(Token) -> Result when
  Token :: erlsp_report:token(),
  Result :: ok.
ensure_built(Token) ->
  gen_server:call(?MODULE, {ensure_built, Token}, infinity).

%% The current graph's status: not_built or built.
-spec status() -> Result when
  Result :: status().
status() ->
  gen_server:call(?MODULE, status).

%% Renders the current graph as plain node/edge data.
-spec snapshot() -> Result when
  Result :: #{nodes := [node_json()], edges := [edge_json()]}.
snapshot() ->
  gen_server:call(?MODULE, snapshot).

-spec handle_call(Request, From, State) -> Result when
  Request :: clear | {ensure_built, erlsp_report:token()} | status | snapshot,
  From :: {pid(), term()},
  State :: state(),
  Result :: {reply, term(), state()}.
handle_call(clear, _From, State) ->
  true = digraph:delete(State#state.graph),
  NewState = State#state{graph = digraph:new([cyclic, protected]), status = not_built},
  {reply, ok, NewState};
handle_call({ensure_built, _Token}, _From, #state{status = built} = State) ->
  {reply, ok, State};
handle_call({ensure_built, Token}, _From, #state{status = not_built} = State) ->
  ok = build(State#state.graph, Token),
  {reply, ok, State#state{status = built}};
handle_call(status, _From, State) ->
  {reply, State#state.status, State};
handle_call(snapshot, _From, State) ->
  {reply, render_snapshot(State#state.graph), State}.

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

%% Walks every workspace .erl file's already-parsed forms,
%% extracting {Mfa, Uri, Line} vertices and {Caller, Callee} edges,
%% then records them into Graph.
%% Every callee that isn't itself a workspace-defined function
%% still gets a vertex, labeled external rather than with a real Uri/Line.
-spec build(Graph, Token) -> Result when
  Graph :: digraph:graph(),
  Token :: erlsp_report:token(),
  Result :: ok.
build(Graph, Token) ->
  erlsp_report:report(Token, {'begin', <<"Building call graph">>}),
  Paths = workspace_erl_files(),
  Total = length(Paths),
  build_files(Graph, Paths, Token, 0, Total),
  erlsp_report:report(Token, done),
  ok.

-spec workspace_erl_files() -> Result when
  Result :: [file:filename()].
workspace_erl_files() ->
  ProjectRoots = erlsp_config:project_roots(),
  lists:append([
    filelib:wildcard(filename:join(Dir, "**/*.erl"))
  || ProjectRoot <- ProjectRoots, Dir <- erlsp_config:source_dirs_for_root(ProjectRoot)
  ]).

-spec build_files(Graph, Paths, Token, Current, Total) -> Result when
  Graph :: digraph:graph(),
  Paths :: [file:filename()],
  Token :: erlsp_report:token(),
  Current :: non_neg_integer(),
  Total :: non_neg_integer(),
  Result :: ok.
build_files(_Graph, [], _Token, _Current, _Total) ->
  ok;
build_files(Graph, [Path | Rest], Token, Current, Total) ->
  build_file(Graph, Path),
  NewCurrent = Current + 1,
  Message = unicode:characters_to_binary(io_lib:format("~b/~b files", [NewCurrent, Total])),
  Percentage = case Total of
    0 -> 100;
    _NonZero -> (NewCurrent * 100) div Total
  end,
  erlsp_report:report(Token, {update, Message, Percentage}),
  build_files(Graph, Rest, Token, NewCurrent, Total).

-spec build_file(Graph, Path) -> Result when
  Graph :: digraph:graph(),
  Path :: file:filename(),
  Result :: ok.
build_file(Graph, Path) ->
  ok = erlsp_index:index_file(Path),
  case epp:parse_file(Path, []) of
    {ok, Forms} ->
      Uri = erlsp_utils:path_to_uri(Path),
      {Vertices, Edges} = erlsp_callgraph_extract:extract_edges(Uri, Forms),
      [add_workspace_vertex(Graph, Mfa, VertexUri, Line) || {Mfa, VertexUri, Line} <- Vertices],
      [add_edge(Graph, Caller, Callee) || {Caller, Callee} <- Edges],
      ok;
    {error, _Reason} ->
      ok
  end.

-spec add_workspace_vertex(Graph, Mfa, Uri, Line) -> Result when
  Graph :: digraph:graph(),
  Mfa :: erlsp_callgraph_extract:mfa_t(),
  Uri :: erlsp_documents:uri(),
  Line :: non_neg_integer(),
  Result :: ok.
add_workspace_vertex(Graph, Mfa, Uri, Line) ->
  digraph:add_vertex(Graph, Mfa, {workspace, Uri, Line}),
  ok.

-spec add_edge(Graph, Caller, Callee) -> Result when
  Graph :: digraph:graph(),
  Caller :: erlsp_callgraph_extract:mfa_t(),
  Callee :: erlsp_callgraph_extract:mfa_t(),
  Result :: ok.
add_edge(Graph, Caller, Callee) ->
  case digraph:vertex(Graph, Callee) of
    {Callee, _Label} ->
      ok;
    false ->
      digraph:add_vertex(Graph, Callee, external),
      ok
  end,
  digraph:add_edge(Graph, Caller, Callee),
  ok.

-spec render_snapshot(Graph) -> Result when
  Graph :: digraph:graph(),
  Result :: #{nodes := [node_json()], edges := [edge_json()]}.
render_snapshot(Graph) ->
  Vertices = digraph:vertices(Graph),
  Nodes = [node_json(Graph, Mfa) || Mfa <- Vertices],
  EdgeIds = digraph:edges(Graph),
  Edges = [edge_json(Graph, EdgeId) || EdgeId <- EdgeIds],
  #{nodes => Nodes, edges => Edges}.

-spec node_json(Graph, Mfa) -> Result when
  Graph :: digraph:graph(),
  Mfa :: erlsp_callgraph_extract:mfa_t(),
  Result :: node_json().
node_json(Graph, {Module, Function, Arity} = Mfa) ->
  {Mfa, VertexLabel} = digraph:vertex(Graph, Mfa),
  Base = #{module => atom_to_binary(Module), function => atom_to_binary(Function), arity => Arity},
  case VertexLabel of
    external ->
      Base#{origin => external};
    {workspace, Uri, Line} ->
      Base#{origin => workspace, uri => Uri, line => Line}
  end.

-spec edge_json(Graph, EdgeId) -> Result when
  Graph :: digraph:graph(),
  EdgeId :: digraph:edge(),
  Result :: edge_json().
edge_json(Graph, EdgeId) ->
  {EdgeId, Caller, Callee, _Label} = digraph:edge(Graph, EdgeId),
  #{caller => mfa_json(Caller), callee => mfa_json(Callee)}.

-spec mfa_json(Mfa) -> Result when
  Mfa :: erlsp_callgraph_extract:mfa_t(),
  Result :: mfa_json().
mfa_json({Module, Function, Arity}) ->
  #{module => atom_to_binary(Module), function => atom_to_binary(Function), arity => Arity}.
