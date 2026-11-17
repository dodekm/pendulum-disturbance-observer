function [allowed,reason]=recovery_gate(rows,interval,nowUtc)
%RECOVERY_GATE Require recovery after the latest started terminal trial.
% Reviewed aborts/faults remain exposures; review does not waive recovery.
arguments
    rows struct
    interval
    nowUtc (1,1) datetime = datetime('now','TimeZone','UTC')
end
allowed=false;reason='';
if ~isnumeric(interval)||~isscalar(interval)||~isfinite(interval)||interval<=0
    reason='Operator-approved positive intertrial_recovery_s is required before physical execution.';return
end
times=NaT(0,1,'TimeZone','UTC');
for k=1:numel(rows)
    r=rows(k);
    if ~isfield(r,'started_utc')||isempty(r.started_utc),continue,end
    if isfield(r,'code')&&any(strcmp(r.code,{'planned','running'})),continue,end
    if ~isfield(r,'finished_utc')||isempty(r.finished_utc)
        reason='A started trial has no finish timestamp; recovery cannot be established.';return
    end
    try
        t=pendulumlab.parse_utc(r.finished_utc);
        if ~isscalar(t)||isnat(t),error('Invalid timestamp');end
        times(end+1,1)=t; %#ok<AGROW>
    catch
        reason='A started trial has an invalid finish timestamp; recovery cannot be established.';return
    end
end
if isempty(times),allowed=true;return,end
age=seconds(nowUtc-max(times));
if ~isfinite(age)||age<interval
    reason=sprintf('Intertrial recovery after the latest started trial remains; %.3f s elapsed of %.3f s required.',age,interval);return
end
allowed=true;
end
