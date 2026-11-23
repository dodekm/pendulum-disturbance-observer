classdef AsyncCheckpoint < handle
    %ASYNCCHECKPOINT One background write; prepare before opening the UART link.
    properties (SetAccess=private)
        Target
        Submitted = 0
        LastCommittedSample = 0
        LastIOSeconds = NaN
        LastSubmitSeconds = NaN
        WarmupSeconds = NaN
    end
    properties (Access=private)
        Future = []
        Prefix
        Worker
        Failure = []
    end
    methods
        function obj=AsyncCheckpoint(target,snapshot,worker)
            if nargin<3,worker=@pendulumlab.write_checkpoint;end
            obj.Target=char(target);obj.Worker=worker;
            folder=fileparts(obj.Target);if ~isfolder(folder),mkdir(folder);end
            obj.Prefix=tempname(folder);
            % Warm the pool, scheduler, save/move implementation and result
            % retrieval before acquisition timing starts or any link opens.
            probe=[obj.Prefix '_probe.checkpoint.mat'];
            snapshot.recording_kind='synthetic';
            snapshot.metadata.checkpoint_sample=0;
            snapshot.metadata.source_class='checkpoint_writer_preflight';
            clock=tic;
            obj.Future=parfeval(backgroundPool,obj.Worker,1,probe,[probe '.tmp'],snapshot);
            wait(obj.Future);
            obj.poll();
            loaded=load(probe,'checkpointResult');
            assert(loaded.checkpointResult.metadata.checkpoint_sample==0,'pendulumlab:CheckpointProbe','Checkpoint probe did not round-trip.');
            delete(probe);
            obj.WarmupSeconds=toc(clock);obj.LastIOSeconds=NaN;
        end
        function submit(obj,snapshot)
            clock=tic;obj.poll();
            if ~isempty(obj.Future)
                error('pendulumlab:CheckpointBacklog','Previous checkpoint is still pending at the next checkpoint interval; stop acquisition rather than queue or skip writes.');
            end
            tempPath=sprintf('%s_%08d.checkpoint.tmp.mat',obj.Prefix,snapshot.metadata.checkpoint_sample);
            obj.Future=parfeval(backgroundPool,obj.Worker,1,obj.Target,tempPath,snapshot);
            obj.Submitted=obj.Submitted+1;obj.LastSubmitSeconds=toc(clock);
        end
        function poll(obj)
            if isempty(obj.Future),return,end
            if ~strcmp(obj.Future.State,'finished'),return,end
            f=obj.Future;obj.Future=[];
            try
                if ~isempty(f.Error)
                    original=f.Error;
                    while ~isempty(original.cause),original=original.cause{1};end
                    problem=MException('pendulumlab:CheckpointWriteFailure', ...
                        'Background checkpoint write failed (%s): %s',original.identifier,original.message);
                    problem=addCause(problem,f.Error);throw(problem);
                end
                receipt=fetchOutputs(f);
                obj.LastCommittedSample=receipt.sample;obj.LastIOSeconds=receipt.io_seconds;
            catch err
                obj.Failure=err;rethrow(err);
            end
        end
        function finish(obj)
            % Call only after zero request and link closure. Never cancel a
            % save or allow a late worker to race checkpoint cleanup.
            if ~isempty(obj.Future),wait(obj.Future);end
            obj.poll();
            if ~isempty(obj.Failure),throw(obj.Failure);end
        end
    end
end
