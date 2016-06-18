mnesia_cluster
=====

mnesia_cluster is a simple application easy cluster mnesia and auto create mnesia table. 

1. auto create mnesia table
2. auto merge mnesia table
3. cluster mnesia

Build
-----

    $ rebar3 compile
    
Start/Stop
------

 **1. start**
    
make sure start mnesia_cluster before use mnesia, recommend start it after node up.

    mnesia_cluster:start().
    
    
**2. stop**

    mnesia_cluster:stop()

--------------------
Config Cluster
----
mnesia_cluster will load configed nodes and dynamic join cluster

set env before start
```erlang
%% set other nodes (will find and connect other nodes)
application:set_env(mnesia_cluster, mnesia_nodes, ['node1','node2'...]).

```
you can also config in .config file
```erlang
[
  {mnesia_cluster,	[
		{mnesia_nodes, ['other@localhost','other2@localhost']}
	]}
].
```

--------------------
Join Cluster
----
```erlang
    %% try to join 'test1@xx.com' cluster
    %% note: this will clean current node's data and copy data from 'test1@xx.com'
    mnesia_cluster:join('test1@xx.com')
```
--------------------
Leave cluster
----
```erlang
    %% if leave successful, will delete current node's data
    mnesia_cluster:leave()
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

----------------
Dynamic add defined table from modules
----
```erlang
    %% make sure module [test1,test2] has table define
    mnesia_cluster:update([test1,test2]).
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

