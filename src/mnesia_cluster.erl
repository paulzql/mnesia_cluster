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

-export([start/0, stop/0, config_nodes/0, mnesia_nodes/0]).

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
            Nodes = mnesia_nodes(),
            mnesia:stop(),
            case prestart(Nodes) of
                ok ->
                    mnesia:start(),
                    poststart(Nodes);
                E -> E
            end;
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
    Nodes = mnesia_nodes(),
    prestop(Nodes),
    mnesia:stop(),
    poststop(Nodes),
    application:stop(?APPLICATION),
    ok.

%%--------------------------------------------------------------------
%% @doc get configed nodes from mnesia_cluster env: mnesia_nodes
%% @spec
%% @end
%%--------------------------------------------------------------------
config_nodes() ->
    case application:get_env(?APPLICATION, ?MASTER) of
        {ok, Nodes} when is_list(Nodes) ->
            [N || N <- Nodes, N =/= node(), pong =:= net_adm:ping(N)];
        _ ->
            []
    end.

%%--------------------------------------------------------------------
%% @doc get cluster nodes
%%      configed nodes from mnesia_nodes env and other nodes with same group
%%      group defined in mnesia_group env (default is undefined)
%% @spec
%% @end
%%--------------------------------------------------------------------
mnesia_nodes() ->
    Nodes1 = config_nodes(),
    Group = application:get_env(?APPLICATION, ?GROUP),
    Nodes2 = [N || N <- nodes(), ok =:= rpc:call(N, application, ensure_started, [?APPLICATION]),
             Group =:= rpc:call(N, application, get_env, [?APPLICATION, ?GROUP])],
    lists:umerge(lists:sort(Nodes1), lists:sort(Nodes2)).

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc before mnesia start (create schema)
%% @spec
%% @end
%%--------------------------------------------------------------------
prestart([]) ->
    mnesia:create_schema([node()]),
    ok;
prestart(_Master) ->
    ok.

%%--------------------------------------------------------------------
%% @doc  after mensia start (create tables or copy tables)
%% @spec
%% @end
%%--------------------------------------------------------------------
poststart([]) ->
    case create_tables(table_defines()) of
        ok ->
            apply_all_module_attributes_of({mnesia_cluster, [create]}),
            ok;
        Error ->
            Error
    end;
poststart(Master) ->
    case lists:any(fun(N)->
                           {ok, [node()]} =:= rpc:call(N, mnesia, change_config, [extra_db_nodes, [node()]])
                   end, Master) of
        true ->
            mnesia:change_table_copy_type(schema, node(), disc_copies),
            case merge_tables(table_defines()) of
                ok ->
                    apply_all_module_attributes_of({mnesia_cluster, [merge]}),
                    ok;
                Error ->
                    Error
            end;
        _ ->
            {error, extra_db_nodes}
    end.

%%--------------------------------------------------------------------
%% @doc  before stop
%% @spec
%% @end
%%--------------------------------------------------------------------
prestop(_) ->
    apply_all_module_attributes_of({mensia_loader, [destroy]}).

%%--------------------------------------------------------------------
%% @doc  after stop (leave cluster)
%% @spec
%% @end
%%--------------------------------------------------------------------
poststop(Nodes) ->
    % clear replica before leaving the cluster
    lists:foreach(fun(N) ->
                      case node() of
                          N -> ok;
                          _ -> rpc:call(N, mnesia, del_table_copy, [schema, node()])
                      end
                  end,
                  Nodes).

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
        disc_only_copies ->
            mnesia:add_table_copy(Name, node(), disc_copies);
        Type ->
            mnesia:add_table_copy(Name, node(), Type)
    end,
    merge_tables(Others).

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
        [T|_] ->
            T
    end.

%%--------------------------------------------------------------------
%% @doc get all table definition from module attribute
%% example:  
%%         -mensia_table({tablename, [{type, bag}, {attributes, [uid,pass]}, {disc_copies, []}]}). 
%% @spec
%% @end
%%--------------------------------------------------------------------
table_defines() ->
    L = [TB || {Module, Attrs} <- all_module_attributes_of(mnesia_table),
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
    [Result || {Module, Attrs} <- all_module_attributes_of(Name),
               Result <- lists:map(fun(Attr) ->
                                            case Attr of
                                                {M, F, A} -> {{M, F, A}, apply(M, F, Args++A)};
                                                {F, A} -> {{Module, F, A}, apply(Module, F, Args++A)};
                                                F -> {{Module, F, Args}, apply(Module, F, Args)}
                                            end
                                   end, Attrs)];
apply_all_module_attributes_of(Name) ->
    apply_all_module_attributes_of({Name, []}).

all_module_attributes_of(Name) ->
    Modules = lists:append([M || {App, _, _} <- application:loaded_applications(),
                                 {ok, M} <- [application:get_key(App, modules)]]),
    lists:foldl(fun(Module, Acc) ->
                        case lists:append([Attr || {N, Attr} <- module_attributes_in(Module),
                                                   N =:= Name]) of
                            [] -> Acc;
                            Attr -> [{Module, Attr} | Acc]
                        end
                end, [], Modules).

module_attributes_in(Module) ->
    case catch Module:module_info(attributes) of
        {'EXIT', {undef, _}} -> [];
        {'EXIT', Reason} -> exit(Reason);
        Attributes -> Attributes
    end.
