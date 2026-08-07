-module(erlsp_callgraph_extract).

-type mfa_t() :: {module(), atom(), arity()}.
-type vertex() :: {mfa_t(), erlsp_documents:uri(), non_neg_integer()}.
-type edge() :: {mfa_t(), mfa_t()}.

-export_type([
  mfa_t/0,
  vertex/0,
  edge/0
]).

-export([
  extract_edges/2
]).

%% Walks every {function, ...} form in Forms and returns:
%% - Vertices: one {Mfa, Uri, Line} per function DEFINED in Forms (Uri/Line
%%   let erlsp_callgraph attach real location data to workspace vertices).
%% - Edges: one {Caller, Callee} per statically-resolvable call site found
%%   anywhere in that function's clause bodies, however deeply nested
%%   (case/if/receive/try/catch/fun/block/comprehension bodies are all
%%   walked, not just a clause's top-level expression list).
%%
%% Only calls whose target is a literal atom become edges.
-spec extract_edges(Uri, Forms) -> Result when
  Uri :: erlsp_documents:uri(),
  Forms :: [erl_parse:abstract_form()],
  Result :: {Vertices :: [vertex()], Edges :: [edge()]}.
extract_edges(Uri, Forms) ->
  case module_name(Forms) of
    {ok, Module} ->
      lists:foldl(
        fun(Form, Acc) -> extract_form(Module, Uri, Form, Acc) end,
        {[], []},
        Forms
      );
    error ->
      {[], []}
  end.

-spec module_name(Forms) -> Result when
  Forms :: [erl_parse:abstract_form()],
  Result :: {ok, module()} | error.
module_name(Forms) ->
  case lists:search(fun({attribute, _Line, module, _Module}) -> true; (_Other) -> false end, Forms) of
    {value, {attribute, _Line, module, Module}} -> {ok, Module};
    false -> error
  end.

-spec extract_form(Module, Uri, Form, Acc) -> Result when
  Module :: module(),
  Uri :: erlsp_documents:uri(),
  Form :: erl_parse:abstract_form(),
  Acc :: {[vertex()], [edge()]},
  Result :: {[vertex()], [edge()]}.
extract_form(Module, Uri, {function, Anno, Name, Arity, Clauses}, {Vertices, Edges}) ->
  Caller = {Module, Name, Arity},
  Line = anno_line(Anno),
  Callees = lists:append([clause_callees(Module, Clause) || Clause <- Clauses]),
  NewEdges = [{Caller, Callee} || Callee <- Callees],
  {[{Caller, Uri, Line} | Vertices], NewEdges ++ Edges};
extract_form(_Module, _Uri, _OtherForm, Acc) ->
  Acc.

-spec anno_line(erl_anno:anno()) -> non_neg_integer().
anno_line(Anno) when is_integer(Anno) -> Anno;
anno_line(Anno) -> erl_anno:line(Anno).

-spec clause_callees(Module, Clause) -> Result when
  Module :: module(),
  Clause :: erl_parse:abstract_clause(),
  Result :: [mfa_t()].
clause_callees(Module, {clause, _Anno, _Patterns, _Guards, Body}) ->
  exprs_callees(Module, Body).

-spec resolve_unqualified_call(Module, Name, Arity) -> Result when
  Module :: module(),
  Name :: atom(),
  Arity :: arity(),
  Result :: mfa_t().
resolve_unqualified_call(Module, Name, Arity) ->
  case erlsp_index:function_location(Module, Name, Arity) of
    {ok, _Location} ->
      {Module, Name, Arity};
    error ->
      case erlsp_index:imported_module(Module, Name, Arity) of
        {ok, ImportedModule} ->
          {ImportedModule, Name, Arity};
        error ->
          case erl_internal:bif(Name, Arity) of
            true -> {erlang, Name, Arity};
            false -> {Module, Name, Arity}
          end
      end
  end.

-spec exprs_callees(Module, Exprs) -> Result when
  Module :: module(),
  Exprs :: [erl_parse:abstract_expr()],
  Result :: [mfa_t()].
exprs_callees(Module, Exprs) ->
  lists:append([expr_callees(Module, Expr) || Expr <- Exprs]).

-spec expr_callees(Module, Expr) -> Result when
  Module :: module(),
  Expr :: erl_parse:abstract_expr(),
  Result :: [mfa_t()].
expr_callees(Module, {call, _Anno, {atom, _NameAnno, Name}, Args}) ->
  Arity = length(Args),
  Callee = resolve_unqualified_call(Module, Name, Arity),
  ArgsCallees = exprs_callees(Module, Args),
  [Callee | ArgsCallees];
expr_callees(Module, {call, _Anno, {remote, _RemoteAnno, {atom, _ModAnno, Mod}, {atom, _NameAnno, Name}}, Args}) ->
  ArgsCallees = exprs_callees(Module, Args),
  [{Mod, Name, length(Args)} | ArgsCallees];
expr_callees(Module, {call, _Anno, Callee, Args}) ->
  %% Dynamic dispatch (variable/expression module or function) - the
  %% callee expression and args may still contain calls of their own
  %% (e.g. Mod:F(helper(X))), so keep walking, just don't emit an edge
  %% for this call site itself.
  exprs_callees(Module, [Callee | Args]);
expr_callees(Module, {match, _Anno, Left, Right}) ->
  exprs_callees(Module, [Left, Right]);
expr_callees(Module, {op, _Anno, _Op, Left, Right}) ->
  exprs_callees(Module, [Left, Right]);
expr_callees(Module, {op, _Anno, _Op, Operand}) ->
  expr_callees(Module, Operand);
expr_callees(Module, {block, _Anno, Body}) ->
  exprs_callees(Module, Body);
expr_callees(Module, {'if', _Anno, Clauses}) ->
  lists:append([clause_callees(Module, Clause) || Clause <- Clauses]);
expr_callees(Module, {'case', _Anno, Expr, Clauses}) ->
  ExprCallees = expr_callees(Module, Expr),
  ClauseCallees = lists:append([clause_callees(Module, Clause) || Clause <- Clauses]),
  ExprCallees ++ ClauseCallees;
expr_callees(Module, {'receive', _Anno, Clauses}) ->
  lists:append([clause_callees(Module, Clause) || Clause <- Clauses]);
expr_callees(Module, {'receive', _Anno, Clauses, After, AfterBody}) ->
  ClauseCallees = lists:append([clause_callees(Module, Clause) || Clause <- Clauses]),
  AfterExprCallees = expr_callees(Module, After),
  AfterBodyCallees = exprs_callees(Module, AfterBody),
  ClauseCallees ++ AfterExprCallees ++ AfterBodyCallees;
expr_callees(Module, {'try', _Anno, Body, CaseClauses, CatchClauses, AfterBody}) ->
  BodyCallees = exprs_callees(Module, Body),
  CaseCallees = lists:append([clause_callees(Module, Clause) || Clause <- CaseClauses]),
  CatchCallees = lists:append([clause_callees(Module, Clause) || Clause <- CatchClauses]),
  AfterCallees = exprs_callees(Module, AfterBody),
  BodyCallees ++ CaseCallees ++ CatchCallees ++ AfterCallees;
expr_callees(Module, {'fun', _Anno, {clauses, Clauses}}) ->
  lists:append([clause_callees(Module, Clause) || Clause <- Clauses]);
expr_callees(_Module, {'fun', _Anno, {function, _Name, _Arity}}) ->
  [];
expr_callees(_Module, {'fun', _Anno, {function, _RemoteMod, _RemoteName, _RemoteArity}}) ->
  [];
expr_callees(Module, {named_fun, _Anno, _FunName, Clauses}) ->
  lists:append([clause_callees(Module, Clause) || Clause <- Clauses]);
expr_callees(Module, {lc, _Anno, TemplateExpr, Qualifiers}) ->
  TemplateCallees = expr_callees(Module, TemplateExpr),
  QualifierCallees = lists:append([qualifier_callees(Module, Qualifier) || Qualifier <- Qualifiers]),
  TemplateCallees ++ QualifierCallees;
expr_callees(Module, {bc, _Anno, TemplateExpr, Qualifiers}) ->
  TemplateCallees = expr_callees(Module, TemplateExpr),
  QualifierCallees = lists:append([qualifier_callees(Module, Qualifier) || Qualifier <- Qualifiers]),
  TemplateCallees ++ QualifierCallees;
expr_callees(Module, {mc, _Anno, TemplateAssoc, Qualifiers}) ->
  TemplateCallees = map_field_callees(Module, TemplateAssoc),
  QualifierCallees = lists:append([qualifier_callees(Module, Qualifier) || Qualifier <- Qualifiers]),
  TemplateCallees ++ QualifierCallees;
expr_callees(Module, {cons, _Anno, Head, Tail}) ->
  exprs_callees(Module, [Head, Tail]);
expr_callees(Module, {tuple, _Anno, Elements}) ->
  exprs_callees(Module, Elements);
expr_callees(Module, {map, _Anno, Assocs}) ->
  lists:append([map_field_callees(Module, Assoc) || Assoc <- Assocs]);
expr_callees(Module, {map, _Anno, BaseExpr, Assocs}) ->
  BaseCallees = expr_callees(Module, BaseExpr),
  AssocCallees = lists:append([map_field_callees(Module, Assoc) || Assoc <- Assocs]),
  BaseCallees ++ AssocCallees;
expr_callees(Module, {record, _Anno, _RecordName, Fields}) ->
  lists:append([record_field_callees(Module, Field) || Field <- Fields]);
expr_callees(Module, {record, _Anno, BaseExpr, _RecordName, Fields}) ->
  BaseCallees = expr_callees(Module, BaseExpr),
  FieldCallees = lists:append([record_field_callees(Module, Field) || Field <- Fields]),
  BaseCallees ++ FieldCallees;
expr_callees(Module, {record_field, _Anno, BaseExpr, _RecordName, _FieldExpr}) ->
  expr_callees(Module, BaseExpr);
expr_callees(Module, {bin, _Anno, Elements}) ->
  lists:append([bin_element_callees(Module, Element) || Element <- Elements]);
expr_callees(Module, {catch_expr, _Anno, Expr}) ->
  expr_callees(Module, Expr);
expr_callees(Module, {'catch', _Anno, Expr}) ->
  expr_callees(Module, Expr);
expr_callees(Module, {generate, _Anno, _Pattern, Expr}) ->
  expr_callees(Module, Expr);
expr_callees(Module, {b_generate, _Anno, _Pattern, Expr}) ->
  expr_callees(Module, Expr);
expr_callees(_Module, _OtherExpr) ->
  [].

-spec qualifier_callees(Module, Qualifier) -> Result when
  Module :: module(),
  Qualifier :: erl_parse:abstract_expr(),
  Result :: [mfa_t()].
qualifier_callees(Module, Qualifier) ->
  expr_callees(Module, Qualifier).

-spec map_field_callees(Module, MapField) -> Result when
  Module :: module(),
  MapField :: erl_parse:abstract_expr(),
  Result :: [mfa_t()].
map_field_callees(Module, {map_field_assoc, _Anno, KeyExpr, ValueExpr}) ->
  exprs_callees(Module, [KeyExpr, ValueExpr]);
map_field_callees(Module, {map_field_exact, _Anno, KeyExpr, ValueExpr}) ->
  exprs_callees(Module, [KeyExpr, ValueExpr]).

-spec record_field_callees(Module, RecordField) -> Result when
  Module :: module(),
  RecordField :: erl_parse:abstract_expr(),
  Result :: [mfa_t()].
record_field_callees(Module, {record_field, _Anno, _FieldName, ValueExpr}) ->
  expr_callees(Module, ValueExpr).

-spec bin_element_callees(Module, BinElement) -> Result when
  Module :: module(),
  BinElement :: erl_parse:abstract_expr(),
  Result :: [mfa_t()].
bin_element_callees(Module, {bin_element, _Anno, ValueExpr, _Size, _TypeSpecifiers}) ->
  expr_callees(Module, ValueExpr).
