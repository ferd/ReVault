-module(revault_otel).
-export([start_active_span/1, start_active_span/2,
         end_active_span/0,
         extract_propagation_data/0, apply_propagation_data/1]).

-include_lib("opentelemetry_api/include/otel_tracer.hrl").

-define(KEY, {self(), ?MODULE}).

start_active_span(Name) ->
    start_active_span(Name, #{}).

start_active_span(Name, StartOpts) ->
    SpanCtx = otel_tracer:start_span(?current_tracer, Name, StartOpts),
    Ctx = otel_tracer:set_current_span(otel_ctx:get_current(), SpanCtx),
    Token = otel_ctx:attach(Ctx),
    Stack = case erlang:get(?KEY) of
        undefined -> [];
        Val -> Val
    end,
    erlang:put(?KEY, [{SpanCtx, Token}|Stack]),
    ok.

end_active_span() ->
    case erlang:get(?KEY) of
        undefined ->
            ok;
        [] ->
            ok;
        [{SpanCtx, Token} | Stack] ->
            _ = otel_tracer:set_current_span(otel_ctx:get_current(),
                                             otel_span:end_span(SpanCtx, undefined)),
            otel_ctx:detach(Token),
            erlang:put(?KEY, Stack),
            ok
    end.

extract_propagation_data() ->
    otel_propagator_text_map:inject([]).

apply_propagation_data(Data) when is_list(Data) ->
    otel_propagator_text_map:extract(Data).
