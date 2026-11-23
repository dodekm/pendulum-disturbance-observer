function analysis = analyze_calibrated_pendulum_campaign(manifestPath,OutputDir,options)
% Offline analysis of a frozen campaign; includes partial/adverse records.
arguments
    manifestPath (1,1) string
    OutputDir (1,1) string = ""
    options.GenerateFigures (1,1) logical = true
end
assert(isfile(manifestPath),'pendulumlab:Manifest','Manifest not found.');
manifestPath=string(java.io.File(char(manifestPath)).getCanonicalPath());
folder=string(fileparts(char(manifestPath)));
projectRoot=fileparts(char(manifestPath));
while ~isfolder(fullfile(projectRoot,'experiment_framework'))&&~isempty(fileparts(projectRoot)),projectRoot=fileparts(projectRoot);end
assert(isfolder(fullfile(projectRoot,'experiment_framework')),'pendulumlab:ProjectRoot','Cannot locate experiment_framework from manifest path.');
previousPath=path;
restorePath=onCleanup(@()path(previousPath)); %#ok<NASGU>
addpath(fullfile(projectRoot,'experiment_framework'));
m=jsondecode(fileread(manifestPath));
assert(isfield(m,'schema_version')&&strcmp(m.schema_version,'pendulumlab.campaign/1')&&isfield(m,'runs'), ...
    'pendulumlab:Manifest','Expected pendulumlab.campaign/1.');
if strlength(OutputDir)==0
    tag=['analysis_' char(datetime('now','TimeZone','UTC','Format','yyyyMMdd_HHmmss_SSS'))];
    OutputDir=fullfile(folder,'derived',tag);
end
[outPath,why]=canonicalOutputPath(OutputDir,folder);
assert(isempty(why),'pendulumlab:OutputLocation','%s',why);
if within(outPath,fullfile(folder,'derived'))
    [allowed,why]=pendulumlab.output_location_allowed(OutputDir,'hardware');
else
    [allowed,why]=pendulumlab.output_location_allowed(OutputDir,'offline');
end
assert(allowed,'pendulumlab:OutputLocation','%s',why);
if isfolder(OutputDir)
    e=dir(OutputDir);e=e(~ismember({e.name},{'.','..'}));
    assert(isempty(e),'pendulumlab:OutputExists','Refusing to overwrite a nonempty output directory.');
else
    mkdir(OutputDir);
end
statusPath=fullfile(folder,'campaign_status.json');
if isfile(statusPath), status=jsondecode(fileread(statusPath)); else, status=struct('runs',struct([])); end
manifestSidecar=fullfile(folder,'campaign_manifest.sha256');
manifestHash=pendulumlab.file_hash(manifestPath);manifestHashVerified=false;
if isfile(manifestSidecar)
    manifestHashVerified=strcmpi(strtrim(fileread(manifestSidecar)),manifestHash);
end
assert(manifestHashVerified,'pendulumlab:ManifestHash','Campaign manifest SHA-256 sidecar is missing or does not match.');
planned=repmat(struct('run_id','','protocol','','condition','','block_id','','planned_order',NaN, ...
    'a_s2',NaN,'use_compensation',NaN,'T_s',NaN, ...
    'status_code','pending','status_reason','','result_file','','result_available',false, ...
    'schedule_file','','schedule_sha256','','schedule_identity_sha256','','config_sha256','', ...
    'schedule_file_sha256','','result_sha256','','integrity_verified',false,'integrity_issue',''),numel(m.runs),1);
records=cell(0,1);
for k=1:numel(m.runs)
    p=m.runs(k);st=findStatus(status,string(p.run_id));hasStatus=~isempty(fieldnames(st));
    planned(k)=struct('run_id',char(string(p.run_id)),'protocol',char(string(fieldOr(p,'protocol','unknown'))), ...
        'condition',char(string(fieldOr(p,'condition','unknown'))),'block_id',char(string(fieldOr(p,'block_id',''))), ...
        'planned_order',double(fieldOr(p,'planned_order',k)), ...
        'a_s2',double(fieldOr(p,'a',fieldOr(m,'controller_a',NaN))), ...
        'use_compensation',double(fieldOr(p,'use_compensation',NaN)),'T_s',double(fieldOr(p,'T',NaN)), ...
        'status_code',char(string(fieldOr(st,'code','pending'))), ...
        'status_reason',char(string(fieldOr(st,'reason',''))),'result_file',char(string(fieldOr(st,'result_file',''))), ...
        'result_available',false,'schedule_sha256',char(string(fieldOr(p,'schedule_sha256',''))), ...
        'schedule_identity_sha256',char(string(fieldOr(p,'schedule_identity_sha256',''))), ...
        'config_sha256',char(string(fieldOr(p,'config_sha256',''))), ...
        'schedule_file',char(string(fieldOr(p,'schedule_file',''))),'schedule_file_sha256','', 'result_sha256','', ...
        'integrity_verified',false,'integrity_issue','');
    % Read the campaign copy, even when an archived absolute path still exists
    % on this machine. Recorded paths remain provenance, not read locations.
    sched=fullfile(folder,'schedules',[char(string(p.run_id)) '.mat']);
    integrityIssue=strings(0,1);frozen=[];
    if ~hasStatus,integrityIssue(end+1)="campaign_status row missing";end %#ok<AGROW>
    if strlength(sched)>0&&isfile(sched)
        planned(k).schedule_file_sha256=pendulumlab.file_hash(sched);
        if ~strcmpi(planned(k).schedule_file_sha256,planned(k).schedule_sha256)
            integrityIssue(end+1)="schedule file hash differs from manifest"; %#ok<AGROW>
        else
            frozen=load(sched,'cfgRun','schedule');
            if ~isfield(frozen,'cfgRun')||~isfield(frozen,'schedule')
                integrityIssue(end+1)="schedule MAT lacks cfgRun/schedule"; %#ok<AGROW>
            else
                planned(k).a_s2=double(fieldOr(frozen.cfgRun,'a',planned(k).a_s2));
                if ~strcmpi(pendulumlab.json_value_sha256(frozen.cfgRun),planned(k).config_sha256)
                    integrityIssue(end+1)="frozen config hash differs from manifest"; %#ok<AGROW>
                end
                if ~strcmpi(pendulumlab.schedule_identity_sha256(frozen.schedule),planned(k).schedule_identity_sha256)
                    integrityIssue(end+1)="schedule identity differs from manifest"; %#ok<AGROW>
                end
                if ~strcmp(string(frozen.cfgRun.run_id),string(p.run_id))
                    integrityIssue(end+1)="frozen config run_id differs from plan"; %#ok<AGROW>
                end
            end
        end
    else
        integrityIssue(end+1)="frozen schedule file missing"; %#ok<AGROW>
    end
    runFile=fullfile(folder,'runs',[char(string(p.run_id)) '.mat']);
    if isfile(runFile)
        z=load(runFile,'result');
        if isfield(z,'result')&&isfield(z.result,'schema_version')&&strcmp(z.result.schema_version,'pendulumlab.run/1')
            r=z.result;h=pendulumlab.file_hash(runFile);
            if ~strcmp(string(fieldOr(r.metadata,'run_id','')),string(p.run_id))
                integrityIssue(end+1)="result metadata run_id differs from plan"; %#ok<AGROW>
            end
            if hasStatus&&isfield(st,'code')&&~strcmp(string(fieldOr(r.status,'code','')),string(planned(k).status_code))
                integrityIssue(end+1)="result status differs from campaign_status row"; %#ok<AGROW>
            end
            if ~strcmpi(string(fieldOr(r.metadata,'config_sha256','')),string(planned(k).config_sha256))
                integrityIssue(end+1)="result config hash differs from manifest"; %#ok<AGROW>
            end
            actualCfg=fieldOr(r.metadata,'config',struct());
            if ~strcmpi(pendulumlab.json_value_sha256(actualCfg),planned(k).config_sha256)
                integrityIssue(end+1)="result configuration content differs from frozen hash"; %#ok<AGROW>
            end
            fp=fieldOr(r.metadata,'frozen_provenance',struct());
            if ~strcmpi(string(fieldOr(r.metadata,'schedule_identity_sha256','')),string(planned(k).schedule_identity_sha256))|| ...
                    ~strcmpi(string(fieldOr(fp,'schedule_identity_sha256','')),string(planned(k).schedule_identity_sha256))|| ...
                    ~strcmpi(string(fieldOr(fp,'schedule_sha256','')),string(planned(k).schedule_sha256))|| ...
                    ~strcmpi(string(fieldOr(fp,'manifest_sha256','')),string(manifestHash))
                integrityIssue(end+1)="result schedule/manifest provenance differs from frozen plan"; %#ok<AGROW>
            end
            if ~isequaln(orderfields(fieldOr(fp,'source_sha256',struct())), ...
                    orderfields(fieldOr(m,'source_sha256',struct())))
                integrityIssue(end+1)="result source inventory differs from frozen plan"; %#ok<AGROW>
            end
            if isstruct(frozen)&&isfield(frozen,'cfgRun')&&isfield(frozen,'schedule')
                for nm={'theta','Ts','T','a','use_compensation'}
                    actual=double(fieldOr(r.metadata,nm{1},NaN));expected=double(frozen.cfgRun.(nm{1}));
                    if ~isequaln(actual(:),expected(:))
                        integrityIssue(end+1)="result flat control/model metadata differs from frozen configuration"; %#ok<AGROW>
                        break
                    end
                end
                rs=fieldOr(r,'signals',struct());
                if isfield(rs,'t')
                    nObserved=numel(rs.t);nPlanned=numel(frozen.schedule.t);
                    gridOK=nObserved<=nPlanned&&isequaln(double(rs.t(:)),double(frozen.schedule.t(1:nObserved)));
                    for nm={'reference','w_injected_requested'}
                        expectedName=nm{1};if strcmp(expectedName,'w_injected_requested'),expectedName='injection';end
                        actual=double(fieldOr(rs,nm{1},[]));expected=double(frozen.schedule.(expectedName));
                        gridOK=gridOK&&numel(actual)==nObserved&&nObserved<=numel(expected)&& ...
                            isequaln(actual(:),expected(1:nObserved));
                    end
                    if strcmp(planned(k).status_code,'completed'),gridOK=gridOK&&nObserved==nPlanned;end
                    if ~gridOK,integrityIssue(end+1)="logged time/reference/requested injection differ from frozen schedule";end %#ok<AGROW>
                elseif strcmp(planned(k).status_code,'completed')
                    integrityIssue(end+1)="completed result has no logged nominal time grid"; %#ok<AGROW>
                end
            end
            planned(k).result_available=true;planned(k).result_file=char(runFile);planned(k).result_sha256=h;
            if ~isfield(r,'provenance')||~isstruct(r.provenance),r.provenance=struct();end
            r.provenance.source_file=char(runFile);r.provenance.source_sha256=h;
            records{end+1}=r; %#ok<AGROW>
        else
            planned(k).status_reason=[planned(k).status_reason ' Result file lacks run/1 schema.'];
        end
    end
    if ~planned(k).result_available
        integrityIssue(end+1)="result file unavailable"; %#ok<AGROW>
    end
    planned(k).integrity_verified=isempty(integrityIssue);
    planned(k).integrity_issue=strjoin(cellstr(integrityIssue),'; ');
    if ~planned(k).integrity_verified&&planned(k).result_available
        error('pendulumlab:CampaignIntegrity','Run %s integrity check failed: %s',p.run_id,planned(k).integrity_issue);
    end
end
hashList={planned([planned.result_available]).result_sha256};
assert(numel(unique(hashList))==numel(hashList),'pendulumlab:DuplicateHash','Duplicate result-file hashes.');
if isempty(records),report=[];trials=repmat(struct(),0,1);
else
    report=pendulumlab.evaluate_campaign(records);
    trials=report.trials;
    for k=1:numel(trials)
        j=find(cellfun(@(r)strcmp(string(fieldOr(r.metadata,'run_id','')),string(trials(k).run_id)),records),1);
        assert(~isempty(j),'pendulumlab:RunMapping','Could not map evaluated trial to source record.');
        r=records{j};
        trials(k).calibrated_analysis=trialMetrics(r,trials(k));
    end
end
gainValues=unique([planned.a_s2]);gainValues=gainValues(isfinite(gainValues));
analysis=struct('schema_version','pendulumlab.calibrated_campaign_analysis/1', ...
    'created_utc',char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z''')), ...
    'execution_mode','offline file analysis only; no UART or hardware link is opened', ...
    'campaign_id',m.campaign_id,'manifest_path',char(manifestPath),'output_dir',char(OutputDir), ...
    'campaign',struct('phase',fieldOr(m,'phase',''),'hardware_id',fieldOr(m,'hardware_id',''), ...
    'model_id',fieldOr(m,'model_id',''),'model_status',fieldOr(m,'model_status',''), ...
    'a_values_s2',gainValues,'observer_T_values',fieldOr(m,'observer_T_values',[]), ...
    'u_limits_raw',fieldOr(m,'u_limits',[]),'sample_period_s',fieldOr(m,'sample_period_s',NaN), ...
    'randomization',fieldOr(m,'randomization',struct())), ...
    'planned_runs',planned,'status_counts',statusCounts(planned), ...
    'integrity_summary',struct('manifest_sidecar_verified',manifestHashVerified, ...
    'planned_rows_verified',sum([planned.integrity_verified]),'planned_rows_unverified',sum(~[planned.integrity_verified]), ...
    'rule','Manifest sidecar, frozen schedule/config/identity, result run ID/config hash, and campaign status/result code are checked per available row.'), ...
    'trials',trials, ...
    'condition_summary',conditionSummary(trials),'paired_effects',fieldOr(report,'paired_block_effects',struct([])), ...
    'paired_descriptive_summary',pairedSummary(fieldOr(report,'paired_block_effects',struct([]))), ...
    'pairing_audit',fieldOr(report,'pairing_audit',struct()), ...
    'hashes',struct('manifest_sha256',manifestHash,'manifest_sidecar_verified',manifestHashVerified, ...
    'status_sha256',hashIfFile(statusPath),'script_sha256',pendulumlab.file_hash([mfilename('fullpath') '.m']), ...
    'result_sha256',{hashList}), ...
    'interpretation','Descriptive analysis of the complete planned campaign. No runs are removed for adverse outcomes. Observer settings are stratified by T; a shared Off set is reused for each On comparison. This is not best-setting selection. Paired intervals are conditional on observed complete pairs; no p-values or stability claims.', ...
    'summary_scope','Every planned status and available trial is retained. Equal-duration condition means and trajectory bands use complete, technically valid records, including adverse valid performance. Partial records retain individual observed-data metrics and counts but are not pooled with full-duration endpoints.', ...
    'units','Error metrics: deg. Raw wire signal u_cmd is the float32 drive-command payload; raw command TV uses command units. Internal code variable q maps to u_cmd. Normalized known/model input is mathcal A(u_cmd)/gamma_ref; mapped TV uses normalized model-input units. These are not thrust, torque, power, or energy.');
save(fullfile(OutputDir,'calibrated_campaign_analysis.mat'),'analysis','report','-v7.3');
writeExports(analysis,OutputDir);
if options.GenerateFigures
    makeSummaryFigures(trials,OutputDir);
    makeIndividualFigures(trials,OutputDir);
end
end

function x=trialMetrics(r,tv)
s=r.signals;t=double(s.t(:));y=double(s.angle(:));ref=double(s.reference(:));q=double(s.u_command(:));
n=min([numel(t),numel(y),numel(ref),numel(q)]);t=t(1:n);y=y(1:n);ref=ref(1:n);q=q(1:n);e=rad2deg(ref-y);
valid=isfinite(t)&isfinite(y)&isfinite(ref);
if isfield(s,'read_valid'),valid=valid&fitLogical(s.read_valid,n);end
windows=getWindows(r.metadata,tv.protocol);
if string(tv.protocol)=="reference_tracking",spans=windows.tracking_full_s;else,spans=windows.injection_windows_s;end
primary=spanMask(t,valid,spans);full=errMetrics(e,valid);prim=errMetrics(e,primary);
uModel=fitLength(double(fieldOr(s,'u_model_command',[])),n);
write=fitLogical(fieldOr(s,'write_succeeded',[]),n);sat=fitLogical(fieldOr(s,'saturated',[]),n);
qCfg=fieldOr(fieldOr(r.metadata,'config',struct()),'u_limits',[NaN NaN]);
loHit=false(n,1);hiHit=loHit;
if numel(qCfg)==2
    tol=max(1e-6,eps(max(abs(qCfg)))*8);loHit=isfinite(q)&abs(q-qCfg(1))<=tol;hiHit=isfinite(q)&abs(q-qCfg(2))<=tol;
end
plateaus=struct();tails=struct();segments=struct();names=fieldnames(tv.window_metrics);
for k=1:numel(names)
    nm=names{k};mm=tv.window_metrics.(nm);
    if startsWith(nm,'plateau_'),plateaus.(nm)=metricWindowDeg(mm);
    elseif contains(nm,'tail'),tails.(nm)=metricWindowDeg(mm);
    elseif any(strcmp(nm,{'pre_injection','positive_injection','negative_injection','random_injection'}))
        segments.(nm)=metricWindowDeg(mm);
    end
end
if string(tv.protocol)=="reference_tracking"
    for k=1:size(windows.tracking_tails_s,1)
        key=sprintf('tail_%d',k);mask=spanMask(t,valid,windows.tracking_tails_s(k,:));
        tails.(key)=errMetrics(e,mask);tails.(key).window_s=windows.tracking_tails_s(k,:);
    end
end
x=struct('error_metrics_deg',struct('full',full,'primary',prim,'primary_spans_s',spans, ...
    'plateau_metrics',plateaus,'tail_metrics',tails,'injection_segments',segments), ...
    'raw_motor_command',struct('unit','raw u_cmd transmitted command units', ...
    'tv_full',tvAdjacent(q,write,valid),'tv_primary',tvAdjacent(q,write,primary), ...
    'configured_limits',qCfg,'software_saturation_count',sum(sat), ...
    'software_saturation_times_s',t(sat),'lower_bound_hit_count',sum(loHit), ...
    'lower_bound_hit_times_s',t(loHit),'upper_bound_hit_count',sum(hiHit),'upper_bound_hit_times_s',t(hiHit), ...
    'bound_contact_is_not_itself_a_saturation',true), ...
    'calibrated_model_input',struct('unit','normalized model-input units mathcal A(u_cmd)/gamma_ref', ...
    'tv_full',tvAdjacent(uModel,write,valid),'tv_primary',tvAdjacent(uModel,write,primary)), ...
    'observer_diagnostic',struct('signals',{{'w_hat','w_injected_filtered'}}, ...
    'unit','normalized model-input units','interpretation','Known injected increment only; total equivalent disturbance is unobserved.'));
x.summary_eligible=summaryEligible(tv);
end
function m=errMetrics(e,mask)
v=e(mask&isfinite(e));m=struct('n_samples',numel(v),'rmse_deg',NaN,'mae_deg',NaN,'bias_deg',NaN,'peak_abs_error_deg',NaN);
if isempty(v),return,end
m.rmse_deg=sqrt(mean(v.^2));m.mae_deg=mean(abs(v));m.bias_deg=mean(v);m.peak_abs_error_deg=max(abs(v));
end
function m=metricWindowDeg(a)
m=struct('n_samples',a.n_samples,'rmse_deg',rad2deg(a.rmse_rad),'mae_deg',rad2deg(a.mae_rad), ...
    'bias_deg',rad2deg(a.bias_rad),'peak_abs_error_deg',rad2deg(a.peak_abs_error_rad), ...
    'coverage_fraction',fieldOr(a,'coverage_fraction',NaN),'window_s',fieldOr(a,'window_s',[NaN NaN]));
m.demeaned_rms_deg=NaN;
if m.n_samples>0&&all(isfinite([m.rmse_deg m.bias_deg]))
    m.demeaned_rms_deg=sqrt(max(0,m.rmse_deg^2-m.bias_deg^2));
end
m.demeaned_rms_definition='sqrt(mean((e-mean(e)).^2)); descriptive within-window variation including transients, not an estimated damping coefficient or measurement-noise level';
end
function v=tvAdjacent(x,write,mask)
x=x(:);n=min([numel(x),numel(write),numel(mask)]);x=x(1:n);write=write(1:n);mask=mask(1:n);
idx=find(mask&write&isfinite(x));v=0;if numel(idx)>1,diffIdx=diff(idx)==1;dx=abs(diff(x(idx)));v=sum(dx(diffIdx));end
end
function w=getWindows(meta,protocol)
w=struct('tracking_full_s',[0 125],'tracking_plateaus_s',[0 25;25 50;50 75;75 100;100 125], ...
    'tracking_tails_s',[22 25;47 50;72 75;97 100;122 125], ...
    'injection_windows_s',[10 20;30 40;50 70]);
cfg=fieldOr(meta,'config',fieldOr(meta,'configuration',struct()));a=fieldOr(cfg,'analysis',struct());x=fieldOr(a,'evaluation_windows',struct());
for k=fieldnames(w).',if isfield(x,k{1}),w.(k{1})=double(x.(k{1}));end,end
if string(protocol)=="injected_disturbance"&&all(isfield(x,{'injection_positive_s','injection_negative_s','injection_random_s'}))
    w.injection_windows_s=[x.injection_positive_s;x.injection_negative_s;x.injection_random_s];
end
end
function mask=spanMask(t,base,spans)
mask=false(size(t));for k=1:size(spans,1),mask=mask|(t>=spans(k,1)&t<spans(k,2));end;mask=mask&base;
end
function out=conditionSummary(tr)
out=struct('protocol',{},'a_s2',{},'condition',{},'T_s',{},'common_off_reused',{},'n_trials',{},'n_completed',{},'n_summary_eligible',{}, ...
    'full_rmse_deg',{},'full_mae_deg',{}, ...
    'primary_rmse_deg',{},'primary_mae_deg',{},'primary_bias_deg',{},'primary_peak_abs_error_deg',{}, ...
    'raw_q_tv_full',{},'raw_q_tv_primary',{},'model_input_tv_full',{},'model_input_tv_primary',{});
if isempty(tr),return,end
for p=unique(string({tr.protocol}))
    protocolMask=strcmp(string({tr.protocol}),p);gains=unique([tr(protocolMask).a]);gains=gains(isfinite(gains));
    for aSet=gains
        gainMask=protocolMask&abs([tr.a]-aSet)<1e-12;
        onMask=gainMask&[tr.use_compensation]==1;settings=unique([tr(onMask).T]);settings=settings(isfinite(settings));
        if isempty(settings),settings=NaN;end
        for tSet=settings
            for on=[0 1]
                ix=gainMask&[tr.use_compensation]==on;
                if on==1,ix=ix&abs([tr.T]-tSet)<1e-12;end
                allTrials=tr(ix);if isempty(allTrials),continue,end
                eligible=arrayfun(@summaryEligible,allTrials);ss=allTrials(eligible);a=nan(numel(ss),10);
                for j=1:numel(ss)
                    z=ss(j).calibrated_analysis;f=z.error_metrics_deg.full;u=z.error_metrics_deg.primary;
                    a(j,:)=[f.rmse_deg f.mae_deg u.rmse_deg u.mae_deg u.bias_deg u.peak_abs_error_deg ...
                        z.raw_motor_command.tv_full z.raw_motor_command.tv_primary ...
                        z.calibrated_model_input.tv_full z.calibrated_model_input.tv_primary];
                end
                if on==0,condition='off';else,condition='on';end
                commonOff=on==0&&numel(settings)>1;
                out(end+1)=struct('protocol',char(p),'a_s2',aSet,'condition',condition,'T_s',tSet, ...
                    'common_off_reused',commonOff,'n_trials',numel(allTrials), ...
                    'n_completed',sum(strcmp({allTrials.status_code},'completed')),'n_summary_eligible',numel(ss), ...
                    'full_rmse_deg',describe(a(:,1)),'full_mae_deg',describe(a(:,2)), ...
                    'primary_rmse_deg',describe(a(:,3)),'primary_mae_deg',describe(a(:,4)), ...
                    'primary_bias_deg',describe(a(:,5)),'primary_peak_abs_error_deg',describe(a(:,6)), ...
                    'raw_q_tv_full',describe(a(:,7)),'raw_q_tv_primary',describe(a(:,8)), ...
                    'model_input_tv_full',describe(a(:,9)),'model_input_tv_primary',describe(a(:,10))); %#ok<AGROW>
            end
        end
    end
end
end
function tf=summaryEligible(r)
tf=false;m=r.metrics.primary_outcome;
if ~strcmp(r.status_code,'completed')||r.write_failure_count>0||~r.window_schedule_match|| ...
        r.valid_sample_count~=r.n_samples||~m.window_complete||m.coverage_fraction<.99,return,end
cfg=r.configuration;protocol=fieldOr(cfg,'protocol',struct());duration=fieldOr(protocol,'duration_s',NaN);Ts=fieldOr(cfg,'Ts',NaN);
if ~isfinite(duration)||~isfinite(Ts)||Ts<=0,return,end
tf=r.n_samples==round(duration/Ts)&&r.write_success_count==r.n_samples;
end
function out=pairedSummary(effects)
out=struct('protocol',{},'a_s2',{},'T_s',{},'metric',{},'unit',{},'comparison',{},'n_pairs',{},'block_ids',{},'mean_difference',{}, ...
    'sd_difference',{},'difference_range',{},'conditional_ci95',{});
for k=1:numel(effects)
    d=effects(k).differences(:);unit='raw u_cmd command units';metric=effects(k).metric;
    if endsWith(metric,'_rad'),d=rad2deg(d);metric=replace(metric,'_rad','_deg');unit='deg';end
    d=d(isfinite(d));z=describe(d);
    out(k)=struct('protocol',effects(k).protocol,'a_s2',effects(k).a,'T_s',effects(k).T, ...
        'metric',metric,'unit',unit, ...
        'comparison',effects(k).comparison,'n_pairs',numel(d),'block_ids',{effects(k).block_ids}, ...
        'mean_difference',z.mean,'sd_difference',z.sd,'difference_range',[z.min z.max], ...
        'conditional_ci95',z.ci95_conditional);
end
end
function d=describe(v)
v=v(isfinite(v));n=numel(v);d=struct('n',n,'mean',NaN,'sd',NaN,'min',NaN,'max',NaN,'range',NaN,'ci95_conditional',[NaN NaN]);
if n==0,return,end;d.mean=mean(v);d.min=min(v);d.max=max(v);d.range=d.max-d.min;
if n>=2,h=tcrit(.975,n-1)*std(v,0)/sqrt(n);d.sd=std(v,0);d.ci95_conditional=[d.mean-h d.mean+h];end
end
function c=statusCounts(p)
c=struct('planned',numel(p),'result_available',sum([p.result_available]),'pending',0,'codes',struct());
if isempty(p),return,end
for s=unique(string({p.status_code})),c.codes.(matlab.lang.makeValidName(char(s)))=sum(string({p.status_code})==s);end
c.pending=sum(ismember(string({p.status_code}),["pending","planned"]));
end
function writeExports(a,folder)
p=a.planned_runs;t=a.trials;
row=repmat(struct('run_id','','protocol','','condition','','block_id','','planned_order',NaN,'a_s2',NaN,'use_compensation',NaN,'T_s',NaN,'status_code','', ...
    'result_available',false,'summary_eligible',false,'full_rmse_deg',NaN,'full_mae_deg',NaN,'full_bias_deg',NaN,'full_peak_abs_error_deg',NaN, ...
    'primary_rmse_deg',NaN,'primary_mae_deg',NaN,'primary_bias_deg',NaN, ...
    'primary_peak_abs_error_deg',NaN,'raw_q_tv_full',NaN,'raw_q_tv_primary',NaN,'model_input_tv_full',NaN, ...
    'model_input_tv_primary',NaN,'software_saturation_count',NaN,'source_sha256',''),numel(p),1);
for k=1:numel(p)
    row(k).run_id=p(k).run_id;row(k).protocol=p(k).protocol;row(k).condition=p(k).condition;row(k).block_id=p(k).block_id;
    row(k).planned_order=p(k).planned_order;row(k).a_s2=p(k).a_s2;
    row(k).use_compensation=p(k).use_compensation;row(k).T_s=p(k).T_s;
    row(k).status_code=p(k).status_code;row(k).result_available=p(k).result_available;row(k).source_sha256=p(k).result_sha256;
    if isempty(t),continue,end
    j=find(strcmp({t.run_id},p(k).run_id),1);if isempty(j),continue,end
    z=t(j).calibrated_analysis;f=z.error_metrics_deg.full;u=z.error_metrics_deg.primary;
    row(k).summary_eligible=z.summary_eligible;
    row(k).full_rmse_deg=f.rmse_deg;row(k).full_mae_deg=f.mae_deg;row(k).full_bias_deg=f.bias_deg;
    row(k).full_peak_abs_error_deg=f.peak_abs_error_deg;row(k).primary_rmse_deg=u.rmse_deg;row(k).primary_mae_deg=u.mae_deg;
    row(k).primary_bias_deg=u.bias_deg;row(k).primary_peak_abs_error_deg=u.peak_abs_error_deg;
    row(k).raw_q_tv_full=z.raw_motor_command.tv_full;row(k).raw_q_tv_primary=z.raw_motor_command.tv_primary;
    row(k).model_input_tv_full=z.calibrated_model_input.tv_full;row(k).model_input_tv_primary=z.calibrated_model_input.tv_primary;
    row(k).software_saturation_count=z.raw_motor_command.software_saturation_count;
end
writetable(struct2table(row),fullfile(folder,'trial_metrics.csv'));
json=rmfield(a,'trials');small=struct([]);
if ~isempty(a.trials),small=rmfield(a.trials,{'signals','metrics','window_metrics'});end
json.trials=small;
fid=fopen(fullfile(folder,'analysis_summary.json'),'w','n','UTF-8');assert(fid>=0);c=onCleanup(@()fclose(fid));
fprintf(fid,'%s',jsonencode(json,PrettyPrint=true));clear c
end
function makeSummaryFigures(tr,folder)
if isempty(tr),return,end
out=fullfile(folder,'figures');if ~isfolder(out),mkdir(out);end
for proto=["reference_tracking","injected_disturbance"]
    protocolMask=string({tr.protocol})==proto;
    gains=unique([tr(protocolMask).a]);gains=gains(isfinite(gains));nGains=numel(gains);
    for aSet=gains
    gainMask=protocolMask&abs([tr.a]-aSet)<1e-12;
    settings=unique([tr(gainMask&[tr.use_compensation]==1).T]);settings=settings(isfinite(settings));
    if isempty(settings),continue,end
    for tSet=settings
    offEligible=eligibleTrials(tr(gainMask&[tr.use_compensation]==0));
    onEligible=eligibleTrials(tr(gainMask&[tr.use_compensation]==1&abs([tr.T]-tSet)<1e-12));
    if isempty(offEligible)&&isempty(onEligible),continue,end
    f=figure('Color','w','Visible','off','Position',[100 100 1000 740]);clean=onCleanup(@()close(f));
    tl=tiledlayout(f,3,1,'TileSpacing','compact','Padding','compact');idx=gainMask;
    colors={[.12 .35 .72],[.8 .22 .12]};labels={sprintf('Off (n=%d)',numel(offEligible)), ...
        sprintf('On T=%.3g s (n=%d)',tSet,numel(onEligible))};
    ax=nexttile(tl);hold(ax,'on');ref=[];refTime=[];
    for c=0:1
        conditionMask=idx&[tr.use_compensation]==c;if c==1,conditionMask=conditionMask&abs([tr.T]-tSet)<1e-12;end
        ix=find(conditionMask);ss=eligibleTrials(tr(ix));[tx,md,lo,hi]=envelope(ss,'angle');
        if isempty(tx),continue,end
        fill(ax,[tx;flipud(tx)],[lo;flipud(hi)],colors{c+1},'FaceAlpha',.14,'EdgeColor','none','HandleVisibility','off');
        plot(ax,tx,md,'Color',colors{c+1},'LineWidth',1.5,'DisplayName',labels{c+1});
        if isempty(ref),ref=rad2deg(ss(1).signals.reference(:));refTime=ss(1).signals.t(:);else,assert(isequal(ref,rad2deg(ss(1).signals.reference(:))));end
    end
    if ~isempty(ref),plot(ax,refTime,ref,'k--','LineWidth',1,'DisplayName','$v$');end
    ylabel(ax,'$y,\ v$ [deg]','Interpreter','latex');grid(ax,'on');legend(ax,'Location','best','Interpreter','latex');
    title(ax,'(a) Angle response');
    ax=nexttile(tl);hold(ax,'on');
    for c=0:1
        conditionMask=idx&[tr.use_compensation]==c;if c==1,conditionMask=conditionMask&abs([tr.T]-tSet)<1e-12;end
        ix=find(conditionMask);ss=eligibleTrials(tr(ix));[tx,md,lo,hi]=envelope(ss,'q');
        if isempty(tx),continue,end
        fill(ax,[tx;flipud(tx)],[lo;flipud(hi)],colors{c+1},'FaceAlpha',.14,'EdgeColor','none','HandleVisibility','off');
        plot(ax,tx,md,'Color',colors{c+1},'LineWidth',1.4,'DisplayName',labels{c+1});
    end
    ylabel(ax,'$u_{\mathrm{cmd}}$ [command units]','Interpreter','latex');grid(ax,'on');
    legend(ax,'Location','best','Interpreter','latex');
    title(ax,'(b) Transmitted motor command');
    ax=nexttile(tl);hold(ax,'on');
    if proto=="reference_tracking"
        for c=0:1
            conditionMask=idx&[tr.use_compensation]==c;if c==1,conditionMask=conditionMask&abs([tr.T]-tSet)<1e-12;end
            ix=find(conditionMask);ss=eligibleTrials(tr(ix));[tx,md,lo,hi]=envelope(ss,'error');
            if isempty(tx),continue,end
            fill(ax,[tx;flipud(tx)],[lo;flipud(hi)],colors{c+1},'FaceAlpha',.14,'EdgeColor','none','HandleVisibility','off');
            plot(ax,tx,md,'Color',colors{c+1},'LineWidth',1.4,'DisplayName',labels{c+1});
        end
        xlimNow=xlim(ax);plot(ax,xlimNow,[0 0],'k--','HandleVisibility','off');ylabel(ax,'$e=v-y$ [deg]','Interpreter','latex');
        legend(ax,'Location','best','Interpreter','latex');
        title(ax,'(c) Tracking error');
    else
        % Both conditions receive injection; this diagnostic shows On estimates.
        % Total equivalent disturbance remains unobserved.
        conditionMask=idx&[tr.use_compensation]==1&abs([tr.T]-tSet)<1e-12;
        ss=eligibleTrials(tr(conditionMask));[tx,md,lo,hi]=envelope(ss,'w_hat');
        if ~isempty(tx)
            fill(ax,[tx;flipud(tx)],[lo;flipud(hi)],[.8 .22 .12],'FaceAlpha',.14,'EdgeColor','none','HandleVisibility','off');
            plot(ax,tx,md,'Color',[.8 .22 .12],'LineWidth',1.4,'DisplayName','$\hat w$');
        end
        [tx,md,lo,hi]=envelope(ss,'w_injected_filtered');
        if ~isempty(tx)
            fill(ax,[tx;flipud(tx)],[lo;flipud(hi)],[.2 .2 .2],'FaceAlpha',.08,'EdgeColor','none','HandleVisibility','off');
            plot(ax,tx,md,'k-.','LineWidth',1.3,'DisplayName','$Qw_{\mathrm{inj,eff}}$');
        end
        ylabel(ax,'Normalized model-input units');title(ax,'(c) Known injection diagnostic; total disturbance unobserved');
        legend(ax,'Location','best','Interpreter','latex');
    end
    xlabel(ax,'Time (s)');
    protocolLabel='Reference tracking';if proto=="injected_disturbance",protocolLabel='Disturbance rejection';end
    title(tl,sprintf('%s: $a=%.3g\\,\\mathrm{s}^{-2}$, $T=%.3g\\,\\mathrm{s}$', ...
        protocolLabel,aSet,tSet),'Interpreter','latex');
    if numel(refTime)>1
        axesList=findall(f,'Type','axes');endTime=refTime(end)+median(diff(refTime));
        for ai=1:numel(axesList),xlim(axesList(ai),[refTime(1) endTime]);end
    end
    if nGains==1&&numel(settings)==1
        base=char(proto);
    elseif numel(settings)==1
        base=sprintf('%s_a_%s',char(proto),strrep(num2str(aSet,'%.3g'),'.','p'));
    else
        base=sprintf('%s_a_%s_T_%s',char(proto),strrep(num2str(aSet,'%.3g'),'.','p'),strrep(num2str(tSet,'%.3g'),'.','p'));
    end
    exportF(f,fullfile(out,base));clear clean
    end
    end
end
end
function ss=eligibleTrials(tr)
if isempty(tr),ss=tr;return,end
keep=arrayfun(@summaryEligible,tr);ss=tr(keep);
end
function [t,med,lo,hi]=envelope(tr,field)
t=[];med=[];lo=[];hi=[];if isempty(tr),return,end
s0=tr(1).signals;t=double(s0.t(:));ref=double(s0.reference(:));v0=signal(s0,field);
assert(all(isfinite(t))&&all(isfinite(ref))&&numel(v0)==numel(t)&&all(isfinite(v0)), ...
    'pendulumlab:SummaryGrid','Summary signals must be finite on the full frozen grid.');
a=nan(numel(t),numel(tr));a(:,1)=v0;
for k=2:numel(tr)
    s=tr(k).signals;tk=double(s.t(:));rk=double(s.reference(:));v=signal(s,field);
    assert(isequal(tk,t)&&isequal(rk,ref)&&numel(v)==numel(t)&&all(isfinite(v)), ...
        'pendulumlab:SummaryGrid','Summary requires identical time/reference grids and finite full records.');
    a(:,k)=v;
end
med=median(a,2);lo=min(a,[],2);hi=max(a,[],2);
end
function v=signal(s,n)
switch n
    case 'angle',v=rad2deg(s.angle);
    case 'error',v=rad2deg(s.reference-s.angle);
    case 'q',v=s.u_command;
    otherwise,v=fieldOr(s,n,nan(size(s.t)));
end
v=v(:);
end
function makeIndividualFigures(tr,folder)
if isempty(tr),return,end
out=fullfile(folder,'individual');if ~isfolder(out),mkdir(out);end
for k=1:numel(tr)
    s=tr(k).signals;f=figure('Color','w','Visible','off','Position',[100 100 900 700]);clean=onCleanup(@()close(f));
    tl=tiledlayout(f,3,1,'TileSpacing','compact','Padding','compact');
    ax=nexttile(tl);plot(ax,s.t,rad2deg(s.angle),'b-',s.t,rad2deg(s.reference),'k--');grid(ax,'on');ylabel(ax,'$y,\ v$ [deg]','Interpreter','latex');
    legend(ax,{'$y$','$v$'},'Location','best','Interpreter','latex');
    ax=nexttile(tl);plot(ax,s.t,s.u_command);grid(ax,'on');ylabel(ax,'$u_{\mathrm{cmd}}$ [command units]','Interpreter','latex');
    ax=nexttile(tl);plot(ax,s.t,fieldOr(s,'w_hat',nan(size(s.t))));hold(ax,'on');
    plot(ax,s.t,fieldOr(s,'w_injected_filtered',nan(size(s.t))),'k-.');grid(ax,'on');ylabel(ax,'Normalized model-input units');xlabel(ax,'Time (s)');
    legend(ax,{'$\hat w$','$Qw_{\mathrm{inj,eff}}$'},'Location','best','Interpreter','latex');
    title(tl,sprintf('%s | %s | %s',tr(k).trial_id,tr(k).protocol,tr(k).status_code),'Interpreter','none');
    exportF(f,fullfile(out,sprintf('%03d_%s',k,tr(k).trial_id)));clear clean
end
end
function exportF(f,base)
base=char(base);
savefig(f,[base '.fig']);
try,exportgraphics(f,[base '.pdf'],'ContentType','vector');catch,print(f,[base '.pdf'],'-dpdf','-painters');end
assert(isfile([base '.pdf']),'pendulumlab:FigureExport','PDF export failed: %s',base);
[~,baseName]=fileparts(base);
if any(strcmp(baseName,{'reference_tracking','injected_disturbance'}))
    exportgraphics(f,fullfile(tempdir,['pendulum_' baseName '_preview.png']),'Resolution',140);
end
patches=findall(f,'Type','patch');oldColors=cell(numel(patches),1);oldAlpha=cell(numel(patches),1);
for k=1:numel(patches)
    oldColors{k}=get(patches(k),'FaceColor');oldAlpha{k}=get(patches(k),'FaceAlpha');
    color=oldColors{k};alpha=oldAlpha{k};
    if isnumeric(color)&&numel(color)==3&&isnumeric(alpha)&&isscalar(alpha)&&isfinite(alpha)
        set(patches(k),'FaceColor',alpha*reshape(color,1,3)+(1-alpha)*[1 1 1],'FaceAlpha',1);
    end
end
restore=onCleanup(@()restorePatches(patches,oldColors,oldAlpha));
axesList=findall(f,'Type','axes');
for axisIndex=1:numel(axesList)
    lines=findall(axesList(axisIndex),'Type','line');
    if ~isempty(lines),uistack(lines,'top');end
end
print(f,[base '.eps'],'-depsc','-painters');
assert(isfile([base '.eps']),'pendulumlab:FigureExport','EPS export failed: %s',base);
clear restore
end
function restorePatches(patches,colors,alpha)
for k=1:numel(patches)
    if isgraphics(patches(k)),set(patches(k),'FaceColor',colors{k},'FaceAlpha',alpha{k});end
end
end
function st=findStatus(doc,id)
st=struct();if ~isfield(doc,'runs')||isempty(doc.runs),return,end
ix=find(string({doc.runs.run_id})==id,1);if ~isempty(ix),st=doc.runs(ix);end
end
function x=fitLength(v,n)
x=nan(n,1);v=v(:);x(1:min(n,numel(v)))=v(1:min(n,numel(v)));
end
function x=fitLogical(v,n)
x=false(n,1);v=logical(v(:));x(1:min(n,numel(v)))=v(1:min(n,numel(v)));
end
function h=hashIfFile(f)
if isfile(f),h=pendulumlab.file_hash(f);else,h='';end
end
function v=fieldOr(s,n,d)
if isstruct(s)&&isfield(s,n),v=s.(n);else,v=d;end
end
function q=tcrit(p,df)
if exist('tinv','file')==2
    q=tinv(p,df);
else
    x=betaincinv(2*min(p,1-p),df/2,0.5);
    q=sign(p-.5)*sqrt(df*(1-x)/x);
end
end
function [target,why]=canonicalOutputPath(path,campaignFolder)
target=char(java.io.File(char(path)).getCanonicalPath());why='';
root=char(java.io.File(char(campaignFolder)).getCanonicalPath());derived=fullfile(root,'derived');
if within(target,root)&&~within(target,derived)
    why='Output inside campaign folder must be under its derived subfolder.';
end
end
function tf=within(child,parent)
child=char(java.io.File(char(child)).getCanonicalPath());parent=char(java.io.File(char(parent)).getCanonicalPath());
tf=strcmpi(child,parent)||startsWith(lower([child filesep]),lower([parent filesep]));
end
