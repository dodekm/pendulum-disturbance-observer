function status=campaign_status(manifestPath)
%CAMPAIGN_STATUS Read a concise, auditable campaign completion snapshot.
arguments
    manifestPath (1,1) string
end
manifestPath=char(manifestPath); folder=fileparts(manifestPath);
if ~isfile(manifestPath), error('pendulumlab:Manifest','Manifest not found.'); end
hashFile=fullfile(folder,'campaign_manifest.sha256');
if ~isfile(hashFile)||~strcmpi(strtrim(fileread(hashFile)),pendulumlab.file_hash(manifestPath))
    error('pendulumlab:ManifestHash','Frozen manifest checksum missing or invalid.');
end
manifest=jsondecode(fileread(manifestPath));
[allowed,reason]=pendulumlab.output_location_allowed(folder,char(manifest.recording_mode));
if ~allowed, error('pendulumlab:OutputLocation','%s',reason); end
statusFile=fullfile(folder,'campaign_status.json');
if isfile(statusFile), state=jsondecode(fileread(statusFile));
else, state=struct('runs',struct([])); end
codes=strings(numel(manifest.runs),1); reasons=strings(numel(manifest.runs),1);
for k=1:numel(manifest.runs)
    ix=find(strcmp({state.runs.run_id},manifest.runs(k).run_id),1);
    if isempty(ix), codes(k)="planned"; reasons(k)="";
    else, codes(k)=string(state.runs(ix).code); reasons(k)=string(state.runs(ix).reason); end
end
terminal=~ismember(codes,["planned","running"]);
attempted=sum(ismember(codes,["completed","aborted","fault","interlock"]));
status=struct('campaign_id',manifest.campaign_id,'plan',manifest.plan, ...
    'planned',numel(codes),'completed',sum(codes=="completed"), ...
    'aborted',sum(codes=="aborted"),'fault',sum(codes=="fault"), ...
    'interlock',sum(codes=="interlock"),'blocked',sum(codes=="blocked"), ...
    'running',sum(codes=="running"),'pending',sum(codes=="planned"), ...
    'terminal',sum(terminal),'attempted',attempted, ...
    'completion_rate',safe_ratio(sum(codes=="completed"),attempted), ...
    'abort_rate',safe_ratio(sum(codes=="aborted"),attempted), ...
    'failure_rate',safe_ratio(sum(ismember(codes,["aborted","fault","interlock"])),attempted), ...
    'run_id',{string({manifest.runs.run_id})},'code',codes,'reason',reasons);
end
function x=safe_ratio(a,b)
if b==0, x=NaN; else, x=a/b; end
end
