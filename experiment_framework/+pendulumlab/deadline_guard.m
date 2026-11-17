function [stopFcn,receipt]=deadline_guard(deadline,requiredDuration_s,options)
%DEADLINE_GUARD Monotonic runtime cancellation and a pre-start time budget.
% A deadline cancellation throws the existing OperatorAbort exception, so
% run_trial retains its zero-request/close/save cleanup and aborted status.
arguments
    deadline (1,1) datetime
    requiredDuration_s (1,1) double {mustBeFinite,mustBeNonnegative}
    options.LatestStart (1,1) datetime = NaT
    options.StopFile (1,1) string = ""
end
assert(strlength(string(deadline.TimeZone))>0,'pendulumlab:DeadlineZone','Use a timezone-aware deadline.');
nowUtc=datetime('now','TimeZone','UTC');deadline.TimeZone='UTC';
if ~isnat(options.LatestStart)
    latest=options.LatestStart;
    assert(strlength(string(latest.TimeZone))>0,'pendulumlab:DeadlineZone','LatestStart must include its timezone.');
    latest.TimeZone='UTC';
    assert(nowUtc<=latest,'pendulumlab:SessionStartClosed','The session no longer permits a new physical recording.');
end
remaining=seconds(deadline-nowUtc);
assert(remaining>requiredDuration_s,'pendulumlab:DeadlineBudget', ...
    'Insufficient time for the complete recording and declared shutdown margin before the session cutoff.');
assert(strlength(options.StopFile)==0||~isfile(options.StopFile),'pendulumlab:StopFlagExists', ...
    'The stop flag already exists; do not arm the recording.');
clock=tic;stopFile=options.StopFile;
receipt=struct('deadline_utc',char(string(deadline,'yyyy-MM-dd''T''HH:mm:ss.SSSXXX')), ...
    'armed_utc',char(string(nowUtc,'yyyy-MM-dd''T''HH:mm:ss.SSSXXX')), ...
    'remaining_at_arm_s',remaining,'required_duration_with_margin_s',requiredDuration_s, ...
    'clock','Monotonic tic/toc initialized from timezone-aware deadline; no wall-clock calls in sample loop.', ...
    'stop_file',char(stopFile));
stopFcn=@stop;
    function value=stop()
        if toc(clock)>=remaining
            error('pendulumlab:OperatorAbort','Session deadline reached: terminate, request zero and preserve partial recording.');
        end
        value=strlength(stopFile)>0&&isfile(stopFile);
    end
end
