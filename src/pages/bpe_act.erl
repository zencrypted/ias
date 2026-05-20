-module(bpe_act).
-copyright('Maxim Sokhatsky').
-include_lib("n2o/include/n2o.hrl").
-include_lib("nitro/include/nitro.hrl").
-include_lib("form/include/meta.hrl").
-include_lib("bpe/include/bpe.hrl").
-include("act.hrl").
-export([event/1]).

event(init) ->
   nitro:clear(tableHead),
   nitro:clear(tableRow),
   CX = get(context),
   Req = CX#cx.req,
   Bin = case Req of
              #{qs := QS} ->
                  proplists:get_value(<<"p">>, uri_string:dissect_query(nitro:to_binary(QS)));
              #{query_string := QS} ->
                  proplists:get_value(<<"p">>, uri_string:dissect_query(nitro:to_binary(QS)));
              _ ->
                  nitro:qc(p)
         end,
   Id = case Bin of
             undefined -> "";
             _ -> nitro:to_list(Bin)
        end,
   case kvs:get("/bpe/proc",Id) of
        {error,not_found} ->
           nitro:update(n, "ERR"),
           nitro:update(desc, "No process found."),
           nitro:update(num, "ERR");
        _ ->
           nitro:insert_top(tableHead, header()),
           nitro:update(n, Bin),
           nitro:update(num, Bin),
   History = bpe:hist(Id),
 [ begin 
     {step,No,Step} = I#hist.id,
     Name = nitro:to_list(No)++"-"++nitro:to_list(Step),
     Trace = bpe_trace:new(form:atom([trace,Name]),I,[]),
     nitro:insert_bottom(tableRow, Trace)
   end 
   || I <- History ]
   end;

event(_) ->
   ok.

header() ->
  #panel{id=header,class=th,body=
    [#panel{class=column6,body="State"},
     #panel{class=column6,body="Documents"}]}.

