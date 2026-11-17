function validation = validate_model(candidate,validationRuns,opts)
%VALIDATE_MODEL Freeze theta and assess independent complete-run data.
% A declared prefix estimates nuisance initial velocity for EACH model. Metrics
% exclude that prefix. Synthetic/replay runs are permitted for diagnostics;
% only physical same-hardware hashes can satisfy promotion gates.
if nargin<3,opts=struct();end
opts=localMerge(struct('initial_state_fit_window_s',[],'substeps',4,'initial_velocity_bounds',[-Inf Inf], ...
 'baseline_theta',[49.3401 .4569 .5586],'criteria',struct(),'report_path',''),opts);
assert(~isempty(opts.initial_state_fit_window_s)&&opts.initial_state_fit_window_s>0,'pendulumlab:StateWindow','Specify positive initial_state_fit_window_s.');
assert(isfield(candidate,'status')&&strcmp(candidate.status,'candidate'),'pendulumlab:CandidateStatus','Validation requires a candidate model.');
assert(isfield(candidate,'theta')&&numel(candidate.theta)==3,'pendulumlab:Candidate','Candidate theta missing.');
assert(~isempty(validationRuns),'pendulumlab:NoValidationRuns','At least one complete independent holdout run is required.');
D=localPrepare(validationRuns); hardware=string(candidate.hardware_id);
if any(string({D.recording_kind})=="physical"),localVerifyPersistedCandidate(candidate);end
assert(all(string({D.hardware_id})==hardware),'pendulumlab:ValidationHardware','Validation hardware must match candidate hardware.');
trainIds=string(candidate.training.run_ids);trainHashes=string(candidate.training.raw_hashes);trainSignals=string(candidate.training.signal_sha256);
assert(isempty(intersect(trainIds,string({D.run_id})))&&isempty(intersect(trainHashes,string({D.raw_hash})))&&isempty(intersect(trainSignals,string({D.signal_sha256}))), ...
 'pendulumlab:ValidationLeakage','Validation run IDs, raw source hashes, and content hashes must be disjoint from training.');
perRun=repmat(struct('run_id','','raw_hash','','hardware_id','','recording_kind','','state_fit_samples',0, ...
 'candidate_initial_velocity_fit_rad_s',NaN,'baseline_initial_velocity_fit_rad_s',NaN, ...
 'candidate_rmse_rad',NaN,'baseline_rmse_rad',NaN,'candidate_mae_rad',NaN,'baseline_mae_rad',NaN, ...
 'candidate_peak_abs_error_rad',NaN,'baseline_peak_abs_error_rad',NaN,'candidate_bias_rad',NaN,'baseline_bias_rad',NaN,'candidate_acf',[], ...
 'candidate_command_corr_lags',[],'angle_bin_rmse_rad',[],'command_shift_rmse_rad',[], ...
 'substep_doubling_max_abs_rad',NaN,'n_scored',0,'powered_samples',0, ...
 'powered_duration_s',0,'powered_rmse_rad',NaN,'powered_bias_rad',NaN, ...
 'candidate_prediction',[],'baseline_prediction',[]),numel(D),1);
scoredAngles=[];scoredCommands=[];
for k=1:numel(D)
 d=D(k);prefix=find(d.t-d.t(1)<=opts.initial_state_fit_window_s);
 assert(numel(prefix)>=4&&prefix(end)<numel(d.t),'pendulumlab:StateWindow','Fit prefix needs >=4 points and must leave scored data.');
 vC=localFitV0(candidate,d,prefix,opts);vB=localFitV0(opts.baseline_theta,d,prefix,opts);
 yc=localPredict(candidate,d.t,d.u,[vC;d.y(1)],opts.substeps);
 yb=pendulumlab.simulate_output(opts.baseline_theta,d.t,d.u,[vB;d.y(1)],opts.substeps);
 ix=(prefix(end)+1):numel(d.t);e=yc(ix)-d.y(ix);eb=yb(ix)-d.y(ix);
 scoredAngles=[scoredAngles;d.y(ix)];scoredCommands=[scoredCommands;d.u(ix)]; %#ok<AGROW>
 ac=localAcf(e,10);lags=-3:3;cc=nan(size(lags));for j=1:numel(lags),cc(j)=localLagCorr(e,d.u(ix),lags(j));end
 shiftRMSE=nan(1,3);shifts=-1:1;
 for j=1:numel(shifts),us=localShift(d.u,shifts(j));vs=localFitV0(candidate,struct('t',d.t,'u',us,'y',d.y),prefix,opts);ys=localPredict(candidate,d.t,us,[vs;d.y(1)],opts.substeps);shiftRMSE(j)=sqrt(mean((ys(ix)-d.y(ix)).^2));end
 yc2=localPredict(candidate,d.t,d.u,[vC;d.y(1)],2*opts.substeps);
 powered=d.u(ix)>0;powerRMSE=NaN;powerBias=NaN;
 if any(powered),powerRMSE=sqrt(mean(e(powered).^2));powerBias=mean(e(powered));end
 step=median(diff(d.t));
 perRun(k)=struct('run_id',d.run_id,'raw_hash',d.raw_hash,'hardware_id',d.hardware_id,'recording_kind',d.recording_kind, ...
 'state_fit_samples',numel(prefix),'candidate_initial_velocity_fit_rad_s',vC,'baseline_initial_velocity_fit_rad_s',vB, ...
 'candidate_rmse_rad',sqrt(mean(e.^2)),'baseline_rmse_rad',sqrt(mean(eb.^2)),'candidate_mae_rad',mean(abs(e)),'baseline_mae_rad',mean(abs(eb)), ...
 'candidate_peak_abs_error_rad',max(abs(e)),'baseline_peak_abs_error_rad',max(abs(eb)),'candidate_bias_rad',mean(e),'baseline_bias_rad',mean(eb), ...
 'candidate_acf',ac,'candidate_command_corr_lags',cc,'angle_bin_rmse_rad',localAngleBins(d.y(ix),e), ...
 'command_shift_rmse_rad',shiftRMSE,'substep_doubling_max_abs_rad',max(abs(yc2-yc)), ...
 'n_scored',numel(ix),'powered_samples',sum(powered),'powered_duration_s',sum(powered)*step, ...
 'powered_rmse_rad',powerRMSE,'powered_bias_rad',powerBias, ...
 'candidate_prediction',yc,'baseline_prediction',yb);
end
criteria=opts.criteria;frozen=localCriteriaFrozen(criteria);passed=false;
physical=all(string({D.recording_kind})=="physical")&&all([D.raw_hash_sha256])&&all([D.acceptable_status])&&all([D.source_file_verified]);
if frozen
 passed=all([perRun.candidate_rmse_rad]<=criteria.max_candidate_rmse_rad);
 checks=struct('full_record_rmse',passed);
 rules={'max_abs_bias_rad','candidate_bias_rad','abs'; ...
     'max_peak_abs_error_rad','candidate_peak_abs_error_rad','max'; ...
     'max_substep_doubling_rad','substep_doubling_max_abs_rad','max'; ...
     'max_powered_rmse_rad','powered_rmse_rad','max'; ...
     'max_abs_powered_bias_rad','powered_bias_rad','abs'; ...
     'min_powered_duration_s','powered_duration_s','min'};
 for ri=1:size(rules,1)
     key=rules{ri,1};if ~isfield(criteria,key),continue,end
     values=[perRun.(rules{ri,2})];
     if strcmp(rules{ri,3},'abs'),values=abs(values);end
     if strcmp(rules{ri,3},'min'),ok=all(isfinite(values)&values>=criteria.(key));
     else,ok=all(isfinite(values)&values<=criteria.(key));end
     checks.(key)=ok;passed=passed&&ok;
 end
 if isfield(criteria,'require_acquisition_binding')&&isequal(criteria.require_acquisition_binding,true)
     binding=true;
     for k=1:numel(D)
         if ~strcmp(D(k).recording_kind,'physical'),binding=false;continue,end
         raw=load(D(k).source_file,'result');meta=raw.result.metadata;
         fields={'validation_candidate_sha256','validation_criteria_sha256'};
         bound=all(isfield(meta.config,fields))&&isfield(candidate,'registry_file_hash')&& ...
             strcmp(meta.config.validation_candidate_sha256,candidate.registry_file_hash)&& ...
             strcmp(meta.config.validation_criteria_sha256,criteria.criteria_sha256);
         stamp=pendulumlab.parse_utc(meta.timestamp);declared=pendulumlab.parse_utc(criteria.frozen_at_utc);
         binding=binding&&bound&&stamp>=declared;
     end
     checks.preacquisition_candidate_and_criteria_binding=binding;passed=passed&&binding;
 end
 reason='Caller-frozen per-run accuracy, positive-command and numerical limits applied where declared; remaining diagnostics are descriptive.';
else
 checks=struct();
 reason='No verifiably frozen acceptance criterion; diagnostic only and not promotable.';
end
validation=struct('schema_version','pendulumlab.validation/1','candidate_id',candidate.model_id, ...
 'candidate_theta',candidate.theta,'candidate_theta_sha256',localHash(candidate.theta), ...
 'candidate_model_descriptor_sha256',pendulumlab.model_descriptor_sha256(candidate), ...
 'hardware_id',char(hardware),'physical_promotion_eligible',physical, ...
 'include',struct('run_ids',{string({D.run_id})},'raw_hashes',{string({D.raw_hash})},'signal_sha256',{string({D.signal_sha256})}, ...
 'observed_angle_range_rad',[min(scoredAngles) max(scoredAngles)], ...
 'observed_command_range',[min(scoredCommands) max(scoredCommands)], ...
 'domain_definition','Extrema on scored held-out samples after initial-state prefix; empirical coverage, not full-state or stability certification', ...
 'recording_kinds',{string({D.recording_kind})},'hardware_ids',{string({D.hardware_id})}, ...
 'status_codes',{string({D.status_code})},'raw_hashes_sha256',{[D.raw_hash_sha256]},'source_files_verified',{[D.source_file_verified]},'source_files',{string({D.source_file})}, ...
 'criteria_frozen',frozen,'passed',passed,'report_hash',''), ...
 'criteria',criteria,'criteria_sha256',localHash(criteria),'criteria_evaluation',checks,'reason',reason, ...
 'state_fit_window_s',opts.initial_state_fit_window_s,'initial_velocity_bounds',opts.initial_velocity_bounds, ...
 'initial_velocity_bounds_text',{cellstr(compose('%.17g',opts.initial_velocity_bounds))}, ...
 'substeps',opts.substeps,'device_timing_diagnostics',{ {D.device_timing} },'per_run',perRun,'summary',struct( ...
 'candidate_mean_rmse_rad',mean([perRun.candidate_rmse_rad]),'baseline_mean_rmse_rad',mean([perRun.baseline_rmse_rad]), ...
 'candidate_rmse_by_run_rad',[perRun.candidate_rmse_rad],'baseline_rmse_by_run_rad',[perRun.baseline_rmse_rad]), ...
 'created_utc',char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z''')));
validation.include.report_hash=localHash(validation);
if strlength(string(opts.report_path))>0
 [allowed,reason]=pendulumlab.output_location_allowed(fileparts(char(opts.report_path)),'mock');assert(allowed,'pendulumlab:ReportPath','%s',reason);assert(~isfile(opts.report_path),'pendulumlab:ReportImmutable','Refusing to overwrite an existing validation report.');
temp=[tempname(fileparts(char(opts.report_path))) '.json'];fid=fopen(temp,'w');assert(fid>=0,'pendulumlab:ReportPath','Cannot create validation report.');c=onCleanup(@()fclose(fid));fwrite(fid,jsonencode(validation),'char');clear c;[ok,msg]=movefile(temp,char(opts.report_path));assert(ok,'pendulumlab:ReportPath','Could not commit validation report: %s',msg);
end
end
function D=localPrepare(runs)
D=repmat(struct('run_id','','hardware_id','','recording_kind','','raw_hash','','source_file','','source_file_verified',false,'signal_sha256','','status_code','','raw_hash_sha256',false,'acceptable_status',false,'device_timing',struct(),'t',[],'y',[],'u',[]),numel(runs),1);
for k=1:numel(runs)
 r=runs(k);s=r.signals;m=r.metadata;assert(all(isfield(s,{'t','angle','u_command'})),'pendulumlab:ValidationSignals','Require t, angle, u_command.');
 d=struct('run_id',localText(localGet(m,'run_id',localGet(m,'trial_id',sprintf('val_%03d',k)))), ...
 'hardware_id',localText(localGet(m,'hardware_id','')),'recording_kind',localText(localGet(r,'recording_kind','')), ...
 'raw_hash',localText(localGet(localGet(r,'provenance',struct()),'source_sha256',localGet(m,'source_sha256',''))), ...
 'source_file',localText(localGet(localGet(r,'provenance',struct()),'source_file','')), ...
 'status_code',localText(localGet(localGet(r,'status',struct()),'code','unknown')), ...
 't',double(s.t(:)),'y',double(s.angle(:)),'u',double(s.u_command(:)));
 d.signal_sha256=localHash(struct('t',d.t,'angle',d.y,'u_command',d.u));
 d.device_timing=struct('available',false,'median_sample_period_s',NaN,'median_offset_s',NaN,'max_offset_deviation_s',NaN);
 if isfield(s,'t_device')&&numel(s.t_device)==numel(d.t)&&all(isfinite(s.t_device(:)))&&all(diff(s.t_device(:))>0),td=double(s.t_device(:));dev=td-d.t;d.device_timing=struct('available',true,'median_sample_period_s',median(diff(td)),'median_offset_s',median(dev),'max_offset_deviation_s',max(abs(dev-median(dev))));end
 assert(numel(d.t)==numel(d.y)&&numel(d.u)==numel(d.t)&&all(isfinite([d.t;d.y;d.u]))&&all(diff(d.t)>0),'pendulumlab:ValidationData','Invalid validation run.');
 if isfield(s,'read_valid'),assert(all(logical(s.read_valid(:))),'pendulumlab:InvalidReadMask','Invalid read mask.');end
 if isfield(s,'write_succeeded'),assert(all(logical(s.write_succeeded(:))),'pendulumlab:InvalidWriteMask','Command write failures in validation run.');end
 d.raw_hash_sha256=~isempty(regexp(d.raw_hash,'^[0-9a-fA-F]{64}$','once'));
 d.source_file_verified=~isempty(d.source_file)&&isfile(d.source_file)&&d.raw_hash_sha256;
 if d.source_file_verified,d.source_file_verified=strcmpi(pendulumlab.file_hash(d.source_file),d.raw_hash);end
 if strcmp(d.recording_kind,'physical')&&d.source_file_verified
  assert(localRawMatches(d.source_file,d.run_id,d.hardware_id,d.recording_kind,d.status_code,d.t,d.y,d.u), ...
   'pendulumlab:RawRecordMismatch','In-memory physical signals/identity differ from the SHA-verified MAT record.');
 end
 d.acceptable_status=any(strcmp(d.status_code,{'completed','complete','legacy_imported'}));D(k)=d;
end
assert(numel(unique(string({D.run_id})))==numel(D)&&numel(unique(string({D.raw_hash})))==numel(D)&&numel(unique(string({D.signal_sha256})))==numel(D),'pendulumlab:ValidationDuplicate','Validation IDs, raw hashes, and signal-content hashes must be unique.');
end
function tf=localCriteriaFrozen(c)
tf=false;if ~isstruct(c)||~isfield(c,'criteria_frozen')||~isequal(c.criteria_frozen,true),return,end
required={'id','frozen_by','frozen_at_utc','criteria_sha256','max_candidate_rmse_rad'};
if ~all(isfield(c,required)),return,end
if isempty(c.id)||~isfinite(c.max_candidate_rmse_rad)||c.max_candidate_rmse_rad<0,return,end
for key={'max_abs_bias_rad','max_peak_abs_error_rad','max_substep_doubling_rad', ...
        'max_powered_rmse_rad','max_abs_powered_bias_rad','min_powered_duration_s'}
 if isfield(c,key{1})
     value=c.(key{1});if ~isnumeric(value)||~isscalar(value)||~isfinite(value)||value<0,return,end
 end
end
copy=c;copy.criteria_sha256='';if ~strcmpi(localHash(copy),c.criteria_sha256),return,end
try,stamp=datetime(c.frozen_at_utc,'InputFormat','yyyy-MM-dd''T''HH:mm:ss''Z''','TimeZone','UTC');tf=stamp<=datetime('now','TimeZone','UTC');catch,tf=false;end
end
function v=localFitV0(model,d,ix,o)
obj=@(v)localPredict(model,d.t(ix),d.u(ix),[v;d.y(1)],o.substeps)-d.y(ix);
if exist('lsqnonlin','file')==2
 op=optimoptions('lsqnonlin','Display','off','MaxIterations',100,'MaxFunctionEvaluations',300);
 v=lsqnonlin(obj,0,o.initial_velocity_bounds(1),o.initial_velocity_bounds(2),op);
else
 lo=o.initial_velocity_bounds(1);hi=o.initial_velocity_bounds(2);
 if isfinite(lo)&&isfinite(hi),v=fminbnd(@(z)sum(obj(z).^2),lo,hi,optimset('Display','off'));
 elseif isfinite(lo),z=fminsearch(@(q)sum(obj(lo+exp(min(q,35))).^2),log(max(0-lo,1e-3)),optimset('Display','off'));v=lo+exp(min(z,35));
 elseif isfinite(hi),z=fminsearch(@(q)sum(obj(hi-exp(min(q,35))).^2),log(max(hi,1e-3)),optimset('Display','off'));v=hi-exp(min(z,35));
 else,v=fminsearch(@(z)sum(obj(z).^2),0,optimset('Display','off'));end
end
end
function y=localPredict(model,t,u,x0,substeps)
if isstruct(model),y=pendulumlab.predict_recorded_model(model,t,u,x0,substeps);
else,y=pendulumlab.simulate_output(double(model(:).'),t,u,x0,substeps);end
end
function u=localShift(u0,n)
u=u0;if n>0,u=[repmat(u0(1),n,1);u0(1:end-n)];elseif n<0,k=-n;u=[u0(k+1:end);repmat(u0(end),k,1)];end
end
function a=localAcf(e,n),a=nan(1,n);for k=1:n,if numel(e)>k,a(k)=localCorr(e(1:end-k),e(1+k:end));end,end,end
function c=localLagCorr(e,u,l),if l>=0,a=e(1+l:end);b=u(1:end-l);else,a=e(1:end+l);b=u(1-l:end);end;c=localCorr(a,b);end
function c=localCorr(a,b),a=a(:)-mean(a);b=b(:)-mean(b);z=sqrt(sum(a.^2)*sum(b.^2));if z==0,c=NaN;else,c=sum(a.*b)/z;end,end
function b=localAngleBins(y,e),edges=linspace(min(y),max(y)+eps,6);b=nan(1,5);for j=1:5,ix=y>=edges(j)&y<edges(j+1);if any(ix),b(j)=sqrt(mean(e(ix).^2));end,end,end
function h=localHash(s),h=pendulumlab.json_integrity_sha256(s);end
function tf=localRawMatches(path,rid,hardware,kind,status,t,y,u)
tf=false;try,z=load(path,'result');if ~isfield(z,'result'),return,end;r=z.result;m=r.metadata;s=r.signals;
 rawId=localText(localGet(m,'run_id',localGet(m,'trial_id','')));rawHardware=localText(localGet(m,'hardware_id',''));rawStatus=localText(localGet(r.status,'code',''));
 tf=strcmp(localText(r.recording_kind),kind)&&strcmp(rawId,rid)&&strcmp(rawHardware,hardware)&&strcmp(rawStatus,status)&& ...
  strcmp(localText(localGet(m,'phase','')),'validation')&&startsWith(localText(localGet(m,'experiment_id','')),'validation_')&& ...
  isequal(double(s.t(:)),t)&&isequal(double(s.angle(:)),y)&&isequal(double(s.u_command(:)),u);
catch,tf=false;end
end
function v=localGet(s,n,d),if isstruct(s)&&isfield(s,n),v=s.(n);else,v=d;end,end
function s=localText(v),if isstring(v),s=char(v);elseif ischar(v),s=v;else,s='';end,end
function out=localMerge(def,in),out=def;f=fieldnames(in);for ii=1:numel(f),assert(isfield(def,f{ii}),'pendulumlab:Option','Unknown option %s',f{ii});out.(f{ii})=in.(f{ii});end,end




function localVerifyPersistedCandidate(c)
assert(isfield(c,'registry_file_hash')&&isfield(c,'registry_path')&&strcmpi(pendulumlab.file_hash(c.registry_path),c.registry_file_hash), ...
 'pendulumlab:CandidateHash','Physical holdout requires candidate loaded from immutable hash-verified registry.');
s=jsondecode(fileread(c.registry_path));assert(strcmp(s.model_id,c.model_id)&&strcmp(s.status,'candidate')&&isequal(double(s.theta(:)),double(c.theta(:)))&&strcmp(s.hardware_id,c.hardware_id), ...
 'pendulumlab:CandidateHash','In-memory candidate differs from persisted candidate.');
assert(strcmp(pendulumlab.model_descriptor_sha256(c),pendulumlab.model_descriptor_sha256(s)), ...
    'pendulumlab:CandidateHash','Physical model/input descriptor differs from persisted candidate.');
for f={'run_ids','raw_hashes','source_files','source_files_verified','raw_hash_sha256','signal_sha256','recording_kinds','hardware_ids','status_codes'}
 lhs=string(c.training.(f{1}));rhs=string(s.training.(f{1}));assert(isequal(lhs(:),rhs(:)),'pendulumlab:CandidateHash','Persisted training provenance differs (%s).',f{1});
end
end

