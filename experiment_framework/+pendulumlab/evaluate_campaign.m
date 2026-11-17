function report = evaluate_campaign(records,options)
%EVALUATE_CAMPAIGN Trial-level evaluation of campaign/replay/legacy records.
%   REPORT=PENDULUMLAB.EVALUATE_CAMPAIGN(RECORDS) returns metrics and
%   summaries without writing files. RECORDS is a run/1 struct array, a cell
%   array of run structs, or a folder/file source accepted by import_legacy.
%   OutputDirectory enables export of CSV tables and figures.

arguments
    records
    options.OutputDirectory (1,1) string = ""
    options.ConfidenceLevel (1,1) double {mustBeGreaterThan(options.ConfidenceLevel,0),mustBeLessThan(options.ConfidenceLevel,1)} = 0.95
end
if ischar(records) || (isstring(records)&&isscalar(records))
    records=loadRecords(string(records));
elseif iscell(records)
    records=[records{:}];
end
if isempty(records), error('pendulumlab:EmptyCampaign','No records supplied.'); end
required={'recording_kind','metadata','signals','status'};
for j=1:numel(records)
    assert(all(isfield(records(j),required)),'Record %d does not meet run/1 schema.',j);
end
ids=cell(numel(records),1); sourceHashes=cell(numel(records),1);
for j=1:numel(records)
    meta=records(j).metadata;
    if strcmp(fieldOr(meta,'source_class',''),'legacy')
        ids{j}=char(string(fieldOr(meta,'legacy_trial_id','')));
    else
        ids{j}=char(string(fieldOr(meta,'run_id',fieldOr(meta,'trial_id',''))));
    end
    assert(~isempty(ids{j}),'Record %d lacks a stable run/trial ID.',j);
    prov=fieldOr(records(j),'provenance',struct());
    sourceHashes{j}=char(string(fieldOr(prov,'source_sha256',fieldOr(records(j).metadata,'source_sha256',''))));
    if isempty(sourceHashes{j}), sourceHashes{j}=recordDigest(records(j)); end
end
if numel(unique(ids))~=numel(ids), error('pendulumlab:DuplicateRunId','Duplicate stable run/trial identifiers detected.'); end
nonemptyHashes=sourceHashes(~cellfun(@isempty,sourceHashes));
if numel(unique(nonemptyHashes))~=numel(nonemptyHashes), error('pendulumlab:DuplicateSourceHash','Duplicate source-file hashes detected.'); end

trial=repmat(emptyTrial(),numel(records),1);
for j=1:numel(records), trial(j)=scoreTrial(records(j),j); end
groups=makeGroups(trial,options.ConfidenceLevel);
[paired,pairingAudit]=makePairedEffects(trial,options.ConfidenceLevel);
report=struct('schema_version','pendulumlab.evaluation/1', ...
    'created_utc',char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z''')), ...
    'default_windows',windowProtocol(), ...
    'window_rule','Each record uses its frozen config.analysis.evaluation_windows when present; legacy records use the explicit historical windows; other protocols derive tracking windows from frozen reference levels/dwell or retain documented contract defaults.', ...
    'trials',trial,'groups',groups, ...
    'paired_block_effects',paired,'pairing_audit',pairingAudit, ...
    'confidence_level',options.ConfidenceLevel,'interval_method','two-sided Student-t intervals across independent trial-level values; conditional on observed trials.', ...
    'multiplicity_note','Intervals are unadjusted. The primary contrast is prespecified for the core campaign; filter-setting comparisons in an expanded campaign are exploratory unless a multiplicity plan is frozen before data collection.', ...
    'independent_unit','one separately initialized physical recording (trial)', ...
    'scope_warning',['Groups retain hardware, model, phase, protocol, gain and filter settings. ' ...
    'Legacy records are single original-propeller observations, not replacement-propeller repetitions. ' ...
    'Synthetic/replay records are not physical evidence.']);
report.software=struct('matlab_version',version, ...
    'evaluator_sha256',pendulumlab.file_hash([mfilename('fullpath') '.m']), ...
    'analysis_windows_sha256',pendulumlab.file_hash(which('pendulumlab.analysis_windows')));
if strlength(options.OutputDirectory)>0
    writeOutputs(report,char(options.OutputDirectory));
end
end

function p=windowProtocol()
p=struct('tracking_full_s',[0 125],'tracking_plateaus_s',[0 25;25 50;50 75;75 100;100 125], ...
    'tracking_tails_s',[22 25;47 50;72 75;97 100;122 125], ...
    'injection_full_s',[0 70],'injection_pre_s',[5 10],'injection_positive_s',[10 20],'injection_negative_s',[30 40], ...
    'injection_random_s',[50 70],'injection_windows_s',[10 20;30 40;50 70],'injection_tails_s',[17 20;37 40], ...
    'startup_window_s',[0 5],'settling_start_s',100, ...
    'window_convention','left closed, right open; windows are frozen in run config when available; report sample counts, observed span and nominal coverage.');
end

function [w,definition,matchesSchedule,note]=windowsForRun(m,protocol)
w=windowProtocol(); definition='contract default windows';
matchesSchedule=true; note='';
source=fieldOr(m,'config',fieldOr(m,'configuration',struct()));
analysis=fieldOr(source,'analysis',struct()); custom=fieldOr(analysis,'evaluation_windows',struct());
names=fieldnames(w); names(strcmp(names,'window_convention'))=[];
if isstruct(custom)&&~isempty(fieldnames(custom))
    for k=1:numel(names)
        if isfield(custom,names{k}), w.(names{k})=double(custom.(names{k})); end
    end
    if isfield(custom,'startup_s'), w.startup_window_s=double(custom.startup_s); end
    if isfield(custom,'injection_windows_s'), w.injection_windows_s=double(custom.injection_windows_s); end
    if isempty(w.tracking_plateaus_s), w.tracking_full_s=[0 0]; end
    if ~isempty(w.tracking_plateaus_s), w.settling_start_s=w.tracking_plateaus_s(end,1); else, w.settling_start_s=0; end
    definition='frozen metadata.config.analysis.evaluation_windows';
    if isfield(source,'protocol')&&isfield(source,'analysis')&&isfield(source.protocol,'reference_levels_rad')
        expected=pendulumlab.analysis_windows(source); ef=fieldnames(expected);
        for k=1:numel(ef)
            if ~isfield(custom,ef{k})||~isequaln(custom.(ef{k}),expected.(ef{k}))
                matchesSchedule=false;
                note='Frozen evaluation windows do not match the protocol-derived windows in the saved config.';
                break
            end
        end
    end
elseif strcmp(fieldOr(m,'source_class',''),'legacy')
    definition='fixed historical analysis windows';
elseif strcmp(protocol,'reference_tracking')
    p=fieldOr(source,'protocol',struct());
    if isfield(p,'reference_levels_rad')&&isfield(p,'plateau_s')
        dwell=double(p.plateau_s); levels=double(p.reference_levels_rad(:));
        w.tracking_full_s=[0 numel(levels)*dwell];
        edges=(0:numel(levels))*dwell; w.tracking_plateaus_s=[edges(1:end-1)' edges(2:end)'];
        w.settling_start_s=max(0,edges(end-1));
        w.startup_window_s=[0 min(5,dwell)];
        definition='tracking windows derived from frozen protocol reference_levels_rad and plateau_s';
    end
end
if strcmp(protocol,'reference_tracking')
    w.primary_name=char(fieldOr(analysis,'primary_tracking','full_record_rmse'));
elseif strcmp(protocol,'injected_disturbance')
    w.primary_name=char(fieldOr(analysis,'primary_injection','injection_window_rmse'));
else
    w.primary_name='not_applicable_no_control_outcome'; definition='no control evaluation windows for this phase';
    return
end
duration=double(fieldOr(m,'schedule_duration_s',NaN));
if ~isfinite(duration)
    p=fieldOr(source,'protocol',struct());
    if strcmp(protocol,'reference_tracking')&&isfield(p,'reference_levels_rad')&&isfield(p,'plateau_s')
        duration=numel(p.reference_levels_rad)*double(p.plateau_s);
    elseif strcmp(protocol,'injected_disturbance')
        duration=70;
    end
end
if isfinite(duration)
    if strcmp(protocol,'reference_tracking')
        spans=[w.tracking_full_s;w.tracking_plateaus_s;w.tracking_tails_s;w.startup_window_s];
    else
        spans=[w.injection_full_s;w.injection_pre_s;w.injection_positive_s; ...
            w.injection_negative_s;w.injection_random_s;w.injection_tails_s;w.startup_window_s];
    end
    if any(spans(:,2)>duration+1e-9)
        matchesSchedule=false;
        note=sprintf('Frozen evaluation window extends beyond planned schedule duration %.6g s.',duration);
    end
end
end

function r=emptyTrial()
r=struct('trial_id','','recording_kind','','status_code','','status_reason','','completion_class','unknown', ...
    'source_class','','hardware_id','','model_id','','model_version','','model_hardware_id','','model_status','', ...
    'phase','','protocol','','campaign_id','', ...
    'schedule_hash','','schedule_identity_hash','','schedule_name','','schedule_seed',NaN,'a',NaN, ...
    'use_compensation',NaN,'T',NaN,'block_id','','session_id','','run_id','','source_file','','file_hash','', ...
    'n_samples',0,'duration_observed_s',NaN,'valid_sample_count',0,'invalid_sample_count',0, ...
    'write_success_count',NaN,'write_failure_count',NaN,'window_definition','','window_schedule_match',true, ...
    'window_schedule_note','','configuration',struct(), ...
    'metrics',struct(),'window_metrics',struct(),'signals',struct());
end

function r=scoreTrial(run,index)
r=emptyTrial(); m=run.metadata; s=run.signals;
r.recording_kind=char(string(run.recording_kind));
r.source_class=char(string(fieldOr(m,'source_class','')));
r.configuration=fieldOr(m,'config',fieldOr(m,'configuration',struct()));
r.hardware_id=char(string(fieldOr(m,'hardware_id','unknown')));
r.model_id=char(string(fieldOr(m,'model_id','unknown')));
r.model_version=char(string(fieldOr(m,'model_version',fieldOr(fieldOr(m,'model_record',struct()),'version', ...
    fieldOr(r.configuration,'model_version','unknown')))));
r.model_hardware_id=char(string(fieldOr(m,'model_hardware_id',fieldOr(r.configuration,'model_hardware_id','unknown'))));
r.model_status=char(string(fieldOr(m,'model_status',fieldOr(r.configuration,'model_status','unknown'))));
r.phase=char(string(fieldOr(m,'phase','unknown')));
r.protocol=char(string(fieldOr(m,'experiment_id',fieldOr(m,'protocol','unknown'))));
r.campaign_id=char(string(fieldOr(m,'campaign_id','')));
r.schedule_hash=char(string(fieldOr(m,'schedule_sha256',fieldOr(m,'schedule_hash',''))));
r.schedule_identity_hash=char(string(fieldOr(m,'schedule_identity_sha256','')));
r.schedule_name=char(string(fieldOr(m,'schedule_name','')));
r.schedule_seed=double(fieldOr(m,'schedule_seed',NaN));
r.a=double(fieldOr(m,'a',NaN)); r.use_compensation=double(fieldOr(m,'use_compensation',NaN));
r.T=double(fieldOr(m,'T',NaN));
r.block_id=char(string(fieldOr(m,'block_id',''))); r.session_id=char(string(fieldOr(m,'session_id','')));
r.run_id=char(string(fieldOr(m,'run_id','')));
if strcmp(r.source_class,'legacy'), r.trial_id=char(string(fieldOr(m,'legacy_trial_id','')));
else, r.trial_id=char(string(fieldOr(m,'run_id',fieldOr(m,'trial_id','')))); end
r.file_hash=char(string(fieldOr(fieldOr(run,'provenance',struct()),'source_sha256',fieldOr(m,'source_sha256',''))));
r.source_file=char(string(fieldOr(fieldOr(run,'provenance',struct()),'source_file',fieldOr(m,'source_file',''))));
if isempty(r.file_hash), r.file_hash=recordDigest(run); end
if isempty(r.trial_id), error('pendulumlab:MissingRunId','Stable trial ID missing from record %d.',index); end
st=run.status; r.status_code=char(string(fieldOr(st,'code','unknown')));
r.status_reason=char(string(fieldOr(st,'reason','')));
switch lower(r.status_code)
    case {'completed','complete'}, r.completion_class='completed';
    case {'aborted','operator_abort','interrupted'}, r.completion_class='aborted';
    case {'fault','timeout','communication_fault'}, r.completion_class='fault';
    case 'interlock'
        if isfield(st,'trial_read_count')
            trialStarted=isnumeric(st.trial_read_count)&&isscalar(st.trial_read_count)&&st.trial_read_count>0;
        else
            trialStarted=isfield(s,'angle')&&any(isfinite(s.angle(:)));
        end
        if trialStarted,r.completion_class='aborted';else,r.completion_class='blocked';end
    case 'blocked', r.completion_class='blocked';
    otherwise, r.completion_class='unknown';
end
if isfield(s,'t'), t=double(s.t(:)); else, t=nan(0,1); end
r.n_samples=numel(t);
if ~isempty(t), r.duration_observed_s=max(t,[],'omitnan')-min(t,[],'omitnan'); end
if isfield(s,'angle'), angle=double(s.angle(:)); else, angle=nan(size(t)); end
if isfield(s,'reference'), ref=double(s.reference(:)); else, ref=nan(size(t)); end
if isfield(s,'u_command'), u=double(s.u_command(:)); else, u=nan(size(t)); end
n=min([numel(t),numel(angle),numel(ref),numel(u)]);
t=t(1:n); angle=angle(1:n); ref=ref(1:n); u=u(1:n);
mask=isfinite(t)&isfinite(angle)&isfinite(ref);
if isfield(s,'read_valid')
    readValid=false(n,1); rawRead=logical(s.read_valid(:)); readValid(1:min(n,numel(rawRead)))=rawRead(1:min(n,numel(rawRead)));
    mask=mask&readValid;
end
r.valid_sample_count=sum(mask); r.invalid_sample_count=n-sum(mask);
r.signals=struct('t',t,'angle',angle,'reference',ref,'error',ref-angle,'u_command',u);
signalNames=fieldnames(s);
for k=1:numel(signalNames)
    name=signalNames{k}; if isfield(r.signals,name), continue; end
    value=s.(name);
    if isnumeric(value)||islogical(value), r.signals.(name)=value(:); end
end
if isfield(s,'read_valid'), r.signals.read_valid=readValid; end
if isfield(s,'saturated')
    saturated=nan(n,1); rawSaturation=double(s.saturated(:)); saturated(1:min(n,numel(rawSaturation)))=rawSaturation(1:min(n,numel(rawSaturation)));
    r.signals.saturated=saturated;
end
if isfield(s,'write_succeeded')
    writeOK=false(n,1); rawWrite=logical(s.write_succeeded(:)); writeOK(1:min(n,numel(rawWrite)))=rawWrite(1:min(n,numel(rawWrite)));
    r.signals.write_succeeded=writeOK;
    r.write_success_count=sum(writeOK); r.write_failure_count=n-sum(writeOK);
end
[windows,r.window_definition,r.window_schedule_match,r.window_schedule_note]=windowsForRun(m,r.protocol);
wm=struct(); Ts=fieldOr(m,'Ts',NaN);
r.metrics=metricFor(r.signals,mask,Ts);
r.metrics.primary_outcome_name=windows.primary_name;
if strcmp(r.protocol,'reference_tracking')
    r.metrics.primary_outcome=metricWindow(r.signals,mask,windows.tracking_full_s,Ts);
elseif strcmp(r.protocol,'injected_disturbance')
    spans=[windows.injection_positive_s;windows.injection_negative_s;windows.injection_random_s];
    idx=mask & unionMask(r.signals.t,spans);
    r.metrics.primary_outcome=metrics(r.signals,idx,Ts);
    r.metrics.primary_outcome.window_s=spans;
    r.metrics.primary_outcome.requested_duration_s=sum(spans(:,2)-spans(:,1));
    r.metrics.primary_outcome.observed_sample_span_s=coverage(r.signals.t,idx);
    if isfinite(Ts)&&Ts>0, r.metrics.primary_outcome.nominal_covered_duration_s=sum(idx)*Ts; else, r.metrics.primary_outcome.nominal_covered_duration_s=NaN; end
    r.metrics.primary_outcome.coverage_fraction=min(1,r.metrics.primary_outcome.nominal_covered_duration_s/r.metrics.primary_outcome.requested_duration_s);
    [r.metrics.primary_outcome.window_complete,r.metrics.primary_outcome.expected_sample_count]=coverageComplete(r.signals.t,idx,spans,Ts);
else
    r.metrics.primary_outcome=struct('rmse_rad',NaN,'n_samples',0,'coverage_fraction',NaN, ...
        'requested_duration_s',NaN,'window_s',[NaN NaN]);
    wm.evaluation_status='not_applicable_no_control_windows';
    r.window_metrics=wm; return
end
if any(isfinite(r.signals.t)), startupEnd=min(windows.startup_window_s(2),max(r.signals.t(isfinite(r.signals.t)))); else, startupEnd=windows.startup_window_s(1); end
wm.startup=metricWindow(r.signals,mask,[windows.startup_window_s(1) startupEnd],Ts);
if any(mask), wm.startup.peak_abs_angle_rad=max(abs(r.signals.angle(mask & r.signals.t>=windows.startup_window_s(1) & r.signals.t<startupEnd))); end
analysisConfig=fieldOr(r.configuration,'analysis',struct());
windowConfig=fieldOr(analysisConfig,'evaluation_windows',struct());
tol=fieldOr(windowConfig,'settling_error_rad',fieldOr(analysisConfig,'settling_error_rad',NaN));
hold=fieldOr(windowConfig,'settling_hold_s',fieldOr(analysisConfig,'settling_hold_s',NaN));
wm.settling=settlingResult(r.signals,mask,windows,tol,hold,r.protocol,Ts);
if strcmp(r.protocol,'reference_tracking')
    wm.full=metricWindow(r.signals,mask,windows.tracking_full_s,Ts);
    for k=1:size(windows.tracking_plateaus_s,1)
        key=sprintf('plateau_%d',k);
        wm.(key)=metricWindow(r.signals,mask,windows.tracking_plateaus_s(k,:),Ts);
    end
elseif strcmp(r.protocol,'injected_disturbance')
    names={'pre_injection','positive_injection','negative_injection','random_injection'};
    spans=[windows.injection_pre_s;windows.injection_positive_s;windows.injection_negative_s;windows.injection_random_s];
    for k=1:numel(names), wm.(names{k})=metricWindow(r.signals,mask,spans(k,:),Ts); end
    tailSpans=windows.injection_tails_s;
    tailIdx=mask & unionMask(r.signals.t,tailSpans);
    wm.injection_tails=metrics(r.signals,tailIdx,Ts);
    wm.injection_tails.window_s=tailSpans;
    wm.injection_tails.requested_duration_s=sum(tailSpans(:,2)-tailSpans(:,1));
    wm.injection_tails.observed_sample_span_s=coverage(r.signals.t,tailIdx);
    wm.injection_tails.nominal_covered_duration_s=sum(tailIdx)*Ts;
    if isfield(r.signals,'w_hat')&&isfield(r.signals,'w_injected_filtered')
        a=r.signals.w_hat(1:min(n,end)); b=r.signals.w_injected_filtered(1:min(n,end));
        commonN=min([n numel(a) numel(b)]);
        common=mask(1:commonN)&isfinite(a(1:commonN))&isfinite(b(1:commonN));
        if any(common)
            diagnostic=a(1:numel(common))-b(1:numel(common));
            wm.injection_referenced_observer_diagnostic_rms=sqrt(mean(diagnostic(common).^2));
        end
    end
end
r.window_metrics=wm;
end

function m=metricFor(s,mask,Ts)
m=metrics(s,mask,Ts);
end

function m=metricWindow(s,mask,span,Ts)
idx=mask & s.t>=span(1) & s.t<span(2);
m=metrics(s,idx,Ts); m.window_s=span; m.observed_sample_span_s=coverage(s.t,idx);
m.requested_duration_s=span(2)-span(1); m.nominal_covered_duration_s=sum(idx)*Ts;
if m.requested_duration_s>0&&isfinite(Ts), m.coverage_fraction=min(1,m.nominal_covered_duration_s/m.requested_duration_s); else, m.coverage_fraction=NaN; end
[m.window_complete,m.expected_sample_count]=coverageComplete(s.t,idx,span,Ts);
end

function out=settlingResult(s,mask,w,tolerance,holdDuration,protocol,Ts)
out=struct('status','not_evaluated_missing_frozen_criterion','settled',NaN, ...
    'settling_time_s',NaN,'tolerance_rad',tolerance,'hold_duration_s',holdDuration, ...
    'window_s',[NaN NaN],'criteria_source','frozen config.analysis.evaluation_windows');
if ~strcmp(protocol,'reference_tracking')
    out.status='not_evaluated_nontracking_protocol'; return
end
start=w.settling_start_s; finish=w.tracking_full_s(2); out.window_s=[start finish];
if ~isfinite(tolerance)||tolerance<=0||~isfinite(holdDuration)||holdDuration<=0||~isfinite(Ts)||Ts<=0, return; end
out.status='not_settled_within_prespecified_window'; out.settled=false;
idx=find(mask&s.t>=start&s.t<finish);
if isempty(idx), out.status='not_evaluable_no_valid_samples'; out.settled=NaN; return; end
for k=1:numel(idx)
    i=idx(k); stopTime=s.t(i)+holdDuration;
    expectedCount=round(holdDuration/Ts)+1;
    j=find(mask&s.t>=s.t(i)-Ts*1e-6&s.t<=stopTime+Ts*1e-6);
    expectedTime=s.t(i)+(0:expectedCount-1)'*Ts;
    if numel(j)~=expectedCount||any(abs(s.t(j)-expectedTime)>max(1e-9,Ts*1e-6)), continue; end
    % Require the error band to hold at every sample across the full interval.
    if any(abs(s.error(j))>tolerance), continue; end
    out.status='settled'; out.settled=true; out.settling_time_s=s.t(i)-start; return
end
end

function m=metrics(s,idx,Ts)
e=s.error(idx); u=s.u_command(idx); t=s.t(idx);
m=struct('n_samples',sum(idx),'rmse_rad',NaN,'mae_rad',NaN,'bias_rad',NaN, ...
    'peak_abs_error_rad',NaN,'iae_rad_s',NaN,'command_rms_units',NaN, ...
    'command_total_variation_units',NaN,'clipping_fraction',NaN);
if isempty(e), return; end
m.rmse_rad=sqrt(mean(e.^2)); m.mae_rad=mean(abs(e)); m.bias_rad=mean(e);
m.peak_abs_error_rad=max(abs(e));
if isfinite(Ts)&&Ts>0, m.iae_rad_s=Ts*sum(abs(e)); end
finiteU=isfinite(u); if any(finiteU), m.command_rms_units=sqrt(mean(u(finiteU).^2)); end
% TV is summed only for adjacent samples both in the selected window.
if isfield(s,'write_succeeded'), commandMask=logical(s.write_succeeded(idx)); else, commandMask=true(size(u)); end
finiteU=isfinite(u)&commandMask; if any(finiteU), m.command_rms_units=sqrt(mean(u(finiteU).^2)); end
allIdx=find(idx & isfinite(s.u_command));
if isfield(s,'write_succeeded'), allIdx=allIdx(s.write_succeeded(allIdx)); end
if numel(allIdx)>1
    adjacent=diff(allIdx)==1;
    delta=abs(diff(s.u_command(allIdx)));
    if any(adjacent), m.command_total_variation_units=sum(delta(adjacent)); end
end
if isfield(s,'saturated')
    sat=s.saturated(idx); sat=sat(isfinite(sat)); if ~isempty(sat), m.clipping_fraction=mean(sat~=0); end
end
m.observed_sample_span_s=coverage(t,true(size(t)));
if isfinite(Ts)&&Ts>0, m.nominal_covered_duration_s=numel(t)*Ts; else, m.nominal_covered_duration_s=NaN; end
end

function span=coverage(t,mask)
v=t(mask); if numel(v)>=2, span=max(v)-min(v); else, span=0; end
end

function idx=unionMask(t,spans)
idx=false(size(t));
for k=1:size(spans,1), idx=idx | (t>=spans(k,1)&t<spans(k,2)); end
end

function [complete,expectedCount]=coverageComplete(t,validMask,spans,Ts)
complete=false; expected=[];
if ~isfinite(Ts)||Ts<=0, expectedCount=NaN; return; end
for k=1:size(spans,1)
    count=round((spans(k,2)-spans(k,1))/Ts);
    expected=[expected; spans(k,1)+(0:count-1)'*Ts]; %#ok<AGROW>
end
expectedCount=numel(expected); actual=t(validMask);
complete=numel(actual)==expectedCount&&all(abs(actual-expected)<=max(1e-9,Ts*1e-6));
end

function groups=makeGroups(trials,confidenceLevel)
groups=struct('key',{},'n_trials',{},'n_completed',{},'n_aborted',{},'n_fault',{},'n_blocked',{}, ...
    'n_unknown_status',{},'completion_rate',{},'abort_rate',{},'fault_rate',{},'blocked_rate',{}, ...
    'n_primary_complete',{},'n_partial_or_noncompleted',{},'trial_ids',{},'summary',{});
keys=cell(numel(trials),1);
for k=1:numel(trials)
    r=trials(k);
    keys{k}=strjoin({r.recording_kind,r.source_class,r.campaign_id,r.phase,r.hardware_id,r.model_hardware_id, ...
        r.model_id,r.model_version,r.model_status, ...
        r.protocol,r.schedule_name,num2str(r.a,17),num2str(r.use_compensation,17),num2str(r.T,17)},'|');
end
u=unique(keys,'stable');
for k=1:numel(u)
    ix=find(strcmp(keys,u{k})); subset=trials(ix);
    complete=false(numel(subset),1);
    for z=1:numel(subset)
        pm=subset(z).metrics.primary_outcome;
        noWriteFault=isnan(subset(z).write_failure_count)||subset(z).write_failure_count==0;
        complete(z)=strcmp(subset(z).completion_class,'completed')&&noWriteFault&&subset(z).window_schedule_match&& ...
            isfield(pm,'coverage_fraction')&&isfinite(pm.coverage_fraction)&&pm.coverage_fraction>=0.99&& ...
            isfield(pm,'window_complete')&&pm.window_complete;
    end
    primary=[subset(complete).metrics];
    summary=struct();
    if isempty(primary), summary.primary_rmse_rad=summarize(struct([]),'primary_outcome',confidenceLevel);
    else, summary.primary_rmse_rad=summarize(primary,'primary_outcome',confidenceLevel); end
    summary.completed_full_rmse_rad=summarize([subset(complete).metrics],'rmse_rad',confidenceLevel);
    summary.completed_full_mae_rad=summarize([subset(complete).metrics],'mae_rad',confidenceLevel);
    summary.completed_command_tv_units=summarize([subset(complete).metrics],'command_total_variation_units',confidenceLevel);
    summary.partial_or_noncompleted_observed_rmse_rad=summarize([subset(~complete).metrics],'rmse_rad',confidenceLevel);
    summary.partial_or_noncompleted_observed_primary_rmse_rad=summarize([subset(~complete).metrics],'primary_outcome',confidenceLevel);
    summary.primary_coverage_fraction=summarizePrimaryCoverage(subset,confidenceLevel);
    summary.injection_tail_rmse_rad=summarizeWindow(subset(complete),'injection_tails',confidenceLevel);
    nCompleted=sum(strcmp({subset.completion_class},'completed')); nAborted=sum(strcmp({subset.completion_class},'aborted'));
    nFault=sum(strcmp({subset.completion_class},'fault')); nBlocked=sum(strcmp({subset.completion_class},'blocked'));
    groups(k)=struct('key',u{k},'n_trials',numel(ix), ...
        'n_completed',nCompleted,'n_aborted',nAborted,'n_fault',nFault,'n_blocked',nBlocked, ...
        'n_unknown_status',sum(strcmp({subset.completion_class},'unknown')), ...
        'completion_rate',nCompleted/numel(ix),'abort_rate',nAborted/numel(ix), ...
        'fault_rate',nFault/numel(ix),'blocked_rate',nBlocked/numel(ix), ...
        'n_primary_complete',sum(complete),'n_partial_or_noncompleted',sum(~complete), ...
        'trial_ids',{ {subset.trial_id} },'summary',summary);
end
end

function out=summarize(items,name,confidenceLevel)
v=nan(numel(items),1);
for i=1:numel(items)
    if ~isfield(items(i),name), continue; end
    value=items(i).(name);
    if isstruct(value)&&isfield(value,'rmse_rad')
        v(i)=value.rmse_rad;
    elseif isnumeric(value)&&isscalar(value)
        v(i)=value;
    end
end
v=v(isfinite(v)); n=numel(v); out=struct('n_trials',n,'mean',NaN,'sd',NaN,'ci_low',NaN,'ci_high',NaN,'values',v(:));
if n==0, return; end
out.mean=mean(v);
if n>=2
    out.sd=std(v,0); q=studentTCrit((1+confidenceLevel)/2,n-1); half=q*out.sd/sqrt(n); out.ci_low=out.mean-half; out.ci_high=out.mean+half;
end
end

function out=summarizePrimaryCoverage(trials,confidenceLevel)
values=nan(numel(trials),1);
for k=1:numel(trials), values(k)=trials(k).metrics.primary_outcome.coverage_fraction; end
out=summarizeScalar(values,confidenceLevel);
end

function out=summarizeWindow(trials,windowName,confidenceLevel)
values=nan(numel(trials),1);
for k=1:numel(trials)
    if isfield(trials(k).window_metrics,windowName)
        values(k)=trials(k).window_metrics.(windowName).rmse_rad;
    end
end
out=summarizeScalar(values,confidenceLevel);
end

function out=summarizeScalar(values,confidenceLevel)
values=values(isfinite(values)); n=numel(values); out=struct('n_trials',n,'mean',NaN,'sd',NaN,'ci_low',NaN,'ci_high',NaN,'values',values(:));
if n==0, return; end
out.mean=mean(values);
if n>=2, out.sd=std(values,0); h=studentTCrit((1+confidenceLevel)/2,n-1)*out.sd/sqrt(n); out.ci_low=out.mean-h; out.ci_high=out.mean+h; end
end

function [effects,audit]=makePairedEffects(trials,level)
template=struct('campaign_id','','session_id','','recording_kind','','source_class','', ...
    'protocol','','hardware_id','','model_hardware_id','','model_id','','model_version','', ...
    'model_status','','phase','','a',NaN,'T',NaN,'metric','', ...
    'comparison','On minus matched Off','n_pairs',0,'block_ids',{{}},'differences',[], ...
    'mean_difference',NaN,'ci_low',NaN,'ci_high',NaN);
effects=repmat(template,0,1);
audit=struct('candidate_on_trials',0,'paired_trials',0,'missing_off',0,'ambiguous_off',0, ...
    'identity_or_schedule_mismatch',0,'incomplete_pair',0, ...
    'rule','Match within campaign_id + session_id + block_id; require one Off, identical recording/source class, protocol, hardware/model/status, phase/gain, theta, time/reference/requested-injection vectors and schedule identity; summarize only completed full-coverage pairs.');
% Block identities are composite; missing identity components cannot be paired.
blockKeys=cell(numel(trials),1);
for k=1:numel(trials)
    r=trials(k);
    if isempty(r.campaign_id)||isempty(r.session_id)||isempty(r.block_id), continue; end
    blockKeys{k}=strjoin({r.campaign_id,r.session_id,r.block_id},'|');
end
u=unique(blockKeys(~cellfun(@isempty,blockKeys)),'stable');
for b=1:numel(u)
    ix=find(strcmp(blockKeys,u{b})); x=trials(ix);
    for j=1:numel(x)
        if ~isfinite(x(j).use_compensation)||x(j).use_compensation~=1, continue; end
        audit.candidate_on_trials=audit.candidate_on_trials+1;
        common=strcmp({x.recording_kind},x(j).recording_kind)&strcmp({x.source_class},x(j).source_class)& ...
            strcmp({x.protocol},x(j).protocol)&strcmp({x.hardware_id},x(j).hardware_id)& ...
            strcmp({x.model_hardware_id},x(j).model_hardware_id)&strcmp({x.model_id},x(j).model_id)& ...
            strcmp({x.model_version},x(j).model_version)&strcmp({x.model_status},x(j).model_status)& ...
            strcmp({x.phase},x(j).phase)&[x.a]==x(j).a&[x.use_compensation]==0;
        candidates=find(common);
        if isempty(candidates), audit.missing_off=audit.missing_off+1; continue; end
        if numel(candidates)~=1, audit.ambiguous_off=audit.ambiguous_off+1; continue; end
        off=x(candidates);
        if ~sameScheduledInputs(x(j),off)
            audit.identity_or_schedule_mismatch=audit.identity_or_schedule_mismatch+1; continue
        end
        onCoverage=x(j).metrics.primary_outcome.coverage_fraction;
        offCoverage=off.metrics.primary_outcome.coverage_fraction;
        noWriteFault=(isnan(x(j).write_failure_count)||x(j).write_failure_count==0)&& ...
            (isnan(off.write_failure_count)||off.write_failure_count==0);
        eligible=strcmp(x(j).completion_class,'completed')&&strcmp(off.completion_class,'completed')&&noWriteFault&& ...
            x(j).window_schedule_match&&off.window_schedule_match&&onCoverage>=0.99&&offCoverage>=0.99&& ...
            x(j).metrics.primary_outcome.window_complete&&off.metrics.primary_outcome.window_complete;
        if ~eligible, audit.incomplete_pair=audit.incomplete_pair+1; continue; end
        audit.paired_trials=audit.paired_trials+1;
        specs={'primary_outcome','mae_rad','command_total_variation_units'};
        for z=1:numel(specs)
            nm=specs{z};
            if strcmp(nm,'primary_outcome')
                a=x(j).metrics.primary_outcome.rmse_rad; c=off.metrics.primary_outcome.rmse_rad; metricName='primary_rmse_rad';
            else
                a=x(j).metrics.(nm); c=off.metrics.(nm); metricName=nm;
            end
            if ~isfinite(a)||~isfinite(c), continue; end
            e=template; e.campaign_id=x(j).campaign_id; e.session_id=x(j).session_id;
            e.recording_kind=x(j).recording_kind; e.source_class=x(j).source_class;
            e.protocol=x(j).protocol; e.hardware_id=x(j).hardware_id; e.model_hardware_id=x(j).model_hardware_id;
            e.model_id=x(j).model_id; e.model_version=x(j).model_version; e.model_status=x(j).model_status;
            e.phase=x(j).phase; e.a=x(j).a; e.T=x(j).T; e.metric=metricName;
            e.n_pairs=1; e.block_ids=u(b); e.differences=a-c; e.mean_difference=a-c;
            effects(end+1)=e; %#ok<AGROW>
        end
    end
end
if isempty(effects), return; end
keys=arrayfun(@(e)strjoin({e.campaign_id,e.recording_kind,e.source_class,e.protocol,e.hardware_id, ...
    e.model_hardware_id,e.model_id,e.model_version,e.model_status,e.phase, ...
    num2str(e.a,17),num2str(e.T,17),e.metric},'|'),effects,'UniformOutput',false);
uniqueKeys=unique(keys,'stable'); combined=repmat(template,0,1);
for k=1:numel(uniqueKeys)
    x=effects(strcmp(keys,uniqueKeys{k})); d=[x.differences]'; n=numel(d); meanD=mean(d); lo=NaN; hi=NaN;
    if n>=2, q=studentTCrit((1+level)/2,n-1); h=q*std(d,0)/sqrt(n); lo=meanD-h; hi=meanD+h; end
    e=x(1); e.n_pairs=n; e.block_ids=vertcat(x.block_ids); e.differences=d; e.mean_difference=meanD; e.ci_low=lo; e.ci_high=hi; combined(end+1)=e; %#ok<AGROW>
end
effects=combined;
end

function tf=sameScheduledInputs(a,b)
tf=isequal(a.metrics.primary_outcome.requested_duration_s,b.metrics.primary_outcome.requested_duration_s)&& ...
    vectorsEqual(a.signals.t,b.signals.t,1e-12)&&vectorsEqual(a.signals.reference,b.signals.reference,1e-10);
for f={'w_injected_requested'}
    if isfield(a.signals,f{1})&&isfield(b.signals,f{1})
        tf=tf&&vectorsEqual(a.signals.(f{1}),b.signals.(f{1}),1e-10);
    elseif strcmp(a.protocol,'injected_disturbance')
        tf=false;
    end
end
thetaA=fieldOr(a.configuration,'theta',[]); thetaB=fieldOr(b.configuration,'theta',[]);
if isempty(thetaA)||isempty(thetaB), tf=false; else, tf=tf&&vectorsEqual(thetaA,thetaB,1e-10); end
limitsA=fieldOr(a.configuration,'u_limits',[]); limitsB=fieldOr(b.configuration,'u_limits',[]);
if isempty(limitsA)||isempty(limitsB), tf=false; else, tf=tf&&vectorsEqual(limitsA,limitsB,1e-10); end
if ~isempty(a.schedule_identity_hash)&&~isempty(b.schedule_identity_hash)
    tf=tf&&strcmp(a.schedule_identity_hash,b.schedule_identity_hash);
end
if ~isempty(a.schedule_name)&&~isempty(b.schedule_name), tf=tf&&strcmp(a.schedule_name,b.schedule_name); end
end

function tf=vectorsEqual(a,b,tol)
a=double(a(:)); b=double(b(:));
tf=numel(a)==numel(b)&&all(isfinite(a))&&all(isfinite(b))&&all(abs(a-b)<=tol);
end

function q=studentTCrit(p,df)
% Inverse Student t from MATLAB base betaincinv, two-sided probability p.
x=betaincinv(2*min(p,1-p),df/2,0.5);
q=sqrt(df*(1/x-1));
end

function value=fieldOr(s,name,default)
if isstruct(s)&&isfield(s,name), value=s.(name); else, value=default; end
end

function records=loadRecords(source)
if isfolder(source)
    runFolder=fullfile(source,'runs'); if isfolder(runFolder), folder=runFolder; else, folder=char(source); end
    files=dir(fullfile(folder,'*.mat'));
    files=files(~contains({files.name},'.checkpoint.'));
    if isempty(files), error('pendulumlab:NoMatFiles','No MAT recordings found under %s.',source); end
    legacy=false(numel(files),1);
    for k=1:numel(files)
        path=fullfile(files(k).folder,files(k).name); loaded=load(path,'result');
        legacy(k)=~isfield(loaded,'result')||~isfield(loaded.result,'schema_version')|| ...
            ~strcmp(fieldOr(loaded.result,'schema_version',''),'pendulumlab.run/1');
    end
    if any(legacy)&&~all(legacy)
        error('pendulumlab:MixedLegacyCampaign','Legacy and run/1 MAT files cannot be concatenated; evaluate each cohort separately.');
    elseif all(legacy)
        records=pendulumlab.import_legacy(source);
    else
        records=pendulumlab.load_runs(source);
    end
elseif isfile(source)
    loaded=load(source,'result');
    if ~isfield(loaded,'result')||~isfield(loaded.result,'schema_version')|| ...
            ~strcmp(fieldOr(loaded.result,'schema_version',''),'pendulumlab.run/1')
        records=pendulumlab.import_legacy(source);
    else
        records=pendulumlab.load_runs(source);
    end
else
    error('pendulumlab:SourceNotFound','Source does not exist: %s',source);
end
end

function digest=recordDigest(record)
bytes=getByteStreamFromArray(record);
md=java.security.MessageDigest.getInstance('SHA-256'); md.update(uint8(bytes));
digest=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
end

function writeOutputs(report,outDir)
[allowed,why]=pendulumlab.output_location_allowed(outDir,'offline');
assert(allowed,'pendulumlab:OutputLocation','%s',why);
if isfolder(outDir)
    entries=dir(outDir);entries=entries(~ismember({entries.name},{'.','..'}));
    assert(isempty(entries),'pendulumlab:EvaluationExists', ...
        'Use a new evaluation directory; prior derived outputs are not overwritten.');
end
if ~exist(outDir,'dir'), mkdir(outDir); end
save(fullfile(outDir,'evaluation_report.mat'),'report','-v7.3');
tr=report.trials; p=cell(numel(tr),1); cv=nan(numel(tr),1); fmae=cv; tv=cv; duration=cv;
for k=1:numel(tr)
    p{k}=tr(k).metrics.primary_outcome.rmse_rad; cv(k)=tr(k).metrics.primary_outcome.coverage_fraction;
    fmae(k)=tr(k).metrics.mae_rad; tv(k)=tr(k).metrics.command_total_variation_units; duration(k)=tr(k).duration_observed_s;
end
primary=cellfun(@double,p);
rows=table(string({tr.trial_id})',string({tr.run_id})',string({tr.campaign_id})', ...
    string({tr.session_id})',string({tr.block_id})',string({tr.recording_kind})', ...
    string({tr.source_class})',string({tr.completion_class})',string({tr.hardware_id})', ...
    string({tr.model_hardware_id})',string({tr.model_id})',string({tr.model_version})', ...
    string({tr.model_status})',string({tr.phase})',string({tr.protocol})', ...
    string({tr.schedule_name})',string({tr.schedule_hash})',string({tr.schedule_identity_hash})',[tr.schedule_seed]', ...
    [tr.a]',[tr.use_compensation]',[tr.T]',duration,[tr.n_samples]',[tr.valid_sample_count]', ...
    [tr.invalid_sample_count]',[tr.write_success_count]',[tr.write_failure_count]',primary,cv,fmae,tv, ...
    [tr.window_schedule_match]',string({tr.window_schedule_note})',string({tr.status_code})', ...
    string({tr.status_reason})',string({tr.source_file})',string({tr.file_hash})', ...
    'VariableNames',{'trial_id','run_id','campaign_id','session_id','block_id','recording_kind', ...
    'source_class','completion_class','hardware_id','model_hardware_id','model_id','model_version', ...
    'model_status','phase','protocol', ...
    'schedule_name','schedule_sha256','schedule_identity_sha256','schedule_seed','a','use_compensation','T_s','duration_observed_s', ...
    'n_samples','valid_sample_count','invalid_sample_count','write_success_count','write_failure_count', ...
    'primary_rmse_rad','primary_coverage_fraction','full_mae_rad','command_total_variation_units', ...
    'window_schedule_match','window_schedule_note','status_code','status_reason','source_file','source_sha256'});
rows=addvars(rows,(1:numel(tr))','Before',1,'NewVariableNames','trial_index');
writetable(rows,fullfile(outDir,'trial_inventory.csv'));
% JSON retains frozen config/provenance for every trial but omits bulky raw vectors.
metadata=rmfield(tr,{'signals','metrics','window_metrics'});
for k=1:numel(metadata),metadata(k).trial_index=k;end
fid=fopen(fullfile(outDir,'trial_metadata.json'),'w','n','UTF-8'); assert(fid>=0); c=onCleanup(@()fclose(fid));
fwrite(fid,jsonencode(struct('trials',metadata,'groups',report.groups, ...
    'paired_block_effects',report.paired_block_effects,'pairing_audit',report.pairing_audit, ...
    'confidence_level',report.confidence_level,'interval_method',report.interval_method, ...
    'multiplicity_note',report.multiplicity_note),PrettyPrint=true),'char');
clear c
makeFigures(report,fullfile(outDir,'figures'));
end

function makeFigures(report,figDir)
if ~exist(figDir,'dir'), mkdir(figDir); end
old=get(groot,'defaultFigureVisible'); cleanup=onCleanup(@()set(groot,'defaultFigureVisible',old));
set(groot,'defaultFigureVisible','off');
% All supplied trials are shown; the inventory maps display indices to UUIDs.
trials=report.trials;
for first=1:4:numel(trials)
    last=min(first+3,numel(trials)); n=last-first+1;
    f=figure('Color','w','Visible','off','Position',[50 50 1250 255*n]);
    c=onCleanup(@()close(f)); tl=tiledlayout(f,n,3,'TileSpacing','compact','Padding','compact');
    for j=first:last
        r=trials(j); ax=nexttile(tl); s=r.signals;
        plot(ax,s.t,s.reference,'--','Color',[.3 .3 .3],'LineWidth',1); hold(ax,'on');
        plot(ax,s.t,s.angle,'Color',[0 .35 .65],'LineWidth',.9); grid(ax,'on');
        ylabel(ax,'$y, v$ [rad]','Interpreter','latex'); xlabel(ax,'$t$ [s]','Interpreter','latex');
        condition='Off';if r.use_compensation==1,condition=sprintf('On, T=%.3g s',r.T);end
        title(ax,sprintf('R%02d | %s | %s | %s',j,r.recording_kind,condition,r.completion_class), ...
            'Interpreter','none','FontWeight','normal');
        legend(ax,{'$v$ (reference)','$y$'},'Interpreter','latex','Location','best','FontSize',8);
        ax=nexttile(tl);plot(ax,s.t,s.u_command,'Color',[0 .35 .65],'LineWidth',.9);hold(ax,'on');grid(ax,'on');
        labels={'$u_{\mathrm{cmd}}$'};
        if isfield(s,'q_nominal')&&isfield(r.configuration,'actuator_calibration')&&r.configuration.actuator_calibration.enabled
            labels={'$q_{\mathrm{cmd}}$'};
            plot(ax,s.t,s.q_nominal,'--','Color',[.75 .35 .05],'LineWidth',.9);labels{end+1}='$q_{\mathrm{nom}}$';
        elseif isfield(s,'u_nominal')&&numel(s.u_nominal)==numel(s.t)
            plot(ax,s.t,s.u_nominal,'--','Color',[.75 .35 .05],'LineWidth',.9);labels{end+1}='$u_{\mathrm{nom}}$';
        end
        legend(ax,labels,'Interpreter','latex','Location','best','FontSize',8);
        ylabel(ax,'Command [command units]');xlabel(ax,'$t$ [s]','Interpreter','latex');
        title(ax,strrep(r.protocol,'_',' '),'FontWeight','normal');
        ax=nexttile(tl);hold(ax,'on');grid(ax,'on');labels={};
        if isfield(s,'w_hat')&&numel(s.w_hat)==numel(s.t)
            plot(ax,s.t,s.w_hat,'Color',[0 .35 .65],'LineWidth',.9);labels{end+1}='$\hat w$';
        end
        if strcmp(r.protocol,'injected_disturbance')&&isfield(s,'w_injected_filtered')&&numel(s.w_injected_filtered)==numel(s.t)
            plot(ax,s.t,s.w_injected_filtered,'--','Color',[.75 .35 .05],'LineWidth',.9);
            labels{end+1}='$Qw_{\mathrm{inj,eff}}$';
        end
        if ~isempty(labels),legend(ax,labels,'Interpreter','latex','Location','best','FontSize',8);end
        ylabel(ax,'Observer [command units]');xlabel(ax,'$t$ [s]','Interpreter','latex');
        if strcmp(r.protocol,'injected_disturbance'),title(ax,'Injection-referenced diagnostic','FontWeight','normal');
        else,title(ax,'Equivalent residual estimate','FontWeight','normal');end
    end
    sgtitle(tl,[figureScope(report) ' | Individual trials; full IDs in trial_inventory.csv'], ...
        'FontWeight','normal','Interpreter','none');
    saveFigure(f,fullfile(figDir,sprintf('individual_trials_%03d_%03d',first,last))); clear c;
end
% One observation per independent recording. Each x category is exactly one
% strict scope group; no hardware/model/protocol/filter group is pooled.
f=figure('Color','w','Visible','off','Position',[50 50 1100 700]); c=onCleanup(@()close(f));
tl=tiledlayout(f,1,3,'TileSpacing','compact','Padding','compact');
names={'primary_outcome','mae_rad','command_total_variation_units'};
labels={'Primary RMSE [rad]','Full-record MAE [rad]','Command total variation [command units]'};
groupKeys={report.groups.key}; ng=numel(groupKeys); colors=lines(max(ng,1));
for q=1:3
    ax=nexttile(tl); hold(ax,'on'); grid(ax,'on');
    hTrial=[]; hSummary=[];
    for g=1:ng
        ids=report.groups(g).trial_ids;
        member=find(ismember({trials.trial_id},ids));
        if q==1, vals=arrayfun(@(r)r.metrics.primary_outcome.rmse_rad,trials(member));
        else, vals=arrayfun(@(r)r.metrics.(names{q}),trials(member)); end
        vals=vals(isfinite(vals));
        if isempty(vals), continue; end
        jitter=linspace(-0.16,0.16,numel(vals));
        h=plot(ax,g+jitter,vals,'ko','MarkerFaceColor',colors(g,:),'MarkerSize',5,'HandleVisibility','off');
        if isempty(hTrial), hTrial=h; end
        sm=report.groups(g).summary;
        if q==1, summary=sm.primary_rmse_rad; elseif q==2, summary=sm.completed_full_mae_rad; else, summary=sm.completed_command_tv_units; end
        if isfinite(summary.ci_low)
            h=errorbar(ax,g,summary.mean,summary.mean-summary.ci_low,summary.ci_high-summary.mean, ...
                'ks','MarkerFaceColor','w','LineWidth',1.1,'CapSize',8,'HandleVisibility','off');
        else
            h=plot(ax,g,summary.mean,'ks','MarkerFaceColor','w','MarkerSize',7,'HandleVisibility','off');
        end
        if isempty(hSummary), hSummary=h; end
    end
    xlim(ax,[0.5 ng+0.5]); xticks(ax,1:ng); xticklabels(ax,arrayfun(@(k)sprintf('G%02d',k),1:ng,'UniformOutput',false)); xtickangle(ax,60);
    ylabel(ax,labels{q},'Interpreter','none'); xlabel(ax,'Condition group','Interpreter','none');
    if q==1&&~isempty(hTrial)&&~isempty(hSummary)
        legend(ax,[hTrial hSummary],{'Individual trial','Completed mean / t interval'},'Location','best');
    end
end
sgtitle(tl,sprintf('%s | Trial outcomes; mean with %.0f%% t interval when n >= 2',figureScope(report),100*report.confidence_level), ...
    'FontWeight','normal','Interpreter','none');
saveFigure(f,fullfile(figDir,'trial_level_outcomes'));
makePairedFigure(report,figDir);
end

function makePairedFigure(report,figDir)
effects=report.paired_block_effects; if isempty(effects), return; end
f=figure('Color','w','Visible','off','Position',[50 50 1100 700]); c=onCleanup(@()close(f));
metricNames=unique({effects.metric},'stable'); tl=tiledlayout(f,numel(metricNames),1,'TileSpacing','compact','Padding','compact');
for q=1:numel(metricNames)
    ax=nexttile(tl); hold(ax,'on'); grid(ax,'on'); subset=effects(strcmp({effects.metric},metricNames{q}));
    for k=1:numel(subset)
        d=subset(k).differences(:); jitter=linspace(-.15,.15,numel(d));
        plot(ax,k+jitter,d,'ko','MarkerFaceColor',[.2 .45 .7],'MarkerSize',5,'HandleVisibility','off');
        if isfinite(subset(k).ci_low)
            errorbar(ax,k,subset(k).mean_difference,subset(k).mean_difference-subset(k).ci_low, ...
                subset(k).ci_high-subset(k).mean_difference,'ks','MarkerFaceColor','w','CapSize',8,'HandleVisibility','off');
        else
            plot(ax,k,subset(k).mean_difference,'ks','MarkerFaceColor','w','MarkerSize',7,'HandleVisibility','off');
        end
    end
    yline(ax,0,':','Color',[.3 .3 .3]); xlim(ax,[.5 numel(subset)+.5]);
    xticks(ax,1:numel(subset)); xticklabels(ax,arrayfun(@(k)sprintf('P%02d',k),1:numel(subset),'UniformOutput',false));
    xtickangle(ax,45);
    switch metricNames{q}
        case 'primary_rmse_rad',label='$\Delta\mathrm{RMSE}_{e}$ [rad]';
        case 'mae_rad',label='$\Delta\mathrm{MAE}_{e}$ [rad]';
        case 'command_total_variation_units',label='$\Delta\mathrm{TV}_{u}$ [command units]';
        otherwise,label=metricNames{q};
    end
    ylabel(ax,label,'Interpreter','latex');
    xlabel(ax,'Paired condition','Interpreter','none');
end
sgtitle(tl,sprintf('%s | On minus Off effects with %.0f%% t intervals',figureScope(report),100*report.confidence_level), ...
    'FontWeight','normal','Interpreter','none');
saveFigure(f,fullfile(figDir,'paired_block_effects')); clear c;
end

function label=figureScope(report)
kinds=unique(string({report.trials.recording_kind}));
if numel(kinds)==1,label=char(upper(kinds));else,label='MIXED SOURCES; groups remain separate';end
end

function saveFigure(f,base)
savefig(f,[base '.fig']);
exportgraphics(f,[base '.eps'],'ContentType','vector','BackgroundColor','white');
exportgraphics(f,[base '.pdf'],'ContentType','vector','BackgroundColor','white');
end
