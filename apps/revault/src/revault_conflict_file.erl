%%% @private This module contains utility functions around the manipulation
%%% of conflict files and naming schemes that end up being shared by
%%% a few modules (eg. `revault_dirmon_tracker' and `revault_fsm') and may
%%% require shared functionality, or easier interfacing for testing purposes.
%%% @end
-module(revault_conflict_file).
-export([marker/1, conflicting/2, working/1, hex/1, hexname/1]).

%% @doc create a conflict file name.
-spec marker(file:filename_all()) -> file:filename_all().
marker(Path) ->
    revault_file:extension(Path, ".conflict").

%% @doc create a conflicting version of a file name. Expects to receive
%% the hash.
-spec conflicting(file:filename_all(), binary()) -> file:filename_all().
conflicting(Path, Hash) ->
    revault_file:extension(Path, "." ++ hexname(Hash)).

%% @doc returns whether the current path may hint at a conflict file, and
%% if so, which working file is at its source.
-spec working(file:filename_all()) -> {marker | conflicting, file:filename_all()}
                                    | undefined.
working(Path) ->
    working(Path, filename:extension(Path)).


%% @doc turn a byte sequence into a hexadecimal representation
-spec hex(binary()) -> <<_:_*16>>.
hex(Hash) ->
    binary:encode_hex(Hash).

%% @doc turn a byte sequence into a subset of a hex representation
%% that can be used as a file path suffix for conflict files
-spec hexname(binary()) -> list().
hexname(Hash) ->
    %% This assertion makes gradualizer happy.
    Res = [_|_] = unicode:characters_to_list(string:slice(hex(Hash), 0, 8)),
    Res.

%%%%%%%%%%%%%%%
%%% PRIVATE %%%
%%%%%%%%%%%%%%%
working(File, Ext) when Ext == ".conflict"; Ext == <<".conflict">> ->
    {marker, drop_suffix(File, Ext)};
working(File, Ext) ->
    case string:length(Ext) == 9 andalso is_hex(drop_period(Ext)) of
        true ->
            {conflicting, drop_suffix(File, Ext)};
        _ ->
            undefined
    end.

drop_suffix(Path, Suffix) ->
    case string:split(Path, Suffix, trailing) of
        [Prefix, Tail] when Tail == <<>>; Tail == [] -> Prefix;
        _ -> Path
    end.

drop_period(Ext) ->
    case string:next_grapheme(Ext) of
        [$.|Rest] -> Rest;
        _ -> error({invalid_ext, Ext})
    end.

is_hex(Str) ->
    case string:next_grapheme(Str) of
        [C|T] when C >= $A, C =< $F; C >= $0, C =< $9 ->
            case T of
                [] -> true;
                <<>> -> true;
                _ -> is_hex(T)
            end;
        _ -> false
    end.

