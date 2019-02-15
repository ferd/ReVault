%%% @doc
%%% Test suite for the `dirmodel' generator library with various calls
%%% as required.
%%% @end
-module(prop_dirmodel).
-include_lib("proper/include/proper.hrl").
-compile(export_all).
-define(DIR, "/tmp/fake/"). % should not write there for real

prop_added_file_found(doc) ->
    "Any file added to the model can be found back in it";
prop_added_file_found(opts) ->
    [{numtests, 10}].
prop_added_file_found() ->
    ?FORALL({Model, Op},
            ?LET({M,_Ops}, dirmodel:populate_dir(?DIR),
                 {M, dirmodel:file_add(?DIR, M)}),
      begin
        {call, _, write_file, [Path|_]} = Op,
        NewModel = dirmodel:apply_call(?DIR, Model, Op),
        Parts = normalize(?DIR, Path),
        dirmodel:at(Model, Parts) =:= undefined
        andalso
        is_tuple(dirmodel:at(NewModel, Parts))
      end).

prop_deleted_file_gone(doc) ->
    "Any file deleted from the model won't be found again";
prop_deleted_file_gone(opts) ->
    [{numtests, 10}].
prop_deleted_file_gone() ->
    ?FORALL({Model, Op},
            ?LET({M,_Ops}, dirmodel:populate_dir(?DIR),
                 {M, dirmodel:file_delete(?DIR, M)}),
      begin
        {call, _, delete_file, [Path|_]} = Op,
        NewModel = dirmodel:apply_call(?DIR, Model, Op),
        Parts = normalize(?DIR, Path),
        is_tuple(dirmodel:at(Model, Parts))
        andalso
        dirmodel:at(NewModel, Parts) =:= undefined
      end).

prop_changed_file(doc) ->
    "Any file changed from the model is detected as such";
prop_changed_file(opts) ->
    [{numtests, 10}].
prop_changed_file() ->
    ?FORALL({Model, Op},
            ?LET({M,_Ops}, dirmodel:populate_dir(?DIR),
                 {M, dirmodel:file_change(?DIR, M)}),
      begin
        {call, _, change_file, [Path|_]} = Op,
        NewModel = dirmodel:apply_call(?DIR, Model, Op),
        Parts = normalize(?DIR, Path),
        {ok, F1} = dirmodel:at(Model, Parts),
        {ok, F2} = dirmodel:at(NewModel, Parts),
        F1 =/= F2
      end).

normalize(Base, Path) ->
    ["." | filename:split(string:prefix(Path, Base))].
