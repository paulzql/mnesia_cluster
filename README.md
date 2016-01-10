mnesia_cluster
=====

mnesia_cluster is a simple application easy cluster mnesia and auto create mnesia table. 

1. auto create mnesia table
2. auto split mnesia table
3. group mnesia cluster

Build
-----

    $ rebar3 compile
    
Start/Stop
------

 **1. start**
    
make sure start mnesia_cluster before use mnesia, recommend start it after node up.

    mnesia_cluster:start().
    
    
**2. stop (leave cluster)**

    mnesia_cluster:stop()

--------------------
Config Cluster
----
mnesia_cluster will load configed nodes and dynamic find node with same group,
**config node**
```erlang
%% set env before start
%% set other nodes (will find and connect other nodes)
application:set_env(mnesia_cluster, mnesia_nodes, ['node1','node2'...]).
%% set cluster group (before start mnesia_cluster will try to find same group cluster in nodes())
%% the same group means the node mnesia_cluster started and mnesia_group value is same.
application:set_env(mnesia_cluster, mnesia_group, group1).
%%
%% --------------------------
%% you can also config in node config file
[
  {mnesia_cluster,	[
		{mnesia_nodes, ['other@localhost']},
		{mnesia_group, group1}
	]}
].
```

--------------------
Define table
----

mnesia_cluster use module attribute 'mnesia_table' define table

**define table with tuple**

```erlang
-mnesia_table({
 TableName,   %% the name of table
 TableOptions %% the options of table (see mnesia:create_table)
}).
%% ------------------------------------------------------------
%% example:
%% ------------------------------------------------------------
-module(chat).
%% define message table
%% notice: left table copy type (ram_copies, disc_copies, disc_only_copies) with blank
%%         it will auto insert node() in the list when do mnesia:create_table
-mnesia_table({message, [{type, bag}, {disc_copies, []}, {attributes, [id, uid, content]}]}).
```
**define table by function**

```erlang
-mnesia_table(
 func   %% function name (make sure export func/0
).
@spec fun() -> [table_def()],
       table_def() :: {atom(), list()}
func() ->
 [].
%% ------------------------------------------------------------
%% example:
%% ------------------------------------------------------------
-module(chat).
-export([get_table/0]).
%% define message table
-mnesia_table(get_table).
get_table() ->
 [
   {message, [{type, bag}, {disc_copies, [node()]}, {attributes, recordinfo(message)}]},
   {users, [{type, set}, {disc_only_copies, [node()]}, {attributes, recordinfo(user)}]}
 ].
```
--------------------
add module to application
----
mnesia_cluster only discover modules in application file, so you need add module to application file

myapp.app
```erlang
{application, 'myapp',
 [{description, "test app"},
  {vsn, "0.1.0"},
  ....
  {modules, [chat]},
 ]}.

```

-------------------
