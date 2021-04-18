%%%-------------------------------------------------------------------
%%% @author paul <qianlong.zhou@gmail.com>
%%% @copyright (C) 2016, paul
%%% @doc
%%%
%%% @end
%%% Created : 8 Jan 2016 by paul <qianlong.zhou@gmail.com>
%%%-------------------------------------------------------------------
-module(mnesia_cluster).

-define(MASTER, mnesia_nodes).
-define(GROUP, mnesia_group).
-define(APPLICATION, mnesia_cluster).
-define(WAIT_FOR_TABLES, 300000).

-export([start/0, stop/0, nodes/0, running_nodes/0,
         join/1, join/2, leave/0, leave/1,
         clean/0, update/1, delete/1]).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc start mnesia clustering, return ok if success otherwise return Error
%% @spec
%% @end
%%--------------------------------------------------------------------
start() ->
    case application:get_application() of
        {ok, ?APPLICATION} ->
            ensure_dir(),
            Nodes = config_nodes(),
            lists:foreach(fun net_kernel:connect_node/1, Nodes -- [node()]),
            ensure_ok(init_schema(Nodes)),
            Res = poststart(),
            application:ensure_all_started(reunion),
            Res;
        _ ->
            case application:start(?APPLICATION) of
                ok ->
                    ok;
                {error,{already_started, ?APPLICATION}} ->
                    ok;
                E -> E
            end
    end.

%%--------------------------------------------------------------------
%% @doc stop mnesia
%% @spec
%% @end
%%--------------------------------------------------------------------
stop() ->
    Nodes = config_nodes(),
    prestop(Nodes),
    case application:get_application() of
        {ok, ?APPLICATION} ->
            spawn(fun() ->
                          mnesia:stop(),
                          poststop(Nodes)
                  end),
            ok;
        _ ->
            mnesia:stop(),
            poststop(Nodes),
            application:stop(?APPLICATION),
            ok
    end.

clean() ->
    delete_schema().

%% @doc Join the mnesia cluster
join(Node) when Node =:= node() ->
    {error, cannot_join_to_self};
join(Node) ->
    join(Node, false).

join(Node, Force) ->
    Nodes = mnesia:system_info(db_nodes),
    RunningNodes = mnesia:system_info(running_db_nodes),
    case {lists:member(Node, Nodes),lists:member(Node, RunningNodes)} of
        {true, false} ->
            {error, joined_not_running};
        {_,true} ->
            {error, already_joined};
        _ ->
            mnesia:start(),
            case {mnesia:change_config(extra_db_nodes, [Node]), Force} of
                {{ok, []}, false} ->
                    {error, join_failed};
                {{ok, [_|_]}, _} ->
                    case copy_schema(node()) of
                        ok ->
                            poststart();
                        E ->
                            E
                    end;
                {Error, false} ->
                    Error;
                {_, _} ->
                    delete_schema(),
                    join(Node, false)
            end
    end.

leave() ->
    leave(node()).
%%--------------------------------------------------------------------
%% @doc leave node from cluster
%% @spec leave(atom()) -> ok | {error, Reason}.
%% @end
%%--------------------------------------------------------------------
leave(Node) ->
    %% find at least one running cluster node and instruct it to
    %% remove our schema copy which will in turn result in our node
    %% being removed as a cluster node from the schema, with that
    %% change being propagated to all nodes
    Nodes = mnesia:system_info(db_nodes),
    Ret =
    case [N || N <- Nodes, N =:= Node] of
        [] ->
            node_not_in_cluster;
        _ ->
            %% try to stop mneisa on that node
            rpc:call(Node, mnesia, stop, []),
            RunningNodes = [N1 || N1 <- mnesia:system_info(running_db_nodes), N1 =/= Node],
            lists:any(fun(Other) ->
                              case rpc:call(Other, mnesia, del_table_copy, [schema, Node]) of
                                  {atomic, ok} -> true;
                                  _ -> false
                              end
                      end, RunningNodes)
    end,
    case Ret of
        true ->
            rpc:call(Node, mnesia, delete_schema, [[Node]]),
            ok;
        E -> {error, E}
    end.

%%--------------------------------------------------------------------
%% @doc get cluster nodes
%% @spec nodes() -> [atom()].
%% @end
%%--------------------------------------------------------------------
nodes() ->
    mnesia:system_info(db_nodes).

%% get running nodes
running_nodes() ->
    mnesia:system_info(running_db_nodes).

%% add table define modules
%% note: need start cluster
update(Modules) ->
    poststart(Modules).

%% delete tables witch defined in modules
%% note: need start cluster
delete(Modules) ->
    delete_tables(table_defines(Modules)).

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc get configed nodes from mnesia_cluster env: mnesia_nodes
%% @spec
%% @end
%%--------------------------------------------------------------------
config_nodes() ->
    case application:get_env(?APPLICATION, ?MASTER) of
        {ok, Nodes} when is_list(Nodes) ->
            [N || N <- Nodes, N =/= node()];
        _ ->
            []
    end.

%% @doc Init mnesia schema or tables.
init_schema(Nodes) ->
    mnesia:start(),
    case mnesia:change_config(extra_db_nodes, Nodes -- [node()]) of
        {ok, []} ->
            case running_nodes() -- [node()] of
                [] ->
                    mnesia:stop(),
                    mnesia:create_schema([node()]),
                    mnesia:start();
                _ ->
                    ok
            end;
        {ok, _} ->
            copy_schema(node());
        Error ->
            Error
    end.


%% @doc Copy schema.
copy_schema(Node) ->
    case mnesia:change_table_copy_type(schema, Node, disc_copies) of
        {atomic, ok} ->
            ok;
        {aborted, {already_exists, schema, Node, disc_copies}} ->
            ok;
        {aborted, Error} ->
            {error, Error}
    end.

%% @doc Force to delete schema.
delete_schema() ->
    mnesia:stop(),
    mnesia:delete_schema([node()]).

%% ensure mneisa dir is ok
ensure_dir() ->
    Dir = mnesia:system_info(directory) ++ "/",
    case filelib:ensure_dir(Dir) of
        ok ->
            ok;
        {error, Reason} ->
            throw({error, {cannot_create_mnesia_dir, Dir, Reason}})
    end.


%% init tables
init_tables(master, Modules) ->
    case create_tables(table_defines(Modules)) of
        ok ->
            wait_tables(),
            apply_all_module_attributes_of({mnesia_cluster, [create]}),
            ok;
        Error ->
            throw(Error)
    end;
init_tables(slave, Modules) ->
    case merge_tables(table_defines(Modules)) of
        ok ->
            wait_tables(),
            apply_all_module_attributes_of({mnesia_cluster, [merge]}),
            ok;
        Error ->
            throw(Error)
    end.

%% post start after mnesia running
poststart() ->
    poststart(all).
poststart(Modules) ->
    case running_nodes() -- [node()] of
        [] ->
            init_tables(master, Modules);
        [_|_] ->
            init_tables(slave, Modules)
    end,
    %% wait for tables
    wait_tables().


%%--------------------------------------------------------------------
%% @doc  before stop
%% @spec
%% @end
%%--------------------------------------------------------------------
prestop(_) ->
    apply_all_module_attributes_of({mnesia_cluster, [destroy]}).

%%--------------------------------------------------------------------
%% @doc  after stop (leave cluster)
%% @spec
%% @end
%%--------------------------------------------------------------------
poststop(_) ->
    ok.

%%--------------------------------------------------------------------
%% @doc create tables from the table definition
%% @spec
%% @end
%%--------------------------------------------------------------------
create_tables([]) ->
    ok;
create_tables([{Name, Opts} | Others]) ->
    case mnesia:create_table(Name, Opts) of
        {atomic, ok} ->
            create_tables(Others);
        {aborted,{already_exists, Name}} ->
            create_tables(Others);
        Error ->
            Error
    end.

%%--------------------------------------------------------------------
%% @doc merge tables base the table definition
%% @spec
%% @end
%%--------------------------------------------------------------------
merge_tables([]) ->
    ok;
merge_tables([{Name, Opts} | Others]) ->
    case find_copy_type(Opts) of
        undefined ->
            ok;
        Type ->
            case mnesia:add_table_copy(Name, node(), Type) of
                {aborted, {no_exists, {Name, cstruct}}} ->
                    create_tables([{Name, Opts}]);
                _ ->
                    ok
            end
    end,
    merge_tables(Others).

%%--------------------------------------------------------------------
%% @doc delete tables base the table definition
%% @spec
%% @end
%%--------------------------------------------------------------------
delete_tables([]) ->
    ok;
delete_tables([{Name, _} | Others]) ->
    mnesia:del_table_copy(Name, node()),
    delete_tables(Others).

%%--------------------------------------------------------------------
%% @doc find the table copy type from the table options
%%      note: only pick {CopyType, []} option
%% @spec
%% @end
%%--------------------------------------------------------------------
find_copy_type(Opts) ->
    Types = lists:filter(fun({T, N}) ->
                                 K = lists:member(T, [disc_copies, disc_only_copies, ram_copies]),
                                 case {K, N} of
                                     {true, []} ->
                                         true;
                                     {true, Nodes} when is_list(Nodes) ->
                                         lists:member(node(), Nodes);
                                     _ ->
                                         false
                                 end
                         end, Opts),
    case Types of
        [] ->
            undefined;
        [{T,_}|_] ->
            T
    end.

%%--------------------------------------------------------------------
%% @doc get all table definition from module attribute
%% example:
%%         -mensia_table({tablename, [{type, bag}, {attributes, [uid,pass]}, {disc_copies, []}]}).
%% @spec
%% @end
%%--------------------------------------------------------------------
table_defines(all) ->
    table_defines(all_modules());

table_defines(Modules) when is_list(Modules) ->
    L = [TB || {Module, Attrs} <- all_module_attributes_of(mnesia_table, Modules),
               TB <- lists:map(fun(Attr) ->
                                       case Attr of
                                           {Name, Opts} when is_atom(Name);
                                                             is_list(Opts)->
                                               {Name, add_table_option(Opts)};
                                           F when is_atom(F) ->
                                               check_defines(apply(Module, F, []));
                                           X ->
                                               throw({error_table, {Module, X}})
                                       end
                               end, Attrs)],
    lists:flatten(L).

check_defines(Attrs) when is_list(Attrs) ->
    L = [{Name, Opts} || {Name, Opts} <- Attrs, not is_atom(Name), not is_list(Opts)],
    case L of
        [] ->
            Attrs;
        BL ->
            throw({invalid_table, BL})
    end;
check_defines(Attrs) ->
    check_defines([Attrs]).

add_table_option(Options) ->
    lists:map(fun({N, O}) ->
                      case lists:member(N, [disc_copies, disc_only_copies, ram_copies]) of
                          true ->
                              {N, [node()|O]};
                          false ->
                              {N, O}
                      end
              end, Options).

apply_all_module_attributes_of({Name, Args}) ->
    [Result || {Module, Attrs} <- all_module_attributes_of(Name, all_modules()),
               Result <- lists:map(fun(Attr) ->
                                            case Attr of
                                                {M, F, A} -> {{M, F, A}, apply(M, F, Args++A)};
                                                {F, A} -> {{Module, F, A}, apply(Module, F, Args++A)};
                                                F -> {{Module, F, Args}, apply(Module, F, Args)}
                                            end
                                   end, Attrs)];
apply_all_module_attributes_of(Name) ->
    apply_all_module_attributes_of({Name, []}).

all_module_attributes_of(Name, Modules) ->
    lists:foldl(fun(Module, Acc) ->
                        case lists:append([Attr || {N, Attr} <- module_attributes_in(Module),
                                                   N =:= Name]) of
                            [] -> Acc;
                            Attr -> [{Module, Attr} | Acc]
                        end
                end, [], Modules).

all_modules() ->
    lists:append([M || {App, _, _} <- application:loaded_applications(),
                       {ok, M} <- [application:get_key(App, modules)]]).

module_attributes_in(Module) ->
    case catch Module:module_info(attributes) of
        {'EXIT', {undef, _}} -> [];
        {'EXIT', Reason} -> exit(Reason);
        Attributes -> Attributes
    end.

%% ensure ok
ensure_ok(ok) -> ok;
ensure_ok({error, {_Node, {already_exists, _Node}}}) -> ok;
ensure_ok({badrpc, Reason}) -> throw({error, {badrpc, Reason}});
ensure_ok({error, Reason}) -> throw({error, Reason});
ensure_ok(Error) -> throw(Error).

%% wait tables
wait_tables() ->
    Tables = mnesia:system_info(local_tables),
    Timeout = application:get_env(?APPLICATION, wait_for_tables, ?WAIT_FOR_TABLES),
    logger:info("waiting for mnesia tables"),
    case mnesia:wait_for_tables(Tables, Timeout) of
        ok                   ->
            ok;
        {error, Reason}      ->
            {error, Reason};
        {timeout, BadTables} ->
            lists:foreach(fun (Tbl) ->
                                  logger:warning("force load table ~p", [Tbl]),
                                  yes = mnesia:force_load_table(Tbl)
                          end, BadTables),
            ok
    end.
