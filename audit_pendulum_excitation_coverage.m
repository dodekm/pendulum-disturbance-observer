function outputPath = audit_pendulum_excitation_coverage(controlManifestPaths,outputDir)
%AUDIT_PENDULUM_EXCITATION_COVERAGE Descriptive empirical coverage audit only.
% Do not run during acquisition. Does not modify model, raw data, or outcomes.
if nargin<1||isempty(controlManifestPaths),error('Supply completed-control campaign manifest paths.');end
if nargin<2,outputDir="";end
root=fileparts(mfilename('fullpath'));addpath(fullfile(root,'experiment_framework'));
controlManifestPaths=string(controlManifestPaths(:));

% Fixed analysis settings and coarse occupancy bins; do not tune after seeing coverage.
cfg=struct();cfg.nominal_Ts_s=.05;cfg.training_prefix_s=5;cfg.training_return_tail_s=20;
cfg.derivative_primary='3-point central difference';cfg.derivative_sensitivity='5-point fourth-order central difference';
cfg.command_rate='Backward one-step difference of known float32 raw u_command using nominal Ts; not actuator rate';
cfg.angle_edges_deg=[-Inf -45 -20 0 20 40 60 85 Inf];
cfg.velocity_edges_deg_s=[-Inf -180 -120 -60 -20 0 20 60 120 180 Inf];
cfg.raw_command_edges=[-Inf 0 10 20 30 40 50 62 Inf];
cfg.raw_command_rate_edges_s=[-Inf -80 -40 -20 -10 0 10 20 40 80 Inf];
cfg.bin_edge_text=struct('angle_deg',{{'-Inf','-45','-20','0','20','40','60','85','Inf'}}, ...
 'velocity_proxy_deg_s',{{'-Inf','-180','-120','-60','-20','0','20','60','120','180','Inf'}}, ...
 'raw_command',{{'-Inf','0','10','20','30','40','50','62','Inf'}}, ...
 'raw_command_rate_per_s',{{'-Inf','-80','-40','-20','-10','0','10','20','40','80','Inf'}});
cfg.frequency_window='Mean-removed raw u_command, symmetric Hann window, MATLAB fft, nominal grid; input spectrum only.';
cfg.controller_frequency_descriptors=struct('a_s2',[20 25], ...
    'sqrt_a_over_2pi_hz',sqrt([20 25])/(2*pi), ...
    'interpretation','Nominal second-order frequency descriptors only; not measured excitation frequencies.');

campaignRoot=fullfile(root,'experiment_data','campaign_v2','campaigns');
ledgers=dir(fullfile(campaignRoot,'*','campaign_status.json'));
for j=1:numel(ledgers)
    q=jsondecode(fileread(fullfile(ledgers(j).folder,ledgers(j).name)));
    if any(strcmp({q.runs.code},'running')),error('An active campaign exists; defer the audit until all acquisitions stop.');end
end
registryPath=fullfile(root,'experiment_framework','model_registry','calibrated_rig_20261106_173755.json');
reg=jsondecode(fileread(registryPath));tr=reg.training;
assert(strcmp(reg.model_id,'calibrated_rig_20261106_173755')&&numel(tr.source_files)==13&& ...
    numel(tr.raw_hashes)==13&&numel(tr.parameter_fit_mask)==13&&sum(logical(tr.parameter_fit_mask))==9, ...
    'Unexpected frozen training manifest or fit mask.');

trainRows=cell(0,1);trainCells3=zeros(0,4);trainCells5=zeros(0,4);
trainPlotA=[];trainPlotV=[];excludedTraining=cell(0,1);rawProvenance=cell(0,1);
srcFiles=string(tr.source_files(:));srcHashes=string(tr.raw_hashes(:));srcIds=string(tr.run_ids(:));fitMask=logical(tr.parameter_fit_mask(:));
for k=1:13
    recordedPath=char(srcFiles(k));path=localRecordedPath(recordedPath,root);
    assert(isfile(path),'Missing hash-bound training source: %s',path);
    h=pendulumlab.file_hash(path);assert(strcmpi(h,char(srcHashes(k))),'Training source hash mismatch: %s',path);
    r=pendulumlab.load_runs(string(path));verifyPhysical(r,reg.hardware_id);timing=timingCheck(r,cfg.nominal_Ts_s);
    role=struct('run_id',char(srcIds(k)),'source_file',path,'recorded_source_file',recordedPath,'raw_sha256',h, ...
        'parameter_fit_mask',fitMask(k),'status_code',r.status.code,'timing_valid',timing.valid,'timing_reason',timing.reason, ...
        'frequency_diagnostic',frequencyDiagnostic(r,cfg.nominal_Ts_s));
    rawProvenance{end+1,1}=role; %#ok<AGROW>
    if ~fitMask(k),excludedTraining{end+1,1}=role;continue,end %#ok<AGROW>
    assert(timing.valid,'Selected fit record has invalid timing: %s',path);
    t=double(r.signals.t(:));y=double(r.signals.angle(:));u=double(r.signals.u_command(:));
    last=find(u>0,1,'last');assert(~isempty(last),'Fit record has no positive raw command.');
    ix=t>=cfg.training_prefix_s&t<=min(t(end),t(last)+cfg.training_return_tail_s);
    f=features(t,y,u,ix,cfg);f.summary.role='parameter_fit_training';f.summary.run_id=char(srcIds(k));
    f.summary.raw_sha256=h;f.summary.fit_window=[cfg.training_prefix_s min(t(end),t(last)+cfg.training_return_tail_s)];
    f.summary.frequency_diagnostic=role.frequency_diagnostic;
    trainRows{end+1,1}=f.summary;trainCells3=[trainCells3;f.powered_bins3];trainCells5=[trainCells5;f.powered_bins5]; %#ok<AGROW>
    trainPlotA=[trainPlotA;f.angle3];trainPlotV=[trainPlotV;f.velocity3]; %#ok<AGROW>
end
trainCells3=unique(trainCells3,'rows');trainCells5=unique(trainCells5,'rows');

controlOutcomes=cell(0,1);controlPlotA=[];controlPlotV=[];manifestProvenance=cell(0,1);seen=string.empty;
for mi=1:numel(controlManifestPaths)
    mp=char(controlManifestPaths(mi));assert(isfile(mp),'Missing control manifest: %s',mp);
    md=jsondecode(fileread(mp));campaignDir=fileparts(mp);sp=fullfile(campaignDir,'campaign_status.json');assert(isfile(sp));
    st=jsondecode(fileread(sp));assert(strcmp(md.campaign_id,st.campaign_id)&&numel(md.runs)==numel(st.runs));
    manifestProvenance{end+1,1}=struct('path',mp,'sha256',pendulumlab.file_hash(mp), ...
        'status_path',sp,'status_sha256',pendulumlab.file_hash(sp),'campaign_id',md.campaign_id); %#ok<AGROW>
    for j=1:numel(md.runs)
        mr=md.runs(j);si=find(strcmp({st.runs.run_id},mr.run_id));assert(numel(si)==1);
        sr=st.runs(si);rid=string(mr.run_id);assert(~any(seen==rid),'Duplicate run across supplied manifests: %s',rid);seen(end+1)=rid; %#ok<AGROW>
        rawPath=fullfile(campaignDir,'runs',[char(rid) '.mat']);
        o=struct('campaign_id',md.campaign_id,'manifest_path',mp,'run_id',char(rid), ...
            'block_id',getText(mr,'block_id'),'protocol',getText(mr,'protocol'), ...
            'condition',getText(mr,'condition'),'planned_model_id',getText(mr,'model_id'),'actual_model_id','', ...
            'ledger_status',sr.code,'ledger_reason',sr.reason,'result_file',rawPath, ...
            'raw_available',false,'raw_sha256','','raw_status','','recording_kind','','hardware_id','', ...
            'timing_valid',false,'timing_class','not_assessable','raw_load_error','', ...
            'timing_reason','raw record unavailable','eligible_for_coverage',false, ...
            'coverage',struct(),'frequency_diagnostic',struct('status','unavailable','reason','raw record unavailable'));
        if isfile(rawPath)
            try
                r=pendulumlab.load_runs(string(rawPath));o.raw_available=true;
                actualHash=pendulumlab.file_hash(rawPath);assert(strcmpi(actualHash,r.provenance.source_sha256));
                assert(strcmp(getText(r.metadata,'run_id'),char(rid)));
                if isfield(mr,'config_sha256'),assert(strcmp(r.metadata.config_sha256,mr.config_sha256));end
                if isfield(mr,'schedule_identity_sha256'),assert(strcmp(r.metadata.schedule_identity_sha256,mr.schedule_identity_sha256));end
                o.raw_sha256=actualHash;o.raw_status=r.status.code;
                o.recording_kind=r.recording_kind;o.hardware_id=getText(r.metadata,'hardware_id');o.actual_model_id=getText(r.metadata,'model_id');
                timing=timingCheck(r,cfg.nominal_Ts_s);o.timing_valid=timing.valid;o.timing_reason=timing.reason;
                if timing.valid,o.timing_class='timing_valid';else,o.timing_class='timing_failed';end
                isComplete=strcmp(sr.code,'completed')&&strcmp(r.status.code,'completed');
                isPhysical=strcmp(r.recording_kind,'physical')&&strcmp(o.hardware_id,reg.hardware_id);
                o.eligible_for_coverage=isComplete&&isPhysical&&timing.valid;
                if o.eligible_for_coverage
                    verifyPhysical(r,reg.hardware_id);
                    t=double(r.signals.t(:));y=double(r.signals.angle(:));u=double(r.signals.u_command(:));
                    f=features(t,y,u,true(size(t)),cfg);
                    f.summary.run_id=char(rid);f.summary.protocol=o.protocol;f.summary.condition=o.condition;
                    c3=f.powered_bins3;c5=f.powered_bins5;
                    overlap3=cellOverlap(c3,trainCells3);overlap5=cellOverlap(c5,trainCells5);
                    f.summary.joint_powered_cell_overlap_3point=overlap3;
                    f.summary.joint_powered_cell_overlap_5point=overlap5;
                    o.coverage=f.summary;controlPlotA=[controlPlotA;f.angle3];controlPlotV=[controlPlotV;f.velocity3]; %#ok<AGROW>
                    o.frequency_diagnostic=frequencyDiagnostic(r,cfg.nominal_Ts_s);
                else
                    o.frequency_diagnostic=struct('status','unavailable','reason','record not eligible for full-trajectory analysis');
                end
            catch err
                o.raw_available=true;o.eligible_for_coverage=false;
                o.raw_load_error=err.message;
                o.timing_reason=['load_or_analysis_error: ' err.message];
            end
        end
        controlOutcomes{end+1,1}=o; %#ok<AGROW>
    end
end
assert(~isempty(controlManifestPaths),'No control manifests supplied.');
if strlength(string(outputDir))==0
    outputDir=fullfile(fileparts(char(controlManifestPaths(1))),'derived', ...
        ['excitation_coverage_' char(datetime('now','Format','yyyyMMdd_HHmmss'))]);
end
outputDir=char(outputDir);assertOutputAllowed(outputDir,controlManifestPaths);
assert(~isfolder(outputDir),'Refusing to overwrite existing output directory.');
[ok,msg]=mkdir(outputDir);assert(ok,'Cannot create output directory: %s',msg);
statusCodes=cellfun(@(x)x.ledger_status,controlOutcomes,'UniformOutput',false);
timingClasses=cellfun(@(x)x.timing_class,controlOutcomes,'UniformOutput',false);
uCodes=unique(statusCodes);statusCounts=struct();
for j=1:numel(uCodes),key=matlab.lang.makeValidName(uCodes{j});statusCounts.(key)=sum(strcmp(statusCodes,uCodes{j}));end
timingSummary=struct('timing_valid',sum(strcmp(timingClasses,'timing_valid')), ...
 'timing_failed',sum(strcmp(timingClasses,'timing_failed')),'not_assessable',sum(strcmp(timingClasses,'not_assessable')));
report=struct('schema_version','pendulumlab.empirical_excitation_coverage/1', ...
    'status','descriptive_coverage_audit_not_model_validation', ...
    'scope','Empirical occupancy and input-spectrum diagnostics only; timing-invalid records remain listed but are excluded from derivatives and full-trajectory endpoints. Not certification, safety bounds, identifiability proof, or controller-frequency response.', ...
    'output_dir',outputDir,'settings',cfg,'model_id',reg.model_id,'hardware_id',reg.hardware_id, ...
    'registry_path',registryPath,'registry_sha256',pendulumlab.file_hash(registryPath), ...
    'training_sources',{rawProvenance},'fit_training_records',{trainRows}, ...
    'excluded_from_fit_coverage',{excludedTraining},'control_manifests',{manifestProvenance}, ...
    'control_outcomes',{controlOutcomes},'control_ledger_status_counts',statusCounts, ...
    'control_timing_class_counts',timingSummary, ...
    'joint_bin_definitions',struct('angle_deg',cfg.angle_edges_deg,'velocity_proxy_deg_s',cfg.velocity_edges_deg_s, ...
      'raw_command',cfg.raw_command_edges,'nominal_command_rate_per_s',cfg.raw_command_rate_edges_s), ...
    'training_powered_joint_cells_3point',size(trainCells3,1), ...
    'training_powered_joint_cells_5point',size(trainCells5,1), ...
    'interpretation','Overlap fractions depend on the stated coarse bins and empirical records; they are not validated domains or guarantees. Velocity is a differentiated angle proxy, not a measured state.');
report.created_utc=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z'''));
sourcePath=[mfilename('fullpath') '.m'];report.analysis_source=sourcePath;report.analysis_source_sha256=pendulumlab.file_hash(sourcePath);
save(fullfile(outputDir,'coverage_audit.mat'),'report','trainCells3','trainCells5','-v7');
fid=fopen(fullfile(outputDir,'coverage_audit.json'),'wt');assert(fid>=0);cl=onCleanup(@()fclose(fid));
fwrite(fid,jsonencode(report,PrettyPrint=true),'char');clear cl

% One supporting descriptive scatter; deterministic thinning limits file size.
fig=figure('Visible','off','Color','w');hold on;grid on;
[ta,tv]=thin(trainPlotA,trainPlotV,12000);[ca,cv]=thin(controlPlotA,controlPlotV,18000);
scatter(ta,tv,5,[.35 .35 .35],'filled');scatter(ca,cv,5,[.1 .4 .8],'filled');
xlabel('Angle [deg]');ylabel('3-point central-difference velocity proxy [deg/s]');
legend('Nine parameter-fit records','Eligible control records','Location','best');
title('Observed angle–velocity occupancy (descriptive; coarse-bin overlap in report)');
savefig(fig,fullfile(outputDir,'angle_velocity_coverage.fig'));
exportgraphics(fig,fullfile(outputDir,'angle_velocity_coverage.pdf'),'ContentType','vector');
print(fig,fullfile(outputDir,'angle_velocity_coverage.eps'),'-depsc','-painters');close(fig);
outputPath=outputDir;
end

function verifyPhysical(r,hardware)
assert(strcmp(r.recording_kind,'physical')&&strcmp(r.status.code,'completed'));
assert(strcmp(getText(r.metadata,'hardware_id'),hardware));
assert(numel(r.signals.t)==numel(r.signals.angle)&&numel(r.signals.t)==numel(r.signals.u_command), ...
 'Time, angle, and command vectors must be aligned.');
expectedSamples=round(double(r.metadata.config.protocol.duration_s)/double(r.metadata.config.Ts));
assert(numel(r.signals.t)==expectedSamples, ...
 'Record does not contain the planned full sample count.');
assert(isfield(r.metadata,'planned_sample_count')&&double(r.metadata.planned_sample_count)==expectedSamples, ...
 'Recorded planned sample count differs from the frozen protocol.');
assert(all(isfinite([r.signals.t(:);r.signals.angle(:);r.signals.u_command(:)])));
assert(isfield(r.signals,'read_valid')&&numel(r.signals.read_valid)==numel(r.signals.t)&&all(r.signals.read_valid(:))&& ...
    isfield(r.signals,'write_succeeded')&&numel(r.signals.write_succeeded)==numel(r.signals.t)&&all(r.signals.write_succeeded(:)));
end
function q=timingCheck(r,Ts)
s=r.signals;q=struct('valid',false,'reason','','max_device_gap_s',NaN);
if ~isfield(s,'t_device')||numel(s.t_device)~=numel(s.t)||any(~isfinite(s.t_device(:)))
    q.reason='missing_or_invalid_device_time';return
end
if ~isfield(s,'read_valid')||~all(s.read_valid(:))||~isfield(s,'write_succeeded')||~all(s.write_succeeded(:))
    q.reason='read_or_write_flag_failed';return
end
t=double(s.t(:));td=double(s.t_device(:));g=diff(td);q.max_device_gap_s=max(g);
if any(g<=0),q.reason='device_time_not_strictly_increasing';return,end
c=r.metadata.config;maxGap=min(double(c.safety.max_device_gap_s),1.5*Ts);
if abs(double(c.Ts)-Ts)>1e-9||max(g)>maxGap+10*eps(Ts)||max(abs(diff(t)-Ts))>1e-7
    q.reason='nominal_or_device_timing_outside_frozen_gate';return
end
q.valid=true;q.reason='all_samples_flags_and_frozen_timing_gate_pass';
end
function f=features(t,y,u,base,cfg)
t=double(t(:));y=double(y(:));u=double(u(:));n=numel(t);Ts=cfg.nominal_Ts_s;
v3=nan(n,1);v5=v3;rate=v3;v3(2:n-1)=(y(3:n)-y(1:n-2))/(2*Ts);
v5(3:n-2)=(y(1:n-4)-8*y(2:n-3)+8*y(4:n-1)-y(5:n))/(12*Ts);
rate(2:n)=(u(2:n)-u(1:n-1))/Ts;
m3=logical(base(:))&isfinite(t)&isfinite(y)&isfinite(u)&isfinite(v3)&isfinite(rate);
m5=logical(base(:))&isfinite(t)&isfinite(y)&isfinite(u)&isfinite(v5)&isfinite(rate);
a=rad2deg(y);w3=rad2deg(v3);w5=rad2deg(v5);ix3=find(m3);ix5=find(m5);
b3=jointBins(a,w3,u,rate,m3,cfg);b5=jointBins(a,w5,u,rate,m5,cfg);
s=struct('sample_count_3point',sum(m3),'sample_count_5point',sum(m5), ...
 'angle_range_deg',rangeOf(a(m3)),'velocity_proxy_3point_deg_s',rangeOf(w3(m3)), ...
 'velocity_proxy_5point_deg_s',rangeOf(w5(m5)),'raw_command_range',rangeOf(u(m3)), ...
 'nominal_command_rate_range_per_s',rangeOf(rate(m3)), ...
 'powered_angle_bins_3point',angleBins(a,u,m3,cfg),'powered_angle_bins_5point',angleBins(a,u,m5,cfg));
f=struct('summary',s,'powered_bins3',b3(u(ix3)>0,:),'powered_bins5',b5(u(ix5)>0,:), ...
 'angle3',a(m3),'velocity3',w3(m3));
end
function b=jointBins(a,v,u,r,mask,c)
i=find(mask);b=[discretize(a(i),c.angle_edges_deg),discretize(v(i),c.velocity_edges_deg_s), ...
 discretize(u(i),c.raw_command_edges),discretize(r(i),c.raw_command_rate_edges_s)];
assert(all(isfinite(b(:))),'Finite samples must map to all declared coarse bins.');
end
function rows=angleBins(a,u,mask,c)
e=c.angle_edges_deg;id=discretize(a,e);rows=repmat(struct('lower_deg',NaN,'upper_deg',NaN,'powered_samples',0, ...
 'powered_duration_s',0,'observed_min_deg',NaN,'observed_max_deg',NaN),numel(e)-1,1);
for k=1:numel(e)-1,ix=mask(:)&u(:)>0&id==k;z=a(ix);rows(k)=struct('lower_deg',e(k),'upper_deg',e(k+1), ...
 'powered_samples',sum(ix),'powered_duration_s',sum(ix)*c.nominal_Ts_s, ...
 'observed_min_deg',minOrNaN(z),'observed_max_deg',maxOrNaN(z));end
end
function r=rangeOf(x),r=struct('n',numel(x),'min',minOrNaN(x),'max',maxOrNaN(x));end
function x=minOrNaN(x),if isempty(x),x=NaN;else,x=min(x);end,end
function x=maxOrNaN(x),if isempty(x),x=NaN;else,x=max(x);end,end
function o=cellOverlap(b,training)
if isempty(b),o=struct('powered_samples',0,'in_training_cells',0,'fraction_in_training_cells',NaN);return,end
hit=ismember(b,training,'rows');o=struct('powered_samples',size(b,1),'in_training_cells',sum(hit), ...
 'fraction_in_training_cells',mean(hit));
end
function d=frequencyDiagnostic(r,Ts)
d=struct('status','unavailable','reason','no declared multisine active-window metadata');
p=r.metadata.config.protocol;if ~isfield(p,'multisine_design'),return,end
x=p.multisine_design;if ~all(isfield(x,{'active_interval_s','full_amplitude_interval_s','frequencies_hz'})), ...
 d.reason='multisine metadata lacks frozen windows or tone list';return,end
s=r.signals;t=double(s.t(:));u=double(s.u_command(:));d.status='available_input_spectrum_only';
d.reason='Frozen multisine metadata available; spectrum uses the actual transmitted command, including any supervised zero return.';
d.declared_tones_hz=double(x.frequencies_hz(:).');d.active=windowSpectrum(t,u,x.active_interval_s,Ts,d.declared_tones_hz);
d.full_amplitude=windowSpectrum(t,u,x.full_amplitude_interval_s,Ts,d.declared_tones_hz);
d.interpretation='Actual raw-command spectrum only; no u/y FRF, causality, or plant-response inference.';
end
function z=windowSpectrum(t,u,w,Ts,tones)
ix=t>=w(1)&t<w(2);x=u(ix);n=numel(x);z=struct('declared_window_s',w,'recorded_samples',n, ...
 'recorded_window_duration_s',n*Ts,'positive_command_duration_s',sum(x>0)*Ts, ...
 'raw_command_range',rangeOf(x),'nearest_bin_hz',[],'nearest_bin_amplitude_raw_units',[], ...
 'amplitude_qualification','Hann-windowed nearest FFT-bin magnitude; leakage means it is not a fitted tone amplitude.');
if n<4,z.status='insufficient_samples';return,end
x=x-mean(x);h=.5-.5*cos(2*pi*(0:n-1)'/(n-1));Y=fft(x.*h);m=floor(n/2)+1;
f=(0:m-1)'/(n*Ts);A=2*abs(Y(1:m))/sum(h);A(1)=abs(Y(1))/sum(h);
if rem(n,2)==0,A(end)=A(end)/2;end
[~,k]=min(abs(f-tones(:).'),[],1);z.nearest_bin_hz=f(k).';z.nearest_bin_amplitude_raw_units=A(k).';z.status='hann_dft_raw_command_only';
end
function [a,b]=thin(x,y,maxN)
step=max(1,ceil(numel(x)/maxN));a=x(1:step:end);b=y(1:step:end);
end
function assertOutputAllowed(path,manifests)
target=char(java.io.File(path).getCanonicalPath());
for k=1:numel(manifests)
    d=char(java.io.File(fullfile(fileparts(char(manifests(k))),'derived')).getCanonicalPath());
    if strcmpi(target,d)||startsWith(lower([target filesep]),lower([d filesep])),return,end
end
[allowed,why]=pendulumlab.output_location_allowed(target,'offline');
assert(allowed,'Output location is outside supplied campaign derived folders and offline policy denied it: %s',why);
end
function s=getText(x,name)
if isstruct(x)&&isfield(x,name),v=x.(name);if isstring(v),s=char(v);elseif ischar(v),s=v;else,s='';end;else,s='';end
end
function path=localRecordedPath(recorded,root)
% Resolve the archived project-relative suffix without reading another copy.
normalized=regexprep(strrep(recorded,'\','/'),'/+','/');marker='/experiment_data/campaign_v2/';
k=strfind(normalized,marker);
assert(numel(k)==1,'Archived training path lacks a unique campaign_v2 suffix.');
relative=normalized(k+1:end);
path=char(java.io.File(fullfile(root,strrep(relative,'/',filesep))).getCanonicalPath());
dataRoot=char(java.io.File(fullfile(root,'experiment_data','campaign_v2')).getCanonicalPath());
assert(startsWith(lower([path filesep]),lower([dataRoot filesep])), ...
 'Archived training path escapes the local campaign_v2 directory.');
end
