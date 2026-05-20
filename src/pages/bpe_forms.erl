-module(bpe_forms).
-copyright('Maxim Sokhatsky').
-export([event/1]).
-include_lib("n2o/include/n2o.hrl").
-include_lib("nitro/include/nitro.hrl").

-record(program, {id = [],next = [],prev = [],
        name = [],
        type = telecom,
        formula = [],
        date = {{2022,11,19},{1,1,1}},
        etc = []
       }).

event({client,{form,Module,ColId}}) ->
    nitro:insert_bottom(
      ColId,
      #panel{
        class = "form-card",
        body = [
          #h3{body = nitro:to_binary(Module)},
          #h5{body = Module:doc(), style = "margin-bottom: 10px;"},
          #panel{body = form:new(Module:new(Module, Module:id(), []), Module:id()), class = form}
        ]
      }
    );

event(init) ->
    nitro:clear(stand),
    nitro:insert_bottom(stand, #panel{id = col1, class = "form-column"}),
    nitro:insert_bottom(stand, #panel{id = col2, class = "form-column"}),
    nitro:insert_bottom(stand, #panel{id = col3, class = "form-column"}),
    Registry = application:get_env(form, registry, []),
    lists:foldl(fun(Mod, Index) ->
        ColId = case Index rem 3 of
            0 -> col1;
            1 -> col2;
            2 -> col3
        end,
        self() ! {client, {form, Mod, ColId}},
        Index + 1
    end, 0, Registry),
    ok;

event(X) ->
    logger:info("EVENT: ~p", [X]),
    case X of
        {Evt, _} when Evt =:= 'CreateClient'; Evt =:= 'TypeClient' ->
            logger:info("Client.Form fields: surnames=~p, names=~p, phone=~p, type=~p",
                        [nitro:q(surnames_client_none),
                         nitro:q(names_client_none),
                         nitro:q(phone_client_none),
                         nitro:q(type_client_none)]);

        {Evt, _} when Evt =:= 'CreateTariff'; Evt =:= 'TypeProgram' ->
            logger:info("Program.Form fields: name=~p, type=~p, date=~p, formula=~p",
                        [nitro:q(name_program_none),
                         nitro:q(type_program_none),
                         nitro:q(date_program_none),
                         nitro:q(formula_program_none)]);

        {Evt, _} when Evt =:= 'CreateAccount'; Evt =:= 'TypeAccount'; Evt =:= 'ProgramAccount' ->
            ProgramId = nitro:q(program_account_none),
            Tariffs = kvs:all("/exo/tariffs"),
            ProgramRecord = case lists:filter(fun(P) ->
                nitro:to_binary(P#program.id) =:= nitro:to_binary(ProgramId)
            end, Tariffs) of
                [Match|_] -> Match;
                [] -> undefined
            end,
            logger:info("Account.Form fields: name=~p, edrpou=~p, type=~p, program=~p, date=~p",
                        [nitro:q(name_account_none),
                         nitro:q(edrpou_account_none),
                         nitro:q(type_account_none),
                         ProgramRecord,
                         nitro:q(date_account_none)]);

        {Evt, _} when Evt =:= 'Spawn'; Evt =:= 'Discard'; Evt =:= 'TypeProcess' ->
            logger:info("BPE.Create fields: process_type=~p",
                        [nitro:q(process_type_process_none)]);

        _ ->
            ok
    end.
