-module(server_coordinator).
-include("clusterdefs.hrl").
-behaviour(gen_fsm).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% This file describes the server coordinator process.  It interfaces with the client coordinator processes
% and asks them for job information.  It processes the job information using the specified calculation function
% and returns data back to the client coordinator.
% It's able to detect when a calculation has failed and retry it.  If the calculation fails several times, an error
% message is returned in place of the output data.
% There are several similarities between the behaviour of the client and server coordinators, but they are different
% enough that they can't both be based on the same generic code.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%%%%% Messages used in this module %%%%%%%
%% -> client-to-server notification of having data ready to process
%%     {client_data, Pid}
%% -> change number of worker processes
%%     {change_worker_number, Number}
%% -> get the number of worker processes
%%     get_worker_number
%% -> incoming chunks from client coordinator
%%     {process_chunks, [Chunk1, Chunk2, ... ]}
%% -> process exit message from calculation process
%%     {'EXIT', CalculationPid, normal}
%% -> abnormal termination exit message from calculation process
%%     {'EXIT', CalculationPid, Reason}
%% -> set the number of chunks to request from a client coordinator
%%     {set_numchunks, Size}
%% -> get the number of chunks that will be requested from a client coordinator
%%     {get_numchunks}
%% -> cleanup after a job and execute the postcalculation functions
%%     {job_cleanup, {ClientCoordinatorPid, JobRef, PostCalcFunctionMFA}}
%% <- server-to-client existence notification
%%     {server_up, self()}
%% <- request chunks from client coordinator
%%     {send_chunks, ServerCoordinatorPid, NumChunks}
%% -> calculation completion, sent to client coordinator by calculator module, but sometimes from
%%    the server_coordinator in the case of complete calculation failure
%%     {calc_done, ServerCoordinatorPid, OutChunk}

%%%%%%% Data Structures used in this module %%%%%%%
%% - ChunkLoads = [Load1, Load2, Load3, ... , LoadN]
%%   where LoadN = [Chunk1,Chunk2,Chunk3, ... , ChunkM]
%%   where ChunkM = {ClientCoordinatorPid, Ref, Seq, Functions, InputData}
%%   where InputData = [Data1, Data2, Data3, ...]
%%   where ClientCoordinatorPid is the PID of the originating client coordinator, Ref is the job reference generated by that coordinator, Seq is an integer sequence number, and InputData is a list of the data elements to process
%% - CalculationsInProgress is a dictionary of the following form:
%%   key: Spawned Pid, value: {Attempt, Chunk}
%% - ProcessedJobs is a dictionary of the following form:
%%   key: {ClientCoordinatorPid, JobReference}, value: {PreCalculationJobRun}

%%%%%%%%%%%%%%%%%%%%%%%% Defines %%%%%%%%%%%%%%%%%%%%%%%%
-define(CALCFAILMESSAGE,calculation_failure). % message to return in place of output data for failed calculations
-define(MAXATTEMPTS,2). % number of times to retry failed calculations

%%%%%%%%%%%%%%%%%%%%%%%% Records %%%%%%%%%%%%%%%%%%%%%%%%

% FSM State
-record(state,{
	chunkloads=[],
	calculationsinprogress=dict:new(),
	workers=0,
	processedjobs=dict:new(),
	maxworkers=0,
	numchunks=?DEFAULT_NUM_CHUNKS
}).

%%%%%%%%%%%%%%%%%%%%%%%% Exports %%%%%%%%%%%%%%%%%%%%%%%%
% GEN_FSM
-export([start_link/1, init/1, handle_event/3, handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).
-export([waiting/2, feeding/2]).
% public functions
-export([change_worker_number/2,get_worker_number/1,test/0,set_numchunks/2, get_numchunks/1]).

%%%%%%%%%%%%%%%%%%%%%%%% GEN_FSM functions%%%%%%%%%%%%%%%%%%%%%%%%

start_link(ClusterName) ->
	gen_fsm:start_link(?MODULE,ClusterName,[]).

init(ClusterName) ->
	% register the server using a unique name
	utils:register_server(ClusterName),
	% figure out what client coordinators are in the cluster
	ClientCoordinators = utils:get_clients(ClusterName),
	%  notify them that the server coordinator is ready to accept jobs
	[gen_fsm:send_all_state_event(Pid, {server_up, self()}) || Pid <- ClientCoordinators],
	% set the number of workers to be the number of CPUs in the system
	% start the CPU utilization supervisor, and keep it running in case it comes in handy in the future
	cpu_sup:start(),
	% ask it for the per-CPU information, and just count the number of elements it returns
	NumCPUs = length(cpu_sup:util([per_cpu])),
	% start in the waiting state
	{ok, waiting, #state{maxworkers=NumCPUs}}.

%%%--------- Functions that handle asynchronous events

% process a load of new chunks from a client
% this matches if the Chunks is empty, and does nothing
handle_event({process_chunks, []}, StateName, State) -> {next_state, StateName, State};
% this matches if chunks are present
handle_event({process_chunks, Chunks}, StateName, State) ->
	% check to see if the precalculation function for these chunks has already been run
	FirstChunk = hd(Chunks),
	{ClientCoordinatorPid, Ref, _, _, _} = FirstChunk,
	NewState = case dict:find({ClientCoordinatorPid, Ref},State#state.processedjobs) of
		% if not, then run the precalculation function before proceeding
		error ->
			{_, _, _, Functions, _} = FirstChunk,
			{PreCalcFunctionMFA, _, _} = Functions,
			case PreCalcFunctionMFA of
				% if the PreCalcFunctionMFA is in the right form, then:
				{M,F,A} ->
					% execute the function
					erlang:apply(M,F,A),
					% then mark it as completed in the database
					NewProcessedJobs = dict:store({ClientCoordinatorPid, Ref}, true, State#state.processedjobs),
					State#state{processedjobs = NewProcessedJobs};
				% otherwise look for the no-function form
				[] -> State
			end;
		% if so, then proceed
		{ok, true} -> State
	end,
	% send an event to self that newdata has arrived
	gen_fsm:send_event(self(),newdata),
	% update the State with the new chunks
	{next_state, StateName, add_chunks(NewState, Chunks)};

% handle the notification from a client that data is available
handle_event({client_data, Pid}, StateName, State) ->
	% request chunks from that client
	request_chunks(Pid, State#state.numchunks),
	{next_state, StateName, State};

% cleanup after a client coordinator has finished a job.  This runs the postcalculation function, if it exists
handle_event({job_cleanup, {ClientCoordinatorPid, JobRef, PostCalcFunctionMFA}}, StateName, State) ->
	% check to see if this server has processed a job from this client coordinator and reference before
	case dict:find({ClientCoordinatorPid, JobRef}, State#state.processedjobs) of
		% if so, then:
		{ok, true} ->
			% delete the {ClientCoordinatorPid, JobRef} tuple from the processedjobs dict
			NewProcessedJobs = dict:erase({ClientCoordinatorPid, JobRef}, State#state.processedjobs),
			% check to see if the PostCalcFunctionMFA is in the right form
			NewState = State#state{processedjobs = NewProcessedJobs},
			case PostCalcFunctionMFA of
				% if so, then spawn it
				{M,F,A} ->
					erlang:spawn(M,F,A);
				% otherwise do nothing	
				_ -> ok
			end,
			{next_state, StateName, NewState};
		% if not, then do nothing
		error -> {next_state, StateName, State}
	end;

% for everything else, do nothing
handle_event(_Event, StateName, State) ->
	{next_state, StateName, State}.

%%%--------- Functions that handle synchronous events

% change the number of parallel worker processes that compute chunk data
% if the new number is greater than the old number, then change the maximum number of workers,
% transition to the waiting state, and send a message that new data is available, as the new workers will be idle
handle_sync_event({change_worker_number, Number}, _FromTag, _StateName, State) when Number > State#state.maxworkers ->
	gen_fsm:send_event(self(),newdata),
	{reply, ok, waiting, State#state{maxworkers = Number}};
% if the number is negative, then return an error
handle_sync_event({change_worker_number, Number}, _FromTag, StateName, State) when Number < 0 ->
	{reply, bad_number, StateName, State};
% otherwise just adjust the worker number and the currently executing workers will terminate themselves when they've finished processing data
handle_sync_event({change_worker_number, Number}, _FromTag, StateName, State) ->
	{reply, ok, StateName, State#state{maxworkers = Number}};

% get the number of workers
handle_sync_event(get_worker_number, _FromTag, StateName, State) ->
	{reply, {State#state.workers, State#state.maxworkers}, StateName, State};

% set the numchunks size used by the server coordinator
handle_sync_event({set_numchunks, Size}, _FromTag, StateName, State) ->
	{reply, {ok, Size}, StateName, State#state{numchunks = Size}};

% get the numchunks size used by the server coordinator
handle_sync_event({get_numchunks}, _FromTag, StateName, State) ->
	{reply, State#state.numchunks, StateName, State};

% for everything else, do nothing
handle_sync_event(_Event, _FromTag, StateName, State) ->
	{next_state, StateName, State}.

%%%--------------- Functions to handle non-gen_fsm messages

% if a worker process exits normally
handle_info({'DOWN', _Ref, process, CalculationPid, normal}, _StateName, State) ->
	% decrease the number of occupied workers
	State1 = State#state{workers = State#state.workers-1},
	% delete the in-progress database entry
	State2 = chunk_delete(State1, CalculationPid),
	% send more chunks off to be processed
	NumToProcess = State2#state.maxworkers - State2#state.workers,
	case process_chunks(State2, NumToProcess) of
		% if all of the workers have been filled, then go to the feeding state
		{Num, NewState} when Num =:= NumToProcess ->
			{next_state, feeding, NewState};
		% otherwise stay in the waiting state
		{_Num, NewState} ->
			{next_state, waiting, NewState}
	end;

% if a worker process exits for some reason other than "normal"
handle_info({'DOWN', _Ref, process, CalculationPid, Reason}, StateName, State) ->
	% retrieve the bad chunk
	{Attempt, BadChunk} = chunk_recall(State, CalculationPid),
	% delete the in-progress database entry
	State1 = chunk_delete(State, CalculationPid),
	NewState = case Attempt of
		% if the attempt is above a threshold
		N when N >= ?MAXATTEMPTS ->
			% decrease the number of occupied workers
			State2 = State1#state{workers = State1#state.workers-1},
			% fill the output chunk with an error message
			OutChunk = outchunk_failure(BadChunk,Reason),
			% send this error output chunk back to the client coordinator
			{ClientCoordinatorPid,_,_,_,_} = BadChunk,
			gen_fsm:send_all_state_event(ClientCoordinatorPid, {calc_done, self(), OutChunk}),
			State2;
		% otherwise
		_ ->
			% increment the attempt number by one
			NewAttempt = Attempt+1,
			% spawn_monitor a new calculation process to work on it again
			{CalcPid, _} = erlang:spawn_monitor(calculator,calculate,[self(), BadChunk]),
			% add it back to the in-progress database
			State1#state{calculationsinprogress = dict:store(CalcPid, {NewAttempt, BadChunk}, State1#state.calculationsinprogress)}
	end,
	{next_state, StateName, NewState};

% for everything else, do nothing
handle_info(_Info, StateName, State) ->
	{next_state, StateName, State}.

%%%--------------- Functions that handle special gen_fsm operations

% terminate the gen_fsm
terminate(_Reason, _StateName, _State) ->
	ok.

% hot code swapping functionality doesn't do anything
code_change(_OldVersion, StateName, State, _Extra) ->
	{ok, StateName, State}.

%%%%%%%%%%%%%%%%%%%%%%%% GEN_FSM states and messages %%%%%%%%%%%%%%%%%%%%%%%%

% if new data comes in when the FSM is waiting
waiting(newdata,State) ->
	% process a chunk for every unoccupied worker
	NumToProcess = State#state.maxworkers - State#state.workers,
	case process_chunks(State, NumToProcess) of
		% if all of the workers have been filled, then go to the feeding state
		{Num, NewState} when Num =:= NumToProcess ->
			{next_state, feeding, NewState};
		% otherwise stay in the waiting state
		{_Num, NewState} ->
			{next_state, waiting, NewState}
	end.

% if new data comes in when the FSM is feeding the workers, don't do anything
% the way the feeding state transitions to the waiting state is by the handle_info function when a worker
% exits normally and no more chunks are available to process, and also by handle_sync_event when processing
% the change_worker_number message
feeding(newdata,State) ->
	{next_state, feeding, State}.

%%%%%%%%%%%%%%%%%%%%%%%% Public functions %%%%%%%%%%%%%%%%%%%%%%%%

% change the number of parallel workers the server coordinator uses to process data
change_worker_number(Number, ServerCoordinatorPid) ->
	gen_fsm:sync_send_all_state_event(ServerCoordinatorPid, {change_worker_number, Number}).

% get the number of parallel workers
% returns {BusyWorkers, MaxWorkers}
get_worker_number(ServerCoordinatorPid) ->
	gen_fsm:sync_send_all_state_event(ServerCoordinatorPid, get_worker_number).

% set the numchunks size being used by the server coordinator
set_numchunks(ServerCoordinatorPid, Size) ->
	if
		% if the given size is valid, send a message to the FSM to adjust it
		Size > 0 -> gen_fsm:sync_send_all_state_event(ServerCoordinatorPid, {set_numchunks, Size});
		% otherwise, return bad_size		
	    true -> bad_size
	end.

% get the numchunks size being used by the server coordinator
get_numchunks(ServerCoordinatorPid) ->
	gen_fsm:sync_send_all_state_event(ServerCoordinatorPid, {get_numchunks}).

%%%%%%%%%%%%%%%%%%%%%%%% Private functions %%%%%%%%%%%%%%%%%%%%%%%%

% request a Number of data chunks from a client coordinator
request_chunks(ClientCoordinatorPid, Number) ->
	gen_fsm:send_all_state_event(ClientCoordinatorPid, {send_chunks, self(), Number}).

% add a load of chunks to be worked on to the internal chunkloads list
% returns State
add_chunks(State, ChunkLoad) ->
	% add the chunkload to the list of chunkloads
	% ChunkLoad is in the form [Chunk1, Chunk2, Chunk3, ...] so we need to enclose it in [] to make sure
	% the whole list gets added as a single element in the chunkloads list
	State#state{chunkloads = [ChunkLoad] ++ State#state.chunkloads}.

% get a Number of chunks off the chunkloads list
% returns {Chunks, State}
get_chunks(State, Number) ->
	% call the helper function to get the chunks, and also the remaining list after the chunks have been removed
	{Chunks, NewChunkLoads} = get_chunks_helper(Number, Number, State#state.numchunks, State#state.chunkloads, []),
	% return the chunks and the new state with the new, smaller, chunkloads list
	{Chunks, State#state{chunkloads = NewChunkLoads}}.

% recursive helper function for get_chunks
% returns {Chunks, RemainingLoads}
% if we come across a load that is empty, simply delete it and keep going
get_chunks_helper(Number, Counter, ReqSize, [[]|OtherLoads], Acc) ->
	get_chunks_helper(Number, Counter, ReqSize, OtherLoads, Acc);
% if the counter runs out, return the accumulator and remaining loads
get_chunks_helper(_Number, 0, _ReqSize, Loads, Acc) ->
	{Acc, Loads};
% if the loads run out, return the accumulator and empty loads list
get_chunks_helper(_Number, _Counter, _ReqSize, [], Acc) ->
	{Acc, []};
% if there's only one element left in the top load
get_chunks_helper(Number, Counter, ReqSize, [[TopChunk|[]]|OtherLoads], Acc) ->
	% send a message to the client coordinator for more chunks
	{ClientCoordinatorPid, _, _, _, _} = TopChunk,
	request_chunks(ClientCoordinatorPid, ReqSize),
	% add the top chunk to the accumulator and continue
	get_chunks_helper(Number, Counter-1, ReqSize, OtherLoads, [TopChunk] ++ Acc);
% otherwise pull off the top chunk belonging to a job, add it to the accumulator, then continue with the chunks of another
% job as the first thing in the list to process next.  This way all submitted job chunks are processed fairly in a round-robin fashion
get_chunks_helper(Number, Counter, ReqSize, [[TopChunk|OtherChunks]|OtherLoads], Acc) ->
	get_chunks_helper(Number, Counter-1, ReqSize, [OtherChunks] ++ OtherLoads, [TopChunk] ++ Acc).

% put/replace a chunk into the database
% returns State
chunk_store(State, Chunk, Pid) ->
	State#state{
		% the zero is the attempt number
		calculationsinprogress = dict:store(Pid, {0, Chunk}, State#state.calculationsinprogress)
	}.

% delete a chunk from the database
% returns State
chunk_delete(State, Pid) ->
	State#state{
		calculationsinprogress = dict:erase(Pid, State#state.calculationsinprogress)
	}.

% recall a chunk from the database
% returns a Chunk
chunk_recall(State, Pid) ->
	dict:fetch(Pid, State#state.calculationsinprogress).

% create a chunk with all elements a failure message
% returns a Chunk
outchunk_failure({_ClientCoordinatorPid, Ref, Seq, _Functions, InputData}, Reason) ->
	FailedOutputData = [{?CALCFAILMESSAGE,Reason} || _X <- InputData],
	{Ref, Seq, FailedOutputData}.

% process a certain number of chunks
% returns {Length, State}
process_chunks(State, Number) when Number > 0 ->
	{Chunks, State1} = get_chunks(State, Number),
	% call the process_chunks helper function
	State2 = process_chunks_helper(State1, Chunks),
	{length(Chunks),State2};
% if the number to process is zero or negative, then don't do anything
process_chunks(State, Number) when Number =< 0 ->
	{0, State}.

% helper function to process chunks
% returns State
% if there are no other chunks to process, just return the final state
process_chunks_helper(State, []) ->
	State;
% if there are chunks to process
process_chunks_helper(State, [TopChunk|OtherChunks]) ->
	% spawn a new calculation process
	{CalcPid, _} = erlang:spawn_monitor(calculator,calculate,[self(), TopChunk]),
	% increment the number of workers that are occupied
	State1 = State#state{workers = State#state.workers+1},
	% store the chunk it's working on in the database and return the altered state
	State2 = chunk_store(State1, TopChunk, CalcPid),
	% make a recursive call with the remaining chunks
	process_chunks_helper(State2, OtherChunks).

%%%%%%%%%%%%%%%%%%%%%%%% Test functions %%%%%%%%%%%%%%%%%%%%%%%%

test() ->
	io:format("--== test_chunks ==--~n"),
	erlang:display(test_chunks()),
	io:format("--== test_registration ==--~n"),
	erlang:display(test_registration()),
	io:format("--== test_server_coordinator ==--~n"),
	erlang:display(test_server_coordinator()).

test_registration() ->
	ClusterName = testcluster,
	{ok, Name} = utils:register_client(ClusterName),
	ClientCoordinators = utils:get_clients(ClusterName),
	global:unregister_name(Name),
	[self()] =:= ClientCoordinators.

test_chunks() ->
	State1 = add_chunks(#state{},test_make_chunks1("yo",self(),make_ref(),fun calculator:calculation1/1,6)),
	State2 = add_chunks(State1,test_make_chunks1("dude",self(),make_ref(),fun calculator:calculation1/1,3)),
	get_chunks(State2, 8).

test_make_chunks1(Prefix, ShellPid, Ref, Functions, Number) ->
	test_make_chunks_helper1(Prefix, ShellPid, Ref, Functions, Number, Number, []).

test_make_chunks_helper1(_Prefix, _ShellPid, _Ref, _Functions, _Number, 0, Acc) ->
	Acc;
test_make_chunks_helper1(Prefix, ShellPid, Ref, Functions, Number, Counter, Acc) ->
	NewData = [erlang:list_to_atom(Prefix ++ integer_to_list(Counter) ++ integer_to_list(X)) || X <- lists:seq(1,3)],
	NewChunk = {ShellPid, Ref, Counter, Functions, NewData},
	test_make_chunks_helper1(Prefix, ShellPid, Ref, Functions, Number, Counter-1, Acc ++ [NewChunk]).

test_make_load(Functions, Number) ->
	Ref = make_ref(),
	[{self(), Ref, X, Functions, lists:seq(10*(X-1)+1,10*X)} || X <- lists:seq(1,Number)].

test_server_coordinator() ->
	ClusterName = testcluster,
	process_flag(trap_exit,true),
	{ok, Name} = utils:register_client(ClusterName),
	{ok, ServerPid} = server_coordinator:start_link(ClusterName),
	% fast computation
	gen_fsm:send_all_state_event(ServerPid,{process_chunks,test_make_load(fun calculator:calculation1/1, 10)}),
	timer:sleep(1000),
	% failing computation
	gen_fsm:send_all_state_event(ServerPid,{process_chunks,test_make_load(fun calculator:calculation1_with_exit/1, 2)}),
	timer:sleep(1000),
	% computation with resizing
	gen_fsm:send_all_state_event(ServerPid,{process_chunks,test_make_load(fun calculator:calculation1_with_sleep/1, 10)}),
	timer:sleep(10000),
	io:format("using 5 workers~n"),
	change_worker_number(5, ServerPid),
	timer:sleep(10000),
	io:format("using 1 worker~n"),
	change_worker_number(1, ServerPid),
	timer:sleep(10000),
	io:format("using 2 workers~n"),
	change_worker_number(2, ServerPid),
	exit(ServerPid,normal),
	global:unregister_name(Name).