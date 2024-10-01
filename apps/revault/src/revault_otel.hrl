-define(start_active_span(Name),
        revault_otel:start_active_span(Name)).

-define(start_active_span(Name, StartOpts),
        revault_otel:start_active_span(Name, StartOpts)).

-define(end_active_span(),
        revault_otel:end_active_span()).

-define(extract_propagation_data(),
        revault_otel:extract_propagation_data()).

-define(apply_propagation_data(Data),
        revault_otel:apply_propagation_data(Data)).
