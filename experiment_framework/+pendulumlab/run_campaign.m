function report=run_campaign(manifestPath,runtimeArm,stopFcn)
%RUN_CAMPAIGN Execute/resume only runs with planned, nonterminal state.
% Existing outputs/checkpoints and all terminal failures are never overwritten
% or retried automatically. Any noncompleted result pauses the campaign.
arguments
    manifestPath (1,1) string
    runtimeArm (1,1) struct = struct()
    stopFcn (1,1) function_handle = @() false
end
manifestPath=char(manifestPath);
manifest=read_frozen_manifest(manifestPath);
[outputAllowed,outputReason]=pendulumlab.output_location_allowed(fileparts(manifestPath),manifest.recording_mode);
if ~outputAllowed, error('pendulumlab:OutputLocation','%s',outputReason); end
verify_frozen_code(manifest);
folder=fileparts(manifestPath); statusPath=fullfile(folder,'campaign_status.json');
if isfile(statusPath), status=jsondecode(fileread(statusPath));
else, status=initial_status(manifest); write_json_atomic(statusPath,status,true); end
report=struct('campaign_id',manifest.campaign_id,'manifest_path',manifestPath, ...
    'started_utc',utc_now(),'finished_utc','','executed',0,'skipped',0, ...
    'paused',false,'pause_reason','','runs',struct([]));
failureIndices=find(ismember(string({status.runs.code}), ...
    ["aborted","fault","interlock","blocked"]));
for f=1:numel(failureIndices)
    ix=failureIndices(f);
    if ~has_valid_review(folder,manifest,status.runs(ix))
        report.paused=true;
        report.pause_reason=sprintf('Run %s is %s and has no valid immutable human review. Review must address this exact result before continuing; the run will not be retried.', ...
            status.runs(ix).run_id,status.runs(ix).code);
        report.runs=status.runs; report.finished_utc=utc_now();
        report.summary=pendulumlab.campaign_status(manifestPath); return
    end
end
physical=string(manifest.recording_mode)=="hardware";
if physical
    if ~valid_runtime_arm(runtimeArm)
        report.paused=true; report.pause_reason='Fresh runtime hardware arm with operator identity is required for this invocation.';
        report.runs=status.runs; report.finished_utc=utc_now();
        report.summary=pendulumlab.campaign_status(manifestPath); return
    end
    if isfield(status.runs,'runtime_arm_id')
        usedArms=string({status.runs.runtime_arm_id});
        if any(usedArms==string(runtimeArm.arm_id))
            report.paused=true; report.pause_reason='This runtime arm ID was already used; obtain a new operator arm.';
            report.runs=status.runs; report.finished_utc=utc_now();
            report.summary=pendulumlab.campaign_status(manifestPath); return
        end
    end
    [recovered,recoveryReason]=pendulumlab.recovery_gate(status.runs,manifest.intertrial_recovery_s);
    if ~recovered
        report.paused=true; report.pause_reason=recoveryReason;
        report.runs=status.runs; report.finished_utc=utc_now();
        report.summary=pendulumlab.campaign_status(manifestPath); return
    end
end
for k=1:numel(manifest.runs)
    row=manifest.runs(k); ix=find(strcmp({status.runs.run_id},row.run_id),1);
    if isempty(ix)
        status.runs(end+1)=status_row(row.run_id); ix=numel(status.runs);
    end
    finalPath=fullfile(folder,'runs',[row.run_id '.mat']);
    checkpointPath=fullfile(folder,'runs',[row.run_id '.checkpoint.mat']);
    current=string(status.runs(ix).code);
    if isfile(finalPath)
        if current=="planned"||current=="running"
            try
                saved=load(finalPath,'result');
                status.runs(ix)=update_row(status.runs(ix),saved.result,finalPath);
            catch err
                status.runs(ix).code='fault'; status.runs(ix).reason=['Unreadable saved result: ' err.message];
                status.runs(ix).finished_utc=utc_now();
            end
            status.updated_utc=utc_now(); write_json_atomic(statusPath,status,true);
        end
        report.skipped=report.skipped+1;
        if ~isempty(ix)&&isfield(status.runs(ix),'code')&& ...
                ~strcmp(status.runs(ix).code,'completed')&& ...
                ~has_valid_review(folder,manifest,status.runs(ix))
            report.paused=true;
            report.pause_reason='A saved noncompleted result requires operator review; later trials remain planned.';
            break
        end
        continue
    end
    if current=="completed"
        status.runs(ix).code='fault';
        status.runs(ix).reason='Status says completed but the immutable result file is missing.';
        status.runs(ix).finished_utc=utc_now(); status.updated_utc=utc_now();
        write_json_atomic(statusPath,status,true);
        report.paused=true; report.pause_reason=status.runs(ix).reason; break
    end
    if current~="planned"
        if current=="running"
            status.runs(ix).code='aborted';
            status.runs(ix).reason='A prior invocation left a running status; automatic retry is prohibited.';
            status.runs(ix).finished_utc=utc_now(); status.updated_utc=utc_now();
            write_json_atomic(statusPath,status,true);
            report.paused=true; report.pause_reason=status.runs(ix).reason; break
        end
        report.skipped=report.skipped+1; continue
    end
    if isfile(checkpointPath)
        status.runs(ix).code='aborted';
        status.runs(ix).reason='A prior in-progress checkpoint exists; automatic retry is prohibited.';
        status.runs(ix).result_file=relative_path(folder,checkpointPath);
        status.runs(ix).finished_utc=utc_now(); status.updated_utc=utc_now();
        write_json_atomic(statusPath,status,true);
        report.paused=true; report.pause_reason='Prior checkpoint requires operator review.'; break
    end
    try
        schedulePath=fullfile(folder,char(row.schedule_file));
        if ~isfile(schedulePath), error('pendulumlab:CampaignSchedule','Frozen schedule file is missing.'); end
        if ~strcmpi(pendulumlab.file_hash(schedulePath),char(row.schedule_sha256))
            error('pendulumlab:CampaignHash','Frozen schedule checksum mismatch.');
        end
        frozen=load(schedulePath,'cfgRun','schedule');
        cfgRun=frozen.cfgRun; schedule=frozen.schedule;
        if ~strcmp(cfgRun.run_id,row.run_id)||~strcmp(cfgRun.campaign_id,manifest.campaign_id)
            error('pendulumlab:CampaignIdentity','Frozen run identity does not match manifest.');
        end
        if ~strcmpi(pendulumlab.json_value_sha256(cfgRun),char(row.config_sha256))|| ...
                ~strcmpi(pendulumlab.schedule_identity_sha256(schedule),char(row.schedule_identity_sha256))
            error('pendulumlab:CampaignIdentity','Frozen config or schedule identity hash mismatch.');
        end
        schedule.manifest_sha256=pendulumlab.file_hash(manifestPath);
        schedule.schedule_sha256=char(row.schedule_sha256);
        schedule.source_sha256=manifest.source_sha256;
        % Saved results can be reconciled above after an interrupted status
        % update. Recheck here so that a newly reconciled terminal trial also
        % imposes recovery before the next physical launch.
        if physical
            [recovered,recoveryReason]=pendulumlab.recovery_gate(status.runs,manifest.intertrial_recovery_s);
            if ~recovered
                report.paused=true;report.pause_reason=recoveryReason;break
            end
        end
        status.runs(ix).code='running'; status.runs(ix).started_utc=utc_now();
        if physical
            status.runs(ix).operator_id=char(runtimeArm.operator_id);
            status.runs(ix).runtime_arm_utc=char(runtimeArm.confirmed_utc);
            status.runs(ix).runtime_arm_id=char(runtimeArm.arm_id);
            status.runs(ix).actual_session_id=char(runtimeArm.session_id);
        end
        status.updated_utc=utc_now(); write_json_atomic(statusPath,status,true);
        armForTrial=runtimeArm;
        if physical, armForTrial.source_sha256=manifest.source_sha256; end
        result=pendulumlab.run_trial(cfgRun,schedule,armForTrial,stopFcn);
        report.executed=report.executed+1;
        if isfile(finalPath)
            saved=load(finalPath,'result'); result=saved.result;
        elseif strcmp(result.status.code,'completed')
            result.status.code='fault';
            result.status.reason='Run returned completed but the immutable result file was not created.';
        end
        status.runs(ix)=update_row(status.runs(ix),result,finalPath);
        status.updated_utc=utc_now(); write_json_atomic(statusPath,status,true);
        if ~strcmp(result.status.code,'completed')
            report.paused=true;
            report.pause_reason=sprintf('Run %s ended as %s; later runs remain planned for review.', ...
                row.run_id,result.status.code);
            break
        end
        if physical
            report.paused=true;
            report.pause_reason='One physical run completed; another run requires a later invocation, fresh operator arm, and intertrial recovery.';
            break
        end
    catch err
        status.runs(ix).code='fault'; status.runs(ix).reason=err.message;
        status.runs(ix).finished_utc=utc_now(); status.updated_utc=utc_now();
        write_json_atomic(statusPath,status,true);
        report.paused=true; report.pause_reason=err.message; break
    end
end
report.finished_utc=utc_now(); report.runs=status.runs;
report.summary=pendulumlab.campaign_status(manifestPath);
end

function manifest=read_frozen_manifest(path)
if ~isfile(path), error('pendulumlab:Manifest','Campaign manifest is missing.'); end
hashFile=fullfile(fileparts(path),'campaign_manifest.sha256');
if ~isfile(hashFile), error('pendulumlab:Manifest','Frozen manifest checksum is missing.'); end
expected=strtrim(fileread(hashFile)); actual=pendulumlab.file_hash(path);
if ~strcmpi(expected,actual), error('pendulumlab:ManifestHash','Campaign manifest checksum mismatch.'); end
manifest=jsondecode(fileread(path));
if ~isfield(manifest,'frozen')||~manifest.frozen||~isfield(manifest,'runs')
    error('pendulumlab:Manifest','Manifest is incomplete or not frozen.');
end
end
function verify_frozen_code(manifest)
if ~isfield(manifest,'source_sha256'), error('pendulumlab:CampaignCodeHash','Manifest has no frozen code hashes.'); end
hashes=manifest.source_sha256; expected=pendulumlab.source_fingerprint();
actualNames=sort(fieldnames(hashes)); expectedNames=sort(fieldnames(expected));
if ~isequal(actualNames,expectedNames)
    error('pendulumlab:CampaignCodeHash','Frozen source inventory differs from the active package/public wrappers.');
end
for k=1:numel(expectedNames)
    name=expectedNames{k};
    if ~strcmpi(char(hashes.(name)),char(expected.(name)))
        error('pendulumlab:CampaignCodeHash','Frozen source changed: %s. Freeze a new campaign after review.',name);
    end
end
end
function status=initial_status(manifest)
rows=repmat(status_row(''),numel(manifest.runs),1);
for k=1:numel(manifest.runs), rows(k)=status_row(manifest.runs(k).run_id); end
status=struct('schema_version','pendulumlab.campaign_status/1', ...
    'campaign_id',manifest.campaign_id,'updated_utc',utc_now(),'runs',rows);
end
function row=status_row(id)
row=struct('run_id',char(id),'code','planned','reason','','result_file','', ...
    'started_utc','','finished_utc','','read_count',0,'read_attempt_count',0, ...
    'rest_read_count',0,'trial_read_count',0,'write_count',0, ...
    'operator_id','','runtime_arm_utc','','runtime_arm_id','','actual_session_id','');
end
function row=update_row(row,result,path)
row.code=char(result.status.code); row.reason=char(result.status.reason);
row.result_file=char(path); row.finished_utc=utc_now();
for n={'read_count','read_attempt_count','rest_read_count','trial_read_count','write_count'}
    key=n{1}; if isfield(result.status,key), row.(key)=result.status.(key); end
end
end
function rel=relative_path(base,path)
rel=erase(path,[base filesep]);
end
function t=utc_now()
t=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss.SSSXXX'));
end
function write_json_atomic(path,value,replace)
text=jsonencode(value); folder=fileparts(path); if ~isfolder(folder), mkdir(folder); end
if isfile(path)&&~replace, error('pendulumlab:Frozen','Refusing to overwrite %s.',path); end
name=[tempname(folder) '.json']; fid=fopen(name,'wt');
if fid<0, error('pendulumlab:Status','Cannot open atomic status temp file.'); end
guard=onCleanup(@()fclose(fid)); fwrite(fid,text,'char'); clear guard
[ok,msg]=movefile(name,path,'f');
if ~ok, if isfile(name), delete(name); end
    error('pendulumlab:Status','Status update failed: %s',msg); end
end
function tf=valid_runtime_arm(arm)
tf=false;
if ~isstruct(arm)||~all(isfield(arm,{'HardwareArmed','operator_id','confirmed_utc','arm_id','session_id'}))|| ...
        ~isequal(arm.HardwareArmed,true)||strlength(strtrim(string(arm.operator_id)))==0|| ...
        strlength(strtrim(string(arm.arm_id)))==0||strlength(strtrim(string(arm.session_id)))==0
    return
end
try
    confirmed=pendulumlab.parse_utc(arm.confirmed_utc);
    age=seconds(datetime('now','TimeZone','UTC')-confirmed);
    tf=isfinite(age)&&age>=-30&&age<=300;
catch
    tf=false;
end
end
function tf=has_valid_review(folder,manifest,row)
tf=false; reviewFolder=fullfile(folder,'reviews');
if ~isfolder(reviewFolder),return;end
manifestHash=pendulumlab.file_hash(fullfile(folder,'campaign_manifest.json'));
files=dir(fullfile(reviewFolder,'review_*.json'));
for k=1:numel(files)
    p=fullfile(files(k).folder,files(k).name); side=[p '.sha256'];
    if ~isfile(side)||~strcmpi(strtrim(fileread(side)),pendulumlab.file_hash(p)),continue;end
    try, audit=jsondecode(fileread(p));catch,continue;end
    if ~isfield(audit,'allow_continue')||~isequal(audit.allow_continue,true)|| ...
            ~strcmp(char(audit.run_id),char(row.run_id))|| ...
            ~strcmpi(char(audit.manifest_sha256),manifestHash)|| ...
            ~strcmp(char(audit.original_status),char(row.code))|| ...
            ~strcmp(char(audit.original_reason),char(row.reason))
        continue
    end
    expected='';
    if isfield(row,'result_file')&&~isempty(row.result_file)&&isfile(row.result_file)
        expected=pendulumlab.file_hash(row.result_file);
    else
        candidate=fullfile(folder,'runs',[char(row.run_id) '.checkpoint.mat']);
        if isfile(candidate),expected=pendulumlab.file_hash(candidate);end
    end
    if ~strcmpi(expected,char(audit.result_sha256)),continue;end
    tf=true;return
end
end
