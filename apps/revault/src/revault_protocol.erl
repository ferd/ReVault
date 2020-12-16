%%% @doc
%%% This module contains the protocol definition for synchronizing multiple
%%% ReVault directories across the network.
%%%
%%% The high level messages to be supported are:
%%%
%%% <pre>
%%%  c    s
%%%    ->    {session, Vsn, SessionId}
%%%     <-   {session, Vsn, SessoinId}  % ack
%%%    ->    {new_id, SessionId}
%%%     <-   {id_forked, SessionId, Id}
%%%    ->    {retire_id, SessionId, Id}
%%%     <-   {id_merged, SessionId, Id}
%%%
%%%    ->    {scan, SessionId, DirName}
%%%     <-   {manifest, SessionId, DirName, [File]}
%%%    ->    {read, SessionId, DirName, FileName}
%%%    <->   {write, SessionId, DirName, File, StreamId}
%%%    <->   {stream, SessionId, StreamId, Data}
%%%    <->   {stream, SessionId, StreamId, done, Reason}
%%%
%%%    <->   {exit, SessionId}          % demand + ack, either side
%%%
%%% Where:
%%%   File :: {FileName, VersionEvent, Hash | deleted}
%%% </pre>
%%%
%%% These should ideally be handled in a way that is agnostic of the underlying
%%% transports (TCP, SSH) and their related concerns such as authentication,
%%% streaming semantics, and so on.
%%%
%%% We will, however, assume that per-session ordering exists for
%%% messages, and that in each case, there can be a clearly defined client and
%%% server role.
%%%
%%% The structure of this module is to provide a stateless (and easily
%%% testable) interface to protocol handling for the general internal logic
%%% that will be shared in all implementations.
%%%
%%% TODO: figure out how to conjugate the stateful calling of this module's
%%% stuff with the specific transport-related data.
%%% TODO: find if we could somehow make sendfile() work with this
%%% TODO: handle streaming for large files
%%% COuld we implement a gen_statem interface that transports use?
-module(revault_protocol).

%% -record(client, {}).
%% 
%% -spec client_init(Opts::term()) ->
%%          {{session, Version, SessionId}, State}.
%% client_init(_Opts) ->
%%     SessionId = uuid:uuid_to_string(uuid:get_v4()),
%% 
%% -spec client_init({session, Vsn, SessionId}, State) ->
%%          {new_id | scan, State}.
%% 
%% -spec client_new_id(State) ->
%%          {new_id, SessionId}.
%% -spec client_new_id({id_forked, SessionId, Id}, State) ->
%%          {scan, State}.
%% 
%% -spec client_scan(DirName, State) ->
%%          {{scan, SessionId, DirName}, State}.
%% -spec client_scan({manifest, SessionId, DirName, [File]}, State) ->
%%          {{manifest, DirName, [File]}, State}.
%% 
%% -spec client_manifest(Manifest | Cont, State) ->
%%          {Reply, State} when
%%       Reply :: {more, [Op, ...], Cont :: _}
%%              | done
%%       Op :: {read, SessionId, DirName, FileName}
%%           | {write, SessionId, DirName, File, StreamId}.
%% 
%% %% Streaming should be done async?
%% -spec client_stream(SessionId, StreamId, Data, State) ->
%%     {ok, State}.
%% 
%% -spec client_handle({write, SessionId, DirName, File, StreamId}, State) ->
%%         State
%%       ;            ({stream, SessionId, StreamId, Data}, State) ->
%%         State
%%       ;            ({stream, SessionId, StreamId, done, Reason}, State) ->
%%         State.
%% 
%% -spec client_exit(State) ->
%%         {{exit, SessionId}, State}.
%% -spec client_exit({exit, SessionId}, State) ->
%%         ok | {exit, SessionId}.
%% 
%% 
%% -spec server_init({session, Vsn, SessionId}) ->
%%         {{session, Vsn, SessionId}, State}.
%% 
%% -spec server_handle({new_id, SessionId}, State) ->
%%         {{id_forked, SessionId, Id}, State}
%%       ;            ({retire_id, SessionId}, State) ->
%%         {{id_merged, SessionId, Id}, State}
%%       ;            ({scan, SessionId, DirName}, State) ->
%%         {{manifest, SessionId, DirName, [File]}, State}
%%         %% TODO: what happens if we are told to handle files without diff?
%%       ;            ({read, SessionId, DirName, FileName}, State) ->
%%         {{write, SessionId, DirName, File, StreamId}, State}
%%       ;            ({write, SessionId, DirName, File, StreamId}, State) ->
%%         State
%%       ;            ({stream, SessionId, StreamId, Data}, State) ->
%%         State
%%       ;            ({stream, SessionId, StreamId, done, Reason}, State) ->
%%         State.
%% 
%% %% Streaming should be done async?
%% -spec server_stream(SessionId, StreamId, Data, State) ->
%%     {ok, State}.
%% 
%% -spec server_exit(State) ->
%%         {{exit, SessionId}, State}.
%% -spec server_exit({exit, SessionId}, State) ->
%%         ok | {exit, SessionId}.
