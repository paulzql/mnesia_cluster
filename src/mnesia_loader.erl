-module(mnesia_loader).

-export([start_mnesia/0, stop_mnesia/0, config_nodes/0, mnesia_nodes/0]).

-define(MASTER, mnesia_nodes).
-define(GROUP, mnesia_group).
-define(APPLICATION, mnesia_loader).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc start mnesia clustering, return ok if success otherwise return Error
%% @spec
%% @end
%%--------------------------------------------------------------------
start_mnesia() ->
	Nodes = mnesia_nodes(),
	mnesia:stop(),
	case prestart(Nodes) of
		ok ->
			mnesia:start(),
			poststart(Nodes);
		Error ->
			Error
	end.

%%--------------------------------------------------------------------
%% @doc stop mnesia
%% @spec
%% @end
%%--------------------------------------------------------------------
stop_mnesia() ->
	Nodes = mnesia_nodes(),
	prestop(Nodes),
	mnesia:stop(),
	poststop(Nodes),
	ok.

%%--------------------------------------------------------------------
%% @doc get configed nodes from mnesia_loader env: mnesia_nodes
%% @spec
%% @end
%%--------------------------------------------------------------------
config_nodes() ->
	case application:get_env(?APPLICATION, ?MASTER) of
		Nodes when is_list(Nodes) ->
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
			apply_all_module_attributes_of({mnesia_loader, [create]}),
			ok;
		Error ->
			Error
	end;
poststart(Master) ->
	case lists:any(fun(N)->
						   {ok, node()} =:= rpc:call(N, mnesia, change_config, [extra_db_nodes, [node()]])
				   end, Master) of
		true ->
			mnesia:change_table_copy_type(schema, node(), disc_copies),
			case merge_tables(table_defines()) of
				ok ->
					apply_all_module_attributes_of({mnesia_loader, [merge]}),
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
%%         -mensia_loader({tablename, [{type, bag}, {attributes, [uid,pass]}, {disc_copies, []}]}). 
%% @spec
%% @end
%%--------------------------------------------------------------------
table_defines() ->
	[TB || {Module, Attrs} <- all_module_attributes_of(mnesia_table),
			   TB <- lists:map(fun(Attr) ->
io:format("attr:~p~n", [Attr]),
									   case Attr of
										   {Name, Opts} -> {Name, Opts};
										   F when is_atom(F) ->
											   case apply(Module, F, []) of
												   {Name, Opts} ->
													   {Name, Opts};
												   R ->
													   throw({error_table, {Module, F, R}})
											   end;
										   X ->
											   throw({error_table, {Module, X}})
									   end
							   end, Attrs)].



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
