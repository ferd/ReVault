%%% @doc
%%% How to generate files and ensure we don't have duplicates,
%%% nor that we try to name files after directories.
%%%
%%% naive approach: just generate random paths and filenames
%%% and filter out the bad stuff so that it works. All subsequent
%%% generations need the content of the prior ones to know what existed
%%% or not.
%%%
%%% two-step approach: generate a random directory tree based on paths.
%%% Then, generate a random set of files that each belong to a random path
%%% of the tree; make sure through a lookup that the current pair does not
%%% match an existing path. All subsequent generations need the content of
%%% the prior ones to know what existed or not.
%%%
%%% model-based approach: create a tree/forest data structure, where each
%%% inner node is a directory, and each leaf is a file; at any given level,
%%% a file can't bear the same name as an inner node.
%%% Files are created or managed by picking a random path in the tree and
%%% inserting data in it. The tree represents the state and can be used to
%%% do all operations, but without caring about the filesystem.
%%%
%%% The advantage of the tree model is that it can be used for both stateless
%%% and stateful tests. Additional inner node types can be added to represent
%%% things such as symlinks (where supported), or used to create alterations
%%% such as "case sensitive duplicates" of given paths.
%%%
%%% The tree model could be activated in many ways:
%%%
%%% 1. `apply_model(Model, Dir)', which reconciliates the filesystem
%%%    with what the model should be.
%%% 2. `add_new_file(Model)' or `some_change(Model)' functions, which return
%%%    both the new model and a symbolic call of the form `{NewModel, Call}'
%%%    which can then be used to drive more changes.
%%% 3. `add_new_file(Model) -> SymbolicCall' and
%%%    `apply_call(Dir, Model, SymbolicCall) -> NewModel' function pairs, which
%%%    allows to split approach 2 in two distinct steps.
%%%
%%% Approach 1 is risky, because it essentially needs to manipulate the file
%%% system as much as any app would. It is super interesting for stateless
%%% properties and test setup, but would be useless for stateful properties
%%% while assuming that modifications to the model take place elsewhere.
%%%
%%% Approach 2 is interesting from the point of view that it lets us evolve
%%% a model, and create a zippable list of operations that can be applied,
%%% giving the benefits of Approach 1 but without the statefulness of the
%%% filesystem to reconcile. The problem is that it is essentially useless
%%% for stateful properties as well since commands are generated in a way
%%% that is distinct from their application and update in next_state as a
%%% callback.
%%%
%%% Approach 3 breaks things apart; the model is fully based on a statem-like
%%% ideal for properties, where the command can be generated from the current
%%% state, and its application to the model is done separatedly, as it would
%%% in the next_state callback of a statem or fsm property. This lowers its
%%% usability for stateless properties, forcing a kind of fold approach where
%%% commands are generated sequentially, flattened with a `?LET' to allow the
%%% model's reuse during next call, and so on recursively.
%%%
%%% It might be sufficient to choose Approach 3, and then provide a utilitary
%%% function `populate_dir(Dir) -> {Model, SymbolicCalls}' that provides
%%% both a model and an `eval()'-friendly list of calls to actualize it in
%%% stateless properties.
%%% @end
-module(dirmodel).
-include_lib("proper/include/proper.hrl").
         %% meta calls for property writers
-export([new/0, apply_call/3, has_files/1, type/3, hashes/2,
         %% mutation calls for propery writers
         file_add/2, file_change/2, file_delete/2,
         %% stateless helper
         populate_dir/1]).
%% private exports for testing and extending the model itself
-export([at/2, insert_at/3, delete_at/2, file/2, dir/1]).

-record(dir, {path :: string(),
              nodes = [] :: [dir() | file()]}).
-record(file, {path :: string(),
               content :: binary(),
               hash :: binary()}).
-type dir() :: #dir{}. % internal representation of a directory
-type file() :: #file{}. % internal representation of a file
-type tnode() :: dir() | file().
-type tree() :: dir(). % a tree's root
-type path() :: [name(), ...]. % a path to a file in the model
-type name() :: string(). % the fragment of a path (filename)

%% @doc Create an empty model tree.
-spec new() -> tree().
new() ->
    dir(".").

-spec populate_dir(file:filename()) ->
    proper_gen:generator(). % {tree(), [{call, _, _, _}]}
populate_dir(Dir) ->
    ?SIZED(Size, populate_dir(Dir, new(), [], Size)).

populate_dir(_Dir, T, Ops, Size) when Size =< 0 ->
    {T, Ops};
populate_dir(Dir, T, Ops, Size) ->
    ?LET(EvalT, T,
         ?LET(Op, file_add(Dir, EvalT),
              populate_dir(Dir, apply_call(Dir, EvalT, Op), [Op|Ops], Size-1))).

-spec file_add(file:filename(), tree()) ->
    proper_gen:generator(). % {call, _, _, _}
file_add(Dir, T) ->
    PathNameGen = ?SUCHTHAT({P,N}, {path(), dirgen:path_chars()},
                            at(T, P++[N]) =:= undefined),
    ?LET({{Path, Name}, Content}, {PathNameGen, binary()},
          {call, dirgen, write_file, [filename:join([Dir, filename:join(Path), Name]),
                                     Content, [sync, raw]]}).

-spec file_change(file:filename(), tree()) ->
    proper_gen:generator(). % {call, _, _, _}
file_change(Dir, T) ->
    ?LET(Path, oneof(file_paths(T)),
      begin
        {ok, #file{content = C}} = at(T, Path),
        ContentGen = ?SUCHTHAT(B, binary(), B =/= C),
        ?LET(Content, ContentGen,
             {call, dirgen, change_file, [filename:join([Dir, filename:join(Path)]),
                                         Content, [sync, raw]]})
      end).

-spec file_delete(file:filename(), tree()) ->
    proper_gen:generator(). % {call, _, _, _}
file_delete(Dir, T) ->
    ?LET(Path, oneof(file_paths(T)),
         {call, dirgen, delete_file,
          [filename:join([Dir, filename:join(Path)])]}).

-spec apply_call(file:filename(), tree(), {call, dirgen, atom(), list()}) ->
    tree().
apply_call(Dir, T, {call, dirgen, delete_file, [Path]}) ->
    Parts = suffix(filename:split(Dir), filename:split(Path)),
    delete_at(T, Parts);
apply_call(Dir, T, {call, dirgen, write_file, [Path, Contents | _]}) ->
    Parts = suffix(filename:split(Dir), filename:split(Path)),
    Root = lists:droplast(Parts),
    Name = lists:last(Parts),
    undefined = at(T, Parts), % new file
    insert_at(T, Root, file(Name, Contents));
apply_call(Dir, T, {call, dirgen, change_file, [Path, Contents | _]}) ->
    Parts = suffix(filename:split(Dir), filename:split(Path)),
    Root = lists:droplast(Parts),
    Name = lists:last(Parts),
    insert_at(delete_at(T, Parts), Root, file(Name, Contents)).

%% @doc Returns `true' if the model contains any file, and `false'
%% otherwise; subdirectories do not count towards files.
-spec has_files(tree()) -> boolean().
has_files(#file{}) -> true;
has_files(#dir{nodes=[]}) -> false;
has_files(#dir{nodes=Nodes}) -> lists:any(fun has_files/1, Nodes).

%% @doc Create a new file node. To be inserted within the model tree
%% with the help of `insert_at/3'.
-spec file(name(), binary()) -> file().
file(Name, Content) when is_list(Name), is_binary(Content) ->
    #file{path=Name,
          content=Content,
          hash = crypto:hash(sha256, Content)}.

%% @doc Create a new directory node. To be inserted within the model
%% tree with the help of `insert_at/3'.
-spec dir(name()) -> dir().
dir(Path) ->
    #dir{path=Path}.


%% @doc Extract the node type out of the model tree
%% according to its path. If the node is a file, also
%% return its content and hash.
-spec type(file:filename(), tree(), file:filename()) ->
    dir | {file, binary(), binary()} | undefined.
type(Dir, Tree, Path) ->
    NodeRes = at(
        Tree,
        suffix(filename:split(Dir), filename:split(Path))
    ),
    case NodeRes of
        {ok, #file{content=C, hash=H}} -> {file, H, C};
        {ok, #dir{}} -> dir;
        undefined -> undefined
    end.

hashes(Dir, Tree) ->
    Paths = file_paths(Tree),
    lists:sort(
      [{filename:join([Dir, filename:join(Path)]), Hash}
       || Path <- Paths,
          {ok, #file{hash=Hash}} <- [at(Tree, Path)]]
     ).

%% @doc Extract the node of the model tree according to its path.
%% Useful for mutations or comparing tree internals.
%%
%% This function relies on the internal `dirmodel' defintion
%% of a path, which is a list of the form
%% `[".", "subdir", "subsubdir", "file"]'
-spec at(tree(), path()) -> {ok, [tnode()] | file()} | undefined.
at(File = #file{path=Name}, [Name]) ->
    {ok, File};
at(Dir = #dir{path=Name}, [Name]) ->
    {ok, Dir};
at(#dir{path=Name, nodes=Nodes}, [Name, Next | Rest]) ->
    case find_node_by_name(Nodes, Next) of
        undefined -> undefined;
        Node -> at(Node, [Next|Rest])
    end;
at(_, _) ->
    undefined.

%% @doc allows the insertion of a new node within a model tree
%% based on its path. If you are looking to replace the node,
%% you should use `delete_at/2' first to remove it. This exclusive
%% addition of tree nodes aims to prevent silently transforming a
%% dir into a file or a file into a dir.
%% If a path is given such as `[A,B,C]' and `B' does not exist in
%% the model, it gets implicitly created as a directory node.
-spec insert_at(tree(), path(), tnode()) -> tree().
insert_at(D=#dir{path=Name, nodes=Nodes}, [Name], Node) ->
    NextName = find_name(Node),
    undefined = find_node_by_name(Nodes, NextName),
    D#dir{nodes=[Node|Nodes]};
insert_at(D=#dir{path=Name, nodes=Nodes}, [Name, Next | Rest], NewNode) ->
    case find_node_by_name(Nodes, Next) of
        undefined ->
            D#dir{nodes=[insert_at(dir(Next), [Next | Rest], NewNode) | Nodes]};
        Node ->
            D#dir{nodes=[insert_at(Node, [Next | Rest], NewNode) | Nodes -- [Node]]}
    end.

%% @doc allows the removal of a node within a model tree
%% based on its path.
%% If a path is not existing in the tree, the call errors out
%% since the intent is to quickly highlight faults in model usage.
%% It is also illegal to remove the root from the tree, since
%% this would result in an undefined model.
-spec delete_at(tree(), path()) -> tree().
delete_at(D=#dir{path=Name, nodes=Nodes}, [Name, Next | Rest]) ->
    case find_node_by_name(Nodes, Next) of
        undefined ->
            error(bad_delete);
        Node when Rest =:= [] ->
            D#dir{nodes=Nodes -- [Node]};
        Node when Rest =/= [] ->
            D#dir{nodes=[delete_at(Node, [Next|Rest]) | Nodes -- [Node]]}
    end.

%% @private
%% used during directory traversal to find the right entry
%% in a directory.
-spec find_node_by_name([dir()|file()], name()) -> undefined | dir() | file().
find_node_by_name([], _) -> undefined;
find_node_by_name([F=#file{path=Name} | _], Name) -> F;
find_node_by_name([D=#dir{path=Name} | _], Name) -> D;
find_node_by_name([_ | Rest], Name) -> find_node_by_name(Rest, Name).

%% @private
%% utility function to get the name of any node type
find_name(F = #file{}) -> F#file.path;
find_name(D = #dir{}) -> D#dir.path.

%% @private
%% Return all paths leading to files
file_paths(Tree) ->
    file_paths(Tree, [], [], []).

file_paths(#file{path=P}, Current, [], Acc) ->
    [lists:reverse(Current, [P]) | Acc];
file_paths(#file{path=P}, Current, [{Next,Node}|ToDo], Acc) ->
    file_paths(Node, Next, ToDo, [lists:reverse(Current, [P]) | Acc]);
file_paths(#dir{nodes=[]}, _, [], Acc) ->
    Acc;
file_paths(#dir{nodes=Ns, path=P}, Current, ToDo, Acc) ->
    Queue = [{[P|Current], N} || N <- Ns],
    case ToDo of
        [{Next,Node}|ToDoNext] ->
            file_paths(Node, Next, ToDoNext ++ Queue, Acc);
        [] ->
            case Queue of
                [] ->
                    Acc;
                [{Next,Node}|ToDoNext] ->
                    file_paths(Node, Next, ToDoNext, Acc)
            end
    end.

%% @private
%% Drop the common prefix of both lists;
%% we assume that `A' is longer or as long as `B'.
suffix([], Bs) -> ["."|Bs];
suffix([A|As], [A|Bs]) -> suffix(As, Bs);
suffix(_, Bs) -> ["."|Bs].

%% @private
%% Generator for dirmodel full paths
path() ->
    ?LET(P, dirgen:path(), ["." | P]). % always a ./ in dirmodel
