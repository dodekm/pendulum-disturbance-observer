function audit=audit_pendulum_control_run(resultPath,options)
%AUDIT_PENDULUM_CONTROL_RUN Create an offline per-trial control audit.
% Reads one immutable result MAT file and writes separate audit JSON/MAT files
% under the campaign derived folder (or options.OutputDir). It never modifies
% the result, manifest, campaign status, or other provenance files.
arguments
    resultPath (1,1) string
    options.OutputDir (1,1) string = ""
end
root=fileparts(mfilename('fullpath'));addpath(fullfile(root,'experiment_framework'));
resultPath=char(resultPath);
assert(isfile(resultPath),'pendulumlab:AuditInput','Result MAT file does not exist.');
loaded=load(resultPath,'result');
assert(isfield(loaded,'result')&&isstruct(loaded.result),'pendulumlab:AuditInput', ...
    'Expected a MAT file containing the result struct.');
r=loaded.result;
assert(isfield(r,'recording_kind')&&strcmp(r.recording_kind,'physical'), ...
    'pendulumlab:AuditKind','This audit is for physical run results.');
meta=getOr(r,'metadata',struct());
assert(any(strcmp(getOr(meta,'phase',''),{'pilot','confirmatory'})), ...
    'pendulumlab:AuditPhase','Expected a physical pilot or confirmatory control result.');
s=getOr(r,'signals',struct());status=getOr(r,'status',struct());
cfg=getOr(meta,'config',struct());
times=double(getOr(s,'t',zeros(0,1)));times=times(:);n=numel(times);
angle=fitLength(getOr(s,'angle',nan(n,1)),n);
reference=fitLength(getOr(s,'reference',nan(n,1)),n);
valid=logical(fitLength(getOr(s,'read_valid',false(n,1)),n))&isfinite(angle)&isfinite(reference);
writeOK=logical(fitLength(getOr(s,'write_succeeded',false(n,1)),n));
q=fitLength(getOr(s,'u_command',nan(n,1)),n);
saturated=logical(fitLength(getOr(s,'saturated',false(n,1)),n));

initialization=getOr(meta,'initialization',struct());
plateaus=plateauRanges(cfg);
perPlateau=repmat(emptyPlateau(),size(plateaus,1),1);
for k=1:size(plateaus,1)
    lo=plateaus(k,1);hi=plateaus(k,2);ix=valid&times>=lo&times<hi;
    e=reference(ix)-angle(ix);y=angle(ix);
    item=emptyPlateau();item.start_s=lo;item.end_s=hi;item.sample_count=sum(ix);
    if ~isempty(e)
        item.rmse_rad=sqrt(mean(e.^2));item.bias_rad=mean(e);
        item.peak_abs_error_rad=max(abs(e));item.angle_peak_to_peak_rad=max(y)-min(y);
        item.angle_min_rad=min(y);item.angle_max_rad=max(y);
    end
    perPlateau(k)=item;
end
e=reference(valid)-angle(valid);yv=angle(valid);
angleSummary=struct('valid_sample_count',sum(valid),'minimum_rad',NaN,'maximum_rad',NaN, ...
    'minimum_deg',NaN,'maximum_deg',NaN,'overall_tracking_rmse_rad',NaN, ...
    'overall_tracking_bias_rad',NaN,'overall_peak_abs_error_rad',NaN);
if ~isempty(yv)
    angleSummary.minimum_rad=min(yv);angleSummary.maximum_rad=max(yv);
    angleSummary.minimum_deg=rad2deg(min(yv));angleSummary.maximum_deg=rad2deg(max(yv));
    angleSummary.overall_tracking_rmse_rad=sqrt(mean(e.^2));
    angleSummary.overall_tracking_bias_rad=mean(e);
    angleSummary.overall_peak_abs_error_rad=max(abs(e));
end

tDevice=fitLength(getOr(s,'t_device',nan(n,1)),n);
tHost=fitLength(getOr(s,'t_host',nan(n,1)),n);
writeStart=fitLength(getOr(s,'write_start_host',nan(n,1)),n);
writeEnd=fitLength(getOr(s,'write_end_host',nan(n,1)),n);
timing=struct('nominal_sample_interval_s',intervalSummary(times), ...
    'device_relative_interval_s',intervalSummary(tDevice), ...
    'host_relative_interval_s',intervalSummary(tHost), ...
    'successful_write_start_interval_s',intervalSummary(writeStart,writeOK&isfinite(q)), ...
    'write_call_duration_s',valueSummary(writeEnd-writeStart,writeOK));
rawMask=writeOK&isfinite(q);rawValues=q(rawMask);
writeAttempted=logical(fitLength(getOr(s,'write_attempted',false(n,1)),n));
rawCommand=struct('unit','raw motor command units (wire payload q)', ...
    'successful_write_sample_count',sum(rawMask),'minimum',NaN,'maximum',NaN, ...
    'maximum_adjacent_successful_write_slew_units_s',NaN, ...
    'saturated_sample_count',sum(saturated),'attempted_write_count',sum(writeAttempted), ...
    'successful_write_count',sum(writeOK));
if ~isempty(rawValues),rawCommand.minimum=min(rawValues);rawCommand.maximum=max(rawValues);end
if n>=2
    pair=rawMask(1:end-1)&rawMask(2:end)&isfinite(writeStart(1:end-1))&isfinite(writeStart(2:end));
    dt=writeStart(2:end)-writeStart(1:end-1);dq=abs(q(2:end)-q(1:end-1));
    pair=pair&isfinite(dt)&dt>0;
    if any(pair),rawCommand.maximum_adjacent_successful_write_slew_units_s=max(dq(pair)./dt(pair));end
end

coordinateAudit=coordinateChecks(r,s,n,writeOK);
statusSummary=struct('code',getOr(status,'code','unknown'),'reason',getOr(status,'reason',''), ...
    'planned_sample_count',getOr(meta,'planned_sample_count',n),'logged_sample_count',n, ...
    'read_valid_count',sum(valid),'read_attempt_count',getOr(status,'read_attempt_count',NaN), ...
    'read_success_count',getOr(status,'read_count',NaN),'rest_read_count',getOr(status,'rest_read_count',NaN), ...
    'trial_read_count',getOr(status,'trial_read_count',NaN), ...
    'write_attempt_count',getOr(status,'write_count',NaN), ...
    'command_write_count',getOr(status,'command_write_count',NaN), ...
    'write_success_count',sum(writeOK),'stop_requested',getOr(status,'stop_requested',false), ...
    'stop_succeeded',getOr(status,'stop_succeeded',false),'link_closed',getOr(status,'link_closed',false), ...
    'exception',getOr(status,'exception',''),'save_exception',getOr(status,'save_exception',''));
restSummary=struct('rest_passed',getOr(initialization,'rest_passed',false), ...
    'rest_range_rad',getOr(initialization,'rest_range_rad',NaN), ...
    'rest_slope_rad_s',getOr(initialization,'rest_slope_rad_s',NaN), ...
    'rest_planned_sample_count',numel(getOr(initialization,'rest_angle_rad',[])), ...
    'rest_valid_sample_count',0, ...
    'observed_angle_min_rad',NaN,'observed_angle_max_rad',NaN);
if isfield(initialization,'rest_angle_rad')&&~isempty(initialization.rest_angle_rad)
    a=double(initialization.rest_angle_rad(:));a=a(isfinite(a));
    restSummary.rest_valid_sample_count=numel(a);
    if ~isempty(a),restSummary.observed_angle_min_rad=min(a);restSummary.observed_angle_max_rad=max(a);end
end

provenance=getOr(meta,'frozen_provenance',struct());
audit=struct('schema_version','pendulumlab.control_run_audit/1', ...
    'created_utc',char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss.SSSXXX')), ...
    'source_result_path',resultPath,'source_result_sha256',pendulumlab.file_hash(resultPath), ...
    'recording_kind',r.recording_kind,'run_id',getOr(meta,'run_id',''), ...
    'campaign_id',getOr(meta,'campaign_id',''),'phase',getOr(meta,'phase',''), ...
    'experiment_id',getOr(meta,'experiment_id',''),'hardware_id',getOr(meta,'hardware_id',''), ...
    'model_id',getOr(meta,'model_id',''),'model_status',getOr(meta,'model_status',''), ...
    'use_compensation',getOr(meta,'use_compensation',false),'T_s',getOr(meta,'T',NaN), ...
    'sample_period_s',getOr(meta,'Ts',NaN),'result_status',statusSummary, ...
    'initialization',restSummary,'timing',timing,'angle_tracking',angleSummary, ...
    'plateaus',perPlateau,'raw_command',rawCommand,'input_coordinate_audit',coordinateAudit, ...
    'frozen_provenance',provenance, ...
    'interpretation_limits',['u_command is the transmitted raw command, not measured actuator output; mapped input is an effective coordinate, not thrust/torque. ', ...
        'Timing is nominal/device/host logging evidence, not an independent actuator-latency or force measurement.']);
if strlength(options.OutputDir)>0
    outDir=char(options.OutputDir);
else
    outDir=fullfile(fileparts(fileparts(resultPath)),'derived','control_run_audits');
end
if ~isfolder(outDir),mkdir(outDir);end
runId=char(string(getOr(meta,'run_id','run')));runId=regexprep(runId,'[^A-Za-z0-9_-]','_');
stamp=char(datetime('now','TimeZone','UTC','Format','yyyyMMdd_HHmmss_SSS'));
baseName=['audit_' runId '_' stamp];matPath=fullfile(outDir,[baseName '.mat']);jsonPath=fullfile(outDir,[baseName '.json']);
assert(~isfile(matPath)&&~isfile(jsonPath),'pendulumlab:AuditOutput','Audit output already exists; refusing overwrite.');
audit.output_mat=matPath;audit.output_json=jsonPath;
save(matPath,'audit','-v7');
fid=fopen(jsonPath,'wt');assert(fid>=0,'pendulumlab:AuditOutput','Could not create audit JSON.');
cleanup=onCleanup(@()fclose(fid));fprintf(fid,'%s',jsonencode(audit,PrettyPrint=true));clear cleanup
fprintf('AUDIT %s status=%s valid=%d/%d qRange=%s saturated=%d\n',runId, ...
    statusSummary.code,sum(valid),n,mat2str([rawCommand.minimum rawCommand.maximum],5),rawCommand.saturated_sample_count);
end

function ranges=plateauRanges(cfg)
ranges=zeros(0,2);
if isfield(cfg,'protocol')&&isstruct(cfg.protocol)&&isfield(cfg.protocol,'reference_plateau_ranges_s')
    ranges=double(cfg.protocol.reference_plateau_ranges_s);
elseif isfield(cfg,'analysis')&&isstruct(cfg.analysis)&&isfield(cfg.analysis,'evaluation_windows')&& ...
        isfield(cfg.analysis.evaluation_windows,'tracking_plateaus_s')
    ranges=double(cfg.analysis.evaluation_windows.tracking_plateaus_s);
end
if isempty(ranges),ranges=zeros(0,2);return,end
if size(ranges,2)~=2,ranges=zeros(0,2);end
end

function x=fitLength(x,n)
x=double(x(:));if numel(x)~=n,x=nan(n,1);end
end

function q=intervalSummary(t,mask)
t=double(t(:));if nargin<2,mask=true(size(t));else,mask=logical(mask(:));end
if numel(mask)~=numel(t),mask=false(size(t));end
if numel(t)>1
    dt=diff(t);both=mask(1:end-1)&mask(2:end);
    keep=both&isfinite(dt)&dt>0;vals=dt(keep);
    nonpositive=sum(both&isfinite(dt)&dt<=0);
else
    vals=zeros(0,1);nonpositive=0;
end
q=struct('valid_interval_count',numel(vals),'nonpositive_interval_count',nonpositive, ...
    'minimum_s',NaN,'median_s',NaN,'p95_s',NaN,'maximum_s',NaN);
if ~isempty(vals)
    vals=sort(vals);q.minimum_s=vals(1);q.median_s=median(vals);q.maximum_s=vals(end);
    at=1+.95*(numel(vals)-1);lo=floor(at);hi=ceil(at);
    q.p95_s=vals(lo)+(at-lo)*(vals(hi)-vals(lo));
end
end

function q=valueSummary(x,mask)
x=double(x(:));if nargin<2,mask=true(size(x));else,mask=logical(mask(:));end
if numel(mask)~=numel(x),mask=false(size(x));end
v=x(mask&isfinite(x));
q=struct('valid_value_count',numel(v),'minimum_s',NaN,'median_s',NaN, ...
    'p95_s',NaN,'maximum_s',NaN);
if ~isempty(v)
    v=sort(v);q.minimum_s=v(1);q.median_s=median(v);q.maximum_s=v(end);
    at=1+.95*(numel(v)-1);lo=floor(at);hi=ceil(at);
    q.p95_s=v(lo)+(at-lo)*(v(hi)-v(lo));
end
end

function c=coordinateChecks(r,s,n,writeOK)
q=fitLength(getOr(s,'u_command',nan(n,1)),n);
qNom=fitLength(getOr(s,'q_nominal',nan(n,1)),n);
uNom=fitLength(getOr(s,'u_nominal',nan(n,1)),n);
uTotal=fitLength(getOr(s,'u_model_command',nan(n,1)),n);
wEff=fitLength(getOr(s,'w_injected_effective',nan(n,1)),n);
mask=writeOK&isfinite(q)&isfinite(qNom)&isfinite(uNom)&isfinite(uTotal)&isfinite(wEff);
meta=getOr(r,'metadata',struct());cal=getOr(meta,'actuator_calibration',struct());
calibrated=isfield(cal,'enabled')&&isequal(cal.enabled,true);
c=struct('calibrated_input_coordinates',calibrated, ...
    'raw_command_signal','u_command: raw transmitted motor command q', ...
    'nominal_observer_input_signal','u_nominal: known base input supplied to observer', ...
    'mapped_total_input_signal','u_model_command: static mapped total command coordinate', ...
    'mapped_input_is_measured_force',false,'samples_checked',sum(mask), ...
    'max_abs_u_nominal_map_residual',NaN,'max_abs_u_total_map_residual',NaN, ...
    'max_abs_known_plus_effective_minus_total_residual',NaN, ...
    'max_abs_requested_vs_effective_injection_residual',NaN, ...
    'calibration_id','','gamma_ref',NaN,'coefficients',[]);
if calibrated
    coeff=double(cal.coefficients(:));gamma=double(cal.gamma_ref);
    c.calibration_id=getOr(cal,'id','');c.gamma_ref=gamma;c.coefficients=coeff(:).';
    map=@(x)(coeff(1).*x+coeff(2).*x.^2/50)./gamma;
else
    map=@(x)x;
end
nominal=map(qNom);total=map(q);
if any(mask)
    c.max_abs_u_nominal_map_residual=max(abs(nominal(mask)-uNom(mask)));
    c.max_abs_u_total_map_residual=max(abs(total(mask)-uTotal(mask)));
    c.max_abs_known_plus_effective_minus_total_residual=max(abs(uNom(mask)+wEff(mask)-uTotal(mask)));
    requested=fitLength(getOr(s,'w_injected_requested',nan(n,1)),n);
    validRequested=mask&isfinite(requested);
    if any(validRequested),c.max_abs_requested_vs_effective_injection_residual= ...
            max(abs(requested(validRequested)-wEff(validRequested)));end
end
end

function p=emptyPlateau()
p=struct('start_s',NaN,'end_s',NaN,'sample_count',0,'rmse_rad',NaN, ...
    'bias_rad',NaN,'peak_abs_error_rad',NaN,'angle_peak_to_peak_rad',NaN, ...
    'angle_min_rad',NaN,'angle_max_rad',NaN);
end

function value=getOr(s,name,default)
if isstruct(s)&&isfield(s,name),value=s.(name);else,value=default;end
end
