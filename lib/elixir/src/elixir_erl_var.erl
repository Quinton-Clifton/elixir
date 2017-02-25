%% Convenience functions used to manipulate scope and its variables.
-module(elixir_erl_var).
-export([translate/4, build/2, context_info/1,
  load_binding/2, dump_binding/2,
  mergev/2, mergec/2, merge_vars/2, merge_opt_vars/2,
  warn_unsafe_var/4, warn_underscored_var_access/3, format_error/1
]).
-include("elixir.hrl").

%% VAR HANDLING

translate(Meta, Name, Kind, S) when is_atom(Kind); is_integer(Kind) ->
  Ann = ?ann(Meta),
  Tuple = {Name, Kind},
  Vars = S#elixir_erl.vars,

  {Current, Exists, Safe} =
    case maps:find({Name, Kind}, Vars) of
      {ok, {VarC, _, VarS}} -> {VarC, true, VarS};
      error -> {nil, false, true}
    end,

  case S#elixir_erl.context of
    match ->
      MatchVars = S#elixir_erl.match_vars,

      case Exists andalso maps:get(Tuple, MatchVars, false) of
        true ->
          warn_underscored_var_repeat(Meta, S#elixir_erl.file, Name, Kind),
          {{var, Ann, Current}, S};
        false ->
          %% We attempt to give vars a nice name because we
          %% still use the unused vars warnings from erl_lint.
          %%
          %% Once we move the warning to Elixir compiler, we
          %% can name vars as _@COUNTER.
          {NewVar, Counter, NS} =
            if
              Kind /= nil ->
                build('_', S);
              true ->
                build(Name, S)
            end,

          FS = NS#elixir_erl{
            vars=maps:put(Tuple, {NewVar, Counter, true}, Vars),
            match_vars=maps:put(Tuple, true, MatchVars),
            export_vars=case S#elixir_erl.export_vars of
              nil -> nil;
              EV  -> maps:put(Tuple, {NewVar, Counter, true}, EV)
            end
          },

          {{var, Ann, NewVar}, FS}
      end;
    _  when Exists ->
      warn_underscored_var_access(Meta, S#elixir_erl.file, Name),
      warn_unsafe_var(Meta, S#elixir_erl.file, Name, Safe),
      {{var, Ann, Current}, S}
  end.

build(Key, #elixir_erl{counter=Counter} = S) ->
  Cnt =
    case maps:find(Key, Counter) of
      {ok, Val} -> Val + 1;
      error -> 1
    end,
  {list_to_atom(atom_to_list(Key) ++ "@" ++ integer_to_list(Cnt)),
   Cnt,
   S#elixir_erl{counter=maps:put(Key, Cnt, Counter)}}.

context_info(Kind) when Kind == nil; is_integer(Kind) -> "";
context_info(Kind) -> io_lib:format(" (context ~ts)", [elixir_aliases:inspect(Kind)]).

warn_underscored_var_repeat(Meta, File, Name, Kind) ->
  Warn = should_warn(Meta),
  case atom_to_list(Name) of
    "_@" ++ _ ->
      ok; %% Automatically generated variables
    "_" ++ _ when Warn ->
      elixir_errors:form_warn(Meta, File, ?MODULE, {unused_match, Name, Kind});
    _ ->
      ok
  end.

warn_unsafe_var(Meta, File, Name, Safe) ->
  Warn = should_warn(Meta),
  if
    (not Safe) and Warn ->
      elixir_errors:form_warn(Meta, File, ?MODULE, {unsafe_var, Name});
    true ->
      ok
  end.

warn_underscored_var_access(Meta, File, Name) ->
  Warn = should_warn(Meta),
  case atom_to_list(Name) of
    "_@" ++ _ ->
      ok; %% Automatically generated variables
    "_" ++ _ when Warn ->
      elixir_errors:form_warn(Meta, File, ?MODULE, {underscore_var_access, Name});
    _ ->
      ok
  end.

should_warn(Meta) ->
  lists:keyfind(generated, 1, Meta) /= {generated, true}.

%% SCOPE MERGING

%% Receives two scopes and return a new scope based on
%% the second with their variables merged.

mergev(S1, S2) ->
  S2#elixir_erl{
    vars=merge_vars(S1#elixir_erl.vars, S2#elixir_erl.vars),
    export_vars=merge_opt_vars(S1#elixir_erl.export_vars, S2#elixir_erl.export_vars)
 }.

%% Receives two scopes and return the first scope with
%% counters and flags from the later.

mergec(S1, S2) ->
  S1#elixir_erl{
    counter=S2#elixir_erl.counter,
    caller=S2#elixir_erl.caller
 }.

%% Mergers.

merge_vars(V, V) -> V;
merge_vars(V1, V2) ->
  merge_maps(fun var_merger/3, V1, V2).

merge_opt_vars(nil, _C2) -> nil;
merge_opt_vars(_C1, nil) -> nil;
merge_opt_vars(C, C)     -> C;
merge_opt_vars(C1, C2)   ->
  merge_maps(fun var_merger/3, C1, C2).

var_merger(_Var, {_, V1, _} = K1, {_, V2, _}) when V1 > V2 -> K1;
var_merger(_Var, _K1, K2) -> K2.

merge_maps(Fun, Map1, Map2) ->
  maps:fold(fun(K, V2, Acc) ->
    V =
      case maps:find(K, Acc) of
        {ok, V1} -> Fun(K, V1, V2);
        error -> V2
      end,
    maps:put(K, V, Acc)
  end, Map1, Map2).

%% BINDINGS

load_binding(Binding, Scope) ->
  {NewBinding, NewKeys, NewVars, NewCounter} = load_binding(Binding, [], [], #{}, 0),
  {NewBinding, NewKeys, Scope#elixir_erl{
    vars=NewVars,
    counter=#{'_' => NewCounter}
 }}.

load_binding([{Key, Value} | T], Binding, Keys, Vars, Counter) ->
  Actual = case Key of
    {_Name, _Kind} -> Key;
    Name when is_atom(Name) -> {Name, nil}
  end,
  InternalName = list_to_atom("_@" ++ integer_to_list(Counter)),
  load_binding(T,
    orddict:store(InternalName, Value, Binding),
    ordsets:add_element(Actual, Keys),
    maps:put(Actual, {InternalName, 0, true}, Vars), Counter + 1);
load_binding([], Binding, Keys, Vars, Counter) ->
  {Binding, Keys, Vars, Counter}.

dump_binding(Binding, #elixir_erl{vars=Vars}) ->
  maps:fold(fun
    ({Var, Kind} = Key, {InternalName, _, _}, Acc) when is_atom(Kind) ->
      Actual = case Kind of
        nil -> Var;
        _   -> Key
      end,

      Value = case orddict:find(InternalName, Binding) of
        {ok, V} -> V;
        error -> nil
      end,

      orddict:store(Actual, Value, Acc);
    (_, _, Acc) ->
      Acc
  end, [], Vars).

%% Errors

format_error({unused_match, Name, Kind}) ->
  io_lib:format("the underscored variable \"~ts\"~ts appears more than once in a "
                "match. This means the pattern will only match if all \"~ts\" bind "
                "to the same value. If this is the intended behaviour, please "
                "remove the leading underscore from the variable name, otherwise "
                "give the variables different names", [Name, context_info(Kind), Name]);

format_error({unsafe_var, Name}) ->
  io_lib:format("the variable \"~ts\" is unsafe as it has been set inside "
                "one of: case, cond, receive, if, and, or, &&, ||. "
                "Please explicitly return the variable value instead. For example:\n\n"
                "    case integer do\n"
                "      1 -> atom = :one\n"
                "      2 -> atom = :two\n"
                "    end\n\n"
                "should be written as\n\n"
                "    atom =\n"
                "      case integer do\n"
                "        1 -> :one\n"
                "        2 -> :two\n"
                "      end\n\n"
                "Unsafe variable found at:", [Name]);

format_error({underscore_var_access, Name}) ->
  io_lib:format("the underscored variable \"~ts\" is used after being set. "
                "A leading underscore indicates that the value of the variable "
                "should be ignored. If this is intended please rename the "
                "variable to remove the underscore", [Name]).
