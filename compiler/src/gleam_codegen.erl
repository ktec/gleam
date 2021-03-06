-module(gleam_codegen).
-include("gleam_records.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([module/3]).

-define(is_uppercase_char(C), C >= $A andalso C =< $Z).

% Holds state used in code generation.
-record(env, {uid = 0}).

% TODO: Use the record below to store an export so that we can expose type
% information.
% Again, why did I want this?
% -record(export, {name, arity, type}).

-record(module_acc, {gen_tests = false, definitions = [], exports = []}).

module(#ast_module{statements = Statements}, ModName, Options) ->
  PrefixedName = "gleam_" ++ ModName,
  GenTests = proplists:get_value(gen_tests, Options, false),
  Acc0 = lists:foldl(fun module_statement/2,
                    #module_acc{gen_tests = GenTests},
                    Statements),

  Acc1 = add_main_test(Acc0, PrefixedName),
  Acc2 = add_module_info(Acc1, PrefixedName),
  Acc = Acc2,

  C_exports = Acc#module_acc.exports,
  C_definitions = Acc#module_acc.definitions,

  Attributes = [], % What are these?
  C_name = cerl:c_atom(PrefixedName),
  Core = cerl:c_module(C_name, C_exports, Attributes, C_definitions),
  {ok, Core}.

add_module_info(Acc0, Name) ->
  Acc1 = add_definition(Acc0, module_info(Name, [])),
  Acc2 = add_definition(Acc1, module_info(Name, [cerl:c_var(item)])),
  Acc3 = add_export(Acc2, export({"module_info", 0})),
  Acc4 = add_export(Acc3, export({"module_info", 1})),
  Acc4.

add_main_test(Acc, PrefixedName) ->
  case Acc of
    #module_acc{gen_tests = false} ->
      Acc;

    #module_acc{gen_tests = true} ->
      Body = cerl:c_call(cerl:c_atom(eunit), cerl:c_atom(test), [cerl:c_atom(PrefixedName)]),
      Name = cerl:c_fname(test, 0),
      Fun = cerl:c_fun([], Body),
      Export = export({"test", 0}),
      C_fun = {Name, Fun},
      add_export(add_definition(Acc, C_fun), Export)
  end.

add_definition(Acc = #module_acc{definitions = Defs}, Def) ->
  Acc#module_acc{definitions = [Def | Defs]}.

add_export(Acc = #module_acc{exports = Exports}, Export) ->
  Acc#module_acc{exports = [Export | Exports]}.

module_statement(Statement, Acc) ->
  case Statement of
    #ast_mod_fn{public = false} ->
      add_definition(Acc, named_function(Statement));

    #ast_mod_fn{name = Name, args = Args, public = true} ->
      Acc1 = add_definition(Acc, named_function(Statement)),
      add_export(Acc1, export(Name, length(Args)));

    #ast_mod_import{} ->
      Acc;

    #ast_mod_enum{} ->
      Acc;

    #ast_mod_external_type{} ->
      Acc;

    #ast_mod_external_fn{meta = Meta, public = Public, name = Name, args = Args,
                         target_fn = TargetFn, target_mod = TargetMod} ->
      FnArgs = lists:map(fun(X) -> #ast_fn_arg{name = [$a | integer_to_list(X)]} end,
                         lists:seq(1, length(Args))),
      ArgsVars = lists:map(fun(#ast_fn_arg{name = X}) -> #ast_var{meta = Meta, name = X, scope = local} end,
                           FnArgs),
      ModFn = #ast_mod_fn{meta = Meta,
                          public = Public,
                          name = Name,
                          args = FnArgs,
                          body = module_call(Meta, TargetMod, TargetFn, ArgsVars)},
      module_statement(ModFn, Acc);

    #ast_mod_test{} ->
      case Acc#module_acc.gen_tests of
        true ->
          {C_export, C_test} = test(Statement),
          add_export(add_definition(Acc, C_test), C_export);

        false ->
          Acc
      end
  end.

-spec module_call(meta(), string(), string(), [ast_expression()]) -> ast_expression().
module_call(Meta, ModName, FnName, Args) ->
  Fn = #ast_module_select{meta = Meta,
                          label = FnName,
                          module = #ast_var{scope = {constant, #ast_atom{value = ModName}}}},
  #ast_call{meta = Meta, fn = Fn, args = Args}.

test(#ast_mod_test{name = Name, body = Body}) ->
  TestName = Name ++ "_test",
  C_fun = named_function(#ast_mod_fn{name = TestName, args = [], body = Body}),
  C_export = export({TestName, 0}),
  {C_export, C_fun}.

export({Name, Arity}) when is_list(Name), is_integer(Arity) ->
  cerl:c_fname(list_to_atom(Name), Arity).

export(Name, Arity) when is_list(Name), is_integer(Arity) ->
  cerl:c_fname(list_to_atom(Name), Arity).

module_info(ModuleName, Params) when is_list(ModuleName) ->
  Body = cerl:c_call(cerl:c_atom(erlang),
                     cerl:c_atom(get_module_info),
                     [cerl:c_atom(list_to_atom(ModuleName)) | Params]),
  C_fun = cerl:c_fun(Params, Body),
  C_fname = cerl:c_fname(module_info, length(Params)),
  {C_fname, C_fun}.

named_function(#ast_mod_fn{name = Name, args = Args, body = Body}) ->
  Env = #env{},
  Arity = length(Args),
  C_fname = cerl:c_fname(list_to_atom(Name), Arity),
  {C_fun, _NewEnv} = function(Args, Body, Env),
  {C_fname, C_fun}.

function(Args, Body, Env) ->
  C_args = lists:map(fun(#ast_fn_arg{name = Name}) -> var(Name) end, Args),
  {C_body, NewEnv} = expression(Body, Env),
  C_fun = cerl:c_fun(C_args, C_body),
  {C_fun, NewEnv}.

var(Atom) ->
  cerl:c_var(list_to_atom(Atom)).

map_clauses(Clauses, Env) ->
  lists:mapfoldl(fun clause/2, Env, Clauses).

map_expressions(Expressions, Env) ->
  lists:mapfoldl(fun expression/2, Env, Expressions).


fn_call(Fn, Args, Env0) ->
  case Fn of
    #ast_var{name = Name, scope = module} ->
      C_fname = cerl:c_fname(list_to_atom(Name), length(Args)),
      {C_args, NewEnv} = map_expressions(Args, Env0),
      {cerl:c_apply(C_fname, C_args), NewEnv};

    % A function assigned to a local variable can be immediately called
    #ast_var{name = Name, scope = local} ->
      {C_args, Env1} = map_expressions(Args, Env0),
      C_var = cerl:c_var(list_to_atom(Name)),
      C_apply = cerl:c_apply(C_var, C_args),
      {C_apply, Env1};

    % A module that has been imported
    #ast_module_select{label = FnName, module = #ast_var{scope = {constant, Constant}}} ->
      {C_module, Env1} = expression(Constant, Env0),
      C_FnName = cerl:c_atom(FnName),
      {C_args, Env2} = map_expressions(Args, Env1),
      {cerl:c_call(C_module, C_FnName, C_args), Env2};

    % A module:function call where the module is assigned to a variable
    #ast_module_select{label = FnName, module = #ast_var{} = ModVar} ->
      {C_module, Env1} = expression(ModVar, Env0),
      C_FnName = cerl:c_atom(FnName),
      {C_args, Env2} = map_expressions(Args, Env1),
      {cerl:c_call(C_module, C_FnName, C_args), Env2};

    % A function value must be assigned to a variable because it can be called
    _ ->
      % TODO: We can check the lhs here to see if it is a fn(_)
      % capture. If it is we can avoid the creation of the intermediary
      % fn by directly rewriting the arguments.
      {C_fn, Env1} = expression(Fn, Env0),
      {C_args, Env2} = map_expressions(Args, Env1),
      {UID, Env3} = uid(Env2),
      Name = list_to_atom("$$gleam_fn_var" ++ integer_to_list(UID)),
      C_var = cerl:c_var(Name),
      C_apply = cerl:c_apply(C_var, C_args),
      C_let = cerl:c_let([C_var], C_fn, C_apply),
      {C_let, Env3}
  end.


expression(#ast_string{value = Value}, Env) when is_binary(Value) ->
  Chars = binary_to_list(Value),
  ByteSequence = lists:map(fun binary_string_byte/1, Chars),
  {cerl:c_binary(ByteSequence), Env};

expression(#ast_tuple{elems = Elems}, Env) ->
  {C_elems, NewEnv} = map_expressions(Elems, Env),
  {cerl:c_tuple(C_elems), NewEnv};

expression(#ast_atom{value = Value}, Env) when is_list(Value) ->
  {cerl:c_atom(Value), Env};

expression(#ast_int{value = Value}, Env) when is_integer(Value) ->
  {cerl:c_int(Value), Env};

expression(#ast_float{value = Value}, Env) when is_float(Value) ->
  {cerl:c_float(Value), Env};

expression(#ast_var{name = Name}, Env) when is_list(Name) ->
  {cerl:c_var(list_to_atom(Name)), Env};

expression(#ast_cons{head = Head, tail = Tail}, Env) ->
  {C_head, Env1} = expression(Head, Env),
  {C_tail, Env2} = expression(Tail, Env1),
  {cerl:c_cons(C_head, C_tail), Env2};

expression(#ast_operator{meta = Meta, name = "|>", args = [Lhs, Rhs]}, Env) ->
  Call = #ast_call{meta = Meta, fn = Rhs, args = [Lhs]},
  expression(Call, Env);

expression(#ast_operator{meta = Meta, name = Name, args = Args}, Env) ->
  ErlangName = case Name of
    "/" -> "div";
    "+." -> "+";
    "-." -> "-";
    "*." -> "*";
    "/." -> "/";
    "<=" -> "=<";
    "==" -> "=:=";
    "!=" -> "=/=";
    _ -> Name
  end,
  expression(module_call(Meta, "erlang", ErlangName, Args), Env);

expression(#ast_call{meta = Meta, fn = Fn, args = Args}, Env) ->
  NumHoles = length(lists:filter(fun(#ast_hole{}) -> true; (_) -> false end, Args)),
  case NumHoles of
    0 ->
      fn_call(Fn, Args, Env);

    1 ->
      % It's a fn(_) capture, convert it into a fn
      hole_fn(Meta, Fn, Args, Env);

    _ ->
      throw({error, multiple_hole_fn})
  end;

expression(#ast_assignment{pattern = #ast_var{name = Name}, value = Value, then = Then}, Env0) ->
  C_var = cerl:c_var(list_to_atom(Name)),
  {C_value, Env1} = expression(Value, Env0),
  {C_then, Env2} = expression(Then, Env1),
  {cerl:c_let([C_var], C_value, C_then), Env2};

expression(#ast_assignment{pattern = Pattern, value = Value, then = Then}, Env0) ->
  {C_pattern, Env1} = expression(Pattern, Env0),
  {C_value, Env2} = expression(Value, Env1),
  {C_then, Env3} = expression(Then, Env2),
  C_clause = cerl:c_clause([C_pattern], C_then),
  {cerl:c_case(C_value, [C_clause]), Env3};

expression(#ast_enum{name = Name, elems = []}, Env) when is_list(Name) ->
  AtomName = list_to_atom(to_snake_case(Name)),
  {cerl:c_atom(AtomName), Env};

expression(#ast_enum{name = Name, meta = Meta, elems = Elems}, Env) when is_list(Name) ->
  AtomValue = to_snake_case(Name),
  Atom = #ast_atom{meta = Meta, value = AtomValue},
  expression(#ast_tuple{elems = [Atom | Elems]}, Env);

expression(#ast_record_empty{}, Env) ->
  {cerl:c_map([]), Env};

expression(#ast_record_extend{} = Ast, Env) ->
  case flatten_record(Ast) of
    {flat, FlatFields} ->
      {C_pairs, NewEnv} = lists:mapfoldl(fun record_field/2,
                                         Env,
                                         maps:to_list(FlatFields)),
      Core = cerl:c_map(C_pairs),
      {Core, NewEnv};

    {extending, Parent, FlatFields} ->
      {C_pairs, Env1} = lists:mapfoldl(fun record_field/2,
                                       Env,
                                       maps:to_list(FlatFields)),
      C_extension = cerl:c_map(C_pairs),
      C_module = cerl:c_atom(maps),
      C_name = cerl:c_atom(merge),
      {C_parent, Env2} = expression(Parent, Env1),
      C_args = [C_parent, C_extension],
      Core = cerl:c_call(C_module, C_name, C_args),
      {Core, Env2}
  end;

expression(#ast_record_select{meta = Meta, record = Record, label = Label}, Env) ->
  Atom = #ast_atom{meta = Meta, value = Label},
  Call = module_call(Meta, "maps", "get", [Atom, Record]),
  expression(Call, Env);

expression(#ast_case{subject = Subject, clauses = Clauses}, Env) ->
  {C_subject, Env1} = expression(Subject, Env),
  {C_clauses, Env2} = map_clauses(Clauses, Env1),
  {cerl:c_case(C_subject, C_clauses), Env2};

expression(#ast_fn{args = Args, body = Body}, Env) ->
  function(Args, Body, Env);

expression(#ast_nil{}, Env) ->
  {cerl:c_nil(), Env};

% We generate a unique variable name for each hole to prevent
% the BEAM thinking two holes are the same.
expression(#ast_hole{}, Env) ->
  {UID, NewEnv} = uid(Env),
  Name = list_to_atom([$_ | integer_to_list(UID)]),
  {cerl:c_var(Name), NewEnv};

expression(#ast_seq{first = First, then = Then}, Env) ->
  {C_first, Env1} = expression(First, Env),
  {C_then, Env2} = expression(Then, Env1),
  C_seq = cerl:c_seq(C_first, C_then),
  {C_seq, Env2};

expression(Expressions, Env) when is_list(Expressions) ->
  {C_exprs, Env1} = map_expressions(Expressions, Env),
  [Head | Tail] = lists:reverse(C_exprs),
  C_seq = lists:foldl(fun cerl:c_seq/2, Head, Tail),
  {C_seq, Env1}.

flatten_record(Record) ->
  case Record of
    #ast_record_empty{} ->
      {flat, #{}};

    #ast_record_extend{parent = Parent, label = Label, value = Value} ->
      case flatten_record(Parent) of
        % The record has been completely flattened to a list of fields
        {flat, Fields} ->
          {flat, maps:put(Label, Value, Fields)};

        % The record could not be completely flattened. This is because at some
        % point the update syntax has been used, it is a not a record literal.
        {extending, TopParent, Fields} ->
          {extending, TopParent, maps:put(Label, Value, Fields)};

        {parent, TopParent} ->
          {extending, TopParent, #{Label => Value}}
      end;

    NotRecord ->
      {parent, NotRecord}
  end.

hole_fn(Meta, Fn, Args, Env) ->
  {UID, NewEnv} = uid(Env),
  VarName = "$$gleam_hole_var" ++ integer_to_list(UID),
  Var = #ast_var{name = VarName},
  NewArgs = lists:map(fun(#ast_hole{}) -> Var; (X) -> X end, Args),
  Call = #ast_call{meta = Meta, fn = Fn, args = NewArgs},
  Closure = #ast_fn{meta = Meta, args = [VarName], body = Call},
  expression(Closure, NewEnv).

record_field({Key, Val}, Env0) when is_list(Key) ->
  C_key = cerl:c_atom(Key),
  {C_val, Env1} = expression(Val, Env0),
  Core = cerl:c_map_pair(C_key, C_val),
  {Core, Env1}.

clause(#ast_clause{pattern = Pattern, value = Value}, Env) ->
  {C_pattern, Env1} = expression(Pattern, Env),
  {C_value, Env2} = expression(Value, Env1),
  C_clause = cerl:c_clause([C_pattern], C_value),
  {C_clause, Env2}.

to_snake_case(Chars) when is_list(Chars) ->
  to_snake_case(Chars, []).

to_snake_case(Input, Acc) ->
  case {Input, Acc} of
    {[C | Chars], []} when ?is_uppercase_char(C) ->
      to_snake_case(Chars, [C + 32]);

    {[C | Chars], _} when ?is_uppercase_char(C) ->
      to_snake_case(Chars, [C + 32, $_ | Acc]);

    {[C | Chars], _} ->
      to_snake_case(Chars, [C | Acc]);

    {[], _} ->
      lists:reverse(Acc)
  end.

c_list(Elems) ->
  Rev = lists:reverse(Elems),
  lists:foldl(fun cerl:c_cons/2, cerl:c_nil(), Rev).

binary_string_byte(Char) ->
  cerl:c_bitstr(cerl:c_int(Char),
                cerl:c_int(8),
                cerl:c_int(1),
                cerl:c_atom(integer),
                c_list([cerl:c_atom(unsigned), cerl:c_atom(big)])).

uid(#env{uid = UID} = Env) ->
  {UID, Env#env{uid = UID + 1}}.
