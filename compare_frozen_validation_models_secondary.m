function outDir = compare_frozen_validation_models_secondary(outputDir)
%COMPARE_FROZEN_VALIDATION_MODELS_SECONDARY
% Secondary, parameter-frozen comparison on the three calibrated holdouts.
% This script does not change or replace any validation report, criterion,
% candidate/model record, or raw file. It must not run during acquisition.
if nargin<1,outputDir="";end
assert(isstring(string(outputDir))&&isscalar(string(outputDir)),'Supply one output directory.');
root=fileparts(mfilename('fullpath'));
addpath(fullfile(root,'experiment_framework'),fullfile(root,'experiment_framework','analyses'));
% Refuse analysis while any campaign ledger reports an active run.
statusFiles=dir(fullfile(root,'experiment_data','campaign_v2','campaigns','*','campaign_status.json'));
for si=1:numel(statusFiles)
    sx=jsondecode(fileread(fullfile(statusFiles(si).folder,statusFiles(si).name)));
    if any(strcmp({sx.runs.code},'running')),error('An experiment campaign is active; defer this offline analysis.');end
end

campaignId='cmp_6cda18fc96744ebb80e024b0f9bb5c62';
campaignDir=fullfile(root,'experiment_data','campaign_v2','campaigns',campaignId);
fitMat=fullfile(root,'experiment_data','campaign_v2','identification_results', ...
    'identification_20261106_163437','identification.mat');
fitJson=fullfile(fileparts(fitMat),'identification.json');
registryPath=fullfile(root,'experiment_framework','model_registry', ...
    'calibrated_rig_20261106_173755.json');
assessmentDir=fullfile(campaignDir,'derived','assessment_20261106_181317');
assessmentMat=fullfile(assessmentDir,'validation_assessment.mat');
assessmentJson=fullfile(assessmentDir,'validation_assessment.json');
assert(isfile(fitMat)&&isfile(fitJson)&&isfile(registryPath)&&isfile(assessmentMat)&&isfile(assessmentJson), ...
    'Required frozen fit, registry, or original assessment file is missing.');

fitHash=pendulumlab.file_hash(fitMat);
fitRecord=jsondecode(fileread(fitJson));
registry=jsondecode(fileread(registryPath));
assert(strcmp(fitRecord.status,'exploratory_identification_not_validated_not_promoted'));
assert(strcmpi(fitHash,registry.fit.source_report_sha256), ...
    'Immutable fit report hash differs from the model record source binding.');
loaded=load(fitMat,'report');reportFit=loaded.report;
assert(numel(reportFit.models)>=3);
p1=double(reportFit.models{1}.parameters_full(:).');
p3=double(reportFit.models{3}.parameters_full(:).');
assert(numel(p1)==6&&numel(p3)==6&&all(isfinite([p1 p3])));
assert(all(p1(4:6)==0)&&p3(6)==0,'Unexpected parameters in frozen model 1 or model 3.');
registryTheta=double(registry.theta(:).');
assert(max(abs(p3(1:2)-registryTheta(1:2)))<1e-12);
assert(max(abs(p3(3:5)-[registry.actuator_calibration.coefficients(:).' registry.plant_characterization.lag_s]))<1e-12);

% Model 1 is the raw-command three-parameter nominal model; model 3 is the
% selected static-map-plus-lag predictor from the same immutable fit report.
nominalTheta=p1(1:3);
g1=p3(3);g2=p3(4);tau=p3(5);
gammaRef=(g1*52+g2*52^2/50)/52;
assert(abs(gammaRef-registry.actuator_calibration.gamma_ref)<1e-12);
mapLag=registry;
mapLag.theta=[p3(1),p3(2),gammaRef];
mapLag.actuator_calibration.coefficients=[g1 g2];
mapLag.actuator_calibration.gamma_ref=gammaRef;
mapLag.plant_characterization.lag_s=tau;

planLoaded=load(fullfile(campaignDir,'derived','validation_plan.mat'),'plan');
plan=planLoaded.plan;
manifestPath=fullfile(campaignDir,'campaign_manifest.json');
manifest=jsondecode(fileread(manifestPath));
ledger=jsondecode(fileread(fullfile(campaignDir,'campaign_status.json')));
original=load(assessmentMat,'report','details');
assert(numel(manifest.runs)==3&&numel(ledger.runs)==3&&numel(original.report.validation.per_run)==3);
assert(original.report.validation.include.passed==false, ...
    'Expected original frozen assessment to remain a failed assessment.');
runIds=string(original.report.validation.include.run_ids(:));
assert(isequal(runIds,string({manifest.runs.run_id}')),'Original assessment run IDs differ from frozen manifest.');
assert(all(strcmp({ledger.runs.code},'completed')),'All three frozen holdouts must be complete before comparison.');
assert(numel(original.details)==3);

nSub=double(plan.substeps);prefixSeconds=double(plan.state_prefix_s);
assert(nSub==8&&prefixSeconds==5,'This comparison is bound to the original 8-substep, 5-second assessment.');
runReport=repmat(struct('run_id','','raw_file','','raw_sha256','','model1',struct(), ...
    'model3_map_lag',struct(),'model3_prediction_max_difference_from_original_rad',NaN, ...
    'response_frequency_diagnostic',struct()),3,1);
rows=repmat(struct('run_id','','model','','initial_velocity_fit_rad_s',NaN, ...
    'scored_samples',0,'scored_duration_s',NaN,'rmse_deg',NaN,'bias_deg',NaN, ...
    'peak_abs_error_deg',NaN,'powered_samples',0,'powered_duration_s',NaN, ...
    'powered_rmse_deg',NaN,'powered_bias_deg',NaN,'powered_peak_abs_error_deg',NaN, ...
    'substep_8_vs_16_max_abs_deg',NaN),6,1);
predictions=cell(3,2);
originalComparison=struct('run_id',{},'rmse_difference_deg',{},'bias_difference_deg',{}, ...
    'peak_difference_deg',{},'powered_rmse_difference_deg',{},'powered_bias_difference_deg',{}, ...
    'prediction_max_abs_difference_rad',{});
rowIndex=0;
for k=1:3
    runId=char(runIds(k));
    assert(strcmp(ledger.runs(k).run_id,runId)&&strcmp(manifest.runs(k).run_id,runId));
    rawPath=fullfile(campaignDir,'runs',[runId '.mat']);
    assert(isfile(rawPath));
    r=pendulumlab.load_runs(string(rawPath));
    assert(strcmp(r.recording_kind,'physical')&&strcmp(r.status.code,'completed'));
    assert(strcmp(r.metadata.phase,'validation')&&strcmp(r.metadata.hardware_id,registry.hardware_id));
    rawHash=pendulumlab.file_hash(rawPath);
    assert(strcmpi(rawHash,r.provenance.source_sha256));
    assert(strcmpi(rawHash,string(original.report.validation.include.raw_hashes(k))));
    t=double(r.signals.t(:));y=double(r.signals.angle(:));uRaw=double(r.signals.u_command(:));
    assert(all(isfinite([t;y;uRaw]))&&all(diff(t)>0));
    prefix=find(t-t(1)<=prefixSeconds);
    assert(numel(prefix)>=4&&prefix(end)<numel(t));
    scored=(prefix(end)+1):numel(t);
    powered=uRaw(scored)>0;
    y0=y(1);

    v01=fitInitialVelocity(nominalTheta,t,uRaw,y,prefix,nSub);
    y1=pendulumlab.simulate_output(nominalTheta,t,uRaw,[v01;y0],nSub);
    y1x2=pendulumlab.simulate_output(nominalTheta,t,uRaw,[v01;y0],2*nSub);
    v03=fitInitialVelocity(mapLag,t,uRaw,y,prefix,nSub);
    y3=pendulumlab.predict_recorded_model(mapLag,t,uRaw,[v03;y0],nSub);
    y3x2=pendulumlab.predict_recorded_model(mapLag,t,uRaw,[v03;y0],2*nSub);
    predictions{k,1}=y1;predictions{k,2}=y3;
    e1=y1(scored)-y(scored);e3=y3(scored)-y(scored);
    metrics1=score(e1,powered,median(diff(t)),y1x2(scored)-y1(scored));
    metrics3=score(e3,powered,median(diff(t)),y3x2(scored)-y3(scored));
    originalPrediction=double(original.details{k}.nominal(:));
    predDiff=max(abs(y3-originalPrediction));
    assert(numel(originalPrediction)==numel(y3)&&predDiff<=1e-8, ...
        'Frozen model 3 prediction does not reproduce the archived full-rig assessment.');

    old=original.report.validation.per_run(k);
    oldRmse=rad2deg(old.candidate_rmse_rad);
    oldBias=rad2deg(old.candidate_bias_rad);
    oldPeak=rad2deg(old.candidate_peak_abs_error_rad);
    oldPoweredRmse=rad2deg(old.powered_rmse_rad);
    oldPoweredBias=rad2deg(old.powered_bias_rad);
    diffValues=[metrics3.rmse_deg-oldRmse,metrics3.bias_deg-oldBias, ...
        metrics3.peak_abs_error_deg-oldPeak,metrics3.powered_rmse_deg-oldPoweredRmse, ...
        metrics3.powered_bias_deg-oldPoweredBias];
    assert(all(abs(diffValues)<=1e-6), ...
        'Model 3 metrics do not reproduce the original assessment within 1e-6 degrees.');
    originalComparison(k)=struct('run_id',runId,'rmse_difference_deg',diffValues(1), ...
        'bias_difference_deg',diffValues(2),'peak_difference_deg',diffValues(3), ...
        'powered_rmse_difference_deg',diffValues(4),'powered_bias_difference_deg',diffValues(5), ...
        'prediction_max_abs_difference_rad',predDiff);

    runReport(k).run_id=runId;runReport(k).raw_file=rawPath;runReport(k).raw_sha256=rawHash;
    runReport(k).model1=metrics1;runReport(k).model3_map_lag=metrics3;
    runReport(k).model3_prediction_max_difference_from_original_rad=predDiff;
    runReport(k).response_frequency_diagnostic=responseFrequencyDiagnostic(r,y1,y3);
    rowIndex=rowIndex+1;rows(rowIndex)=asRow(runId,'model1_raw_three_parameter',v01,metrics1);
    rowIndex=rowIndex+1;rows(rowIndex)=asRow(runId,'model3_static_map_plus_lag',v03,metrics3);
end

if strlength(string(outputDir))==0
    outDir=fullfile(campaignDir,'derived',['secondary_model_comparison_' char(datetime('now','Format','yyyyMMdd_HHmmss'))]);
else
    outDir=char(java.io.File(char(outputDir)).getCanonicalPath());
    [allowed,why]=pendulumlab.output_location_allowed(outDir,'offline');
    assert(allowed,'Output location denied by offline policy: %s',why);
end
assert(~isfolder(outDir),'Refusing to overwrite an existing secondary comparison folder.');
[ok,msg]=mkdir(outDir);assert(ok,'Could not create secondary output directory: %s',msg);
report=struct();
report.schema_version='pendulumlab.secondary_frozen_predictor_comparison/1';
report.status='secondary_frozen_predictor_comparison_not_new_validation_criterion';
report.scope=['Two parameter-frozen predictors from the same pre-holdout fit report, compared on the same three fresh physical records. ', ...
    'Not a controller comparison, new prospective criterion, model truth claim, or replacement for the original failed assessment.'];
report.campaign_id=campaignId;report.output_folder=outDir;
report.source=struct('fit_report_mat',fitMat,'fit_report_json',fitJson,'fit_report_mat_sha256',fitHash, ...
    'fit_report_json_sha256',pendulumlab.file_hash(fitJson),'registry_json',registryPath, ...
    'registry_json_sha256',pendulumlab.file_hash(registryPath),'manifest',manifestPath, ...
    'manifest_sha256',pendulumlab.file_hash(manifestPath),'original_assessment_mat',assessmentMat, ...
    'original_assessment_mat_sha256',pendulumlab.file_hash(assessmentMat),'original_assessment_json',assessmentJson, ...
    'original_assessment_json_sha256',pendulumlab.file_hash(assessmentJson), ...
    'validation_predictor_source',which('pendulumlab.predict_recorded_model'), ...
    'validation_predictor_sha256',pendulumlab.file_hash(which('pendulumlab.predict_recorded_model')), ...
    'nominal_simulator_source',which('pendulumlab.simulate_output'), ...
    'nominal_simulator_sha256',pendulumlab.file_hash(which('pendulumlab.simulate_output')));
report.models=struct('model1_raw_three_parameter',p1,'model3_static_map_plus_lag',p3, ...
    'model3_gamma_ref_derived',gammaRef,'model3_parameters_source','same immutable identification_20261106_163437 fit report');
report.preprocessing=struct('initial_angle','Measured first sample; fixed, not fitted.', ...
    'initial_velocity','One nuisance v0 fit per model and run using only the first 5 seconds.', ...
    'scoring','Samples strictly after the 5-second prefix; powered subset uses raw u_command > 0.', ...
    'substeps',[nSub 2*nSub],'map_lag_initial_state','Effective acceleration lag state initialized to zero, matching the original full-rig predictor.');
report.run_ids=cellstr(runIds);report.runs=runReport;
report.model3_reproduction_of_original_assessment=originalComparison;
report.original_frozen_assessment_passed=original.report.validation.include.passed;
report.criteria_reapplied=false;
report.created_utc=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z'''));
report.analysis_script=[mfilename('fullpath') '.m'];
report.analysis_script_sha256=pendulumlab.file_hash(report.analysis_script);
report.figure_bases=cell(3,1);
for k=1:3
    runId=char(runIds(k));r=pendulumlab.load_runs(string(fullfile(campaignDir,'runs',[runId '.mat'])));
    t=double(r.signals.t(:));y=double(r.signals.angle(:));uRaw=double(r.signals.u_command(:));
    f=figure('Visible','off','Color','w','Position',[80 80 1000 800]);clean=onCleanup(@()close(f));
    tl=tiledlayout(f,3,1,'TileSpacing','compact','Padding','compact');
    ax=nexttile(tl);plot(ax,t,rad2deg(y),'k-',t,rad2deg(predictions{k,1}),'b--', ...
        t,rad2deg(predictions{k,2}),'r-','LineWidth',1);grid(ax,'on');
    ylabel(ax,'Angle [deg]');legend(ax,{'Measured $y$','Raw-command model','Map and lag predictor'}, ...
        'Interpreter','latex','Location','best');title(ax,'(a) Output prediction');
    ax=nexttile(tl);plot(ax,t,rad2deg(predictions{k,1}-y),'b--', ...
        t,rad2deg(predictions{k,2}-y),'r-','LineWidth',1);hold(ax,'on');
    plot(ax,[t(1) t(end)],[15 15],'k:',[t(1) t(end)],[-15 -15],'k:','HandleVisibility','off');
    grid(ax,'on');ylabel(ax,'$y_{\mathrm{pred}}-y$ [deg]','Interpreter','latex');
    legend(ax,{'Raw-command model','Map and lag predictor'},'Location','best');
    title(ax,'(b) Prediction error; dotted lines show the frozen peak-error target');
    ax=nexttile(tl);plot(ax,t,uRaw,'k-','LineWidth',1);grid(ax,'on');
    ylabel(ax,'$u_{\mathrm{cmd}}$ [command units]','Interpreter','latex');xlabel(ax,'Time (s)');
    title(ax,'(c) Recorded transmitted command');
    labels={'Ascending and descending commands','Multisine near 45 deg','Multisine near 60 deg'};
    title(tl,labels{k});
    base=fullfile(outDir,sprintf('holdout_%d',k));report.figure_bases{k}=base;
    savefig(f,[base '.fig']);exportgraphics(f,[base '.pdf'],'ContentType','vector');
    print(f,[base '.eps'],'-depsc','-painters');
    if k==3,exportgraphics(f,fullfile(tempdir,'pendulum_holdout60_preview.png'),'Resolution',140);end
    clear clean
end
zip(fullfile(outDir,'analysis_source_used.zip'),{report.analysis_script});
save(fullfile(outDir,'secondary_comparison.mat'),'report','rows','predictions','-v7');
writetable(struct2table(rows),fullfile(outDir,'metrics.csv'));
fid=fopen(fullfile(outDir,'secondary_comparison.json'),'wt');assert(fid>=0);c=onCleanup(@()fclose(fid));
fwrite(fid,jsonencode(report,PrettyPrint=true),'char');clear c
end

function v0=fitInitialVelocity(model,t,u,y,prefix,substeps)
obj=@(v) predict(model,t(prefix),u(prefix),[v;y(1)],substeps)-y(prefix);
if exist('lsqnonlin','file')==2
    op=optimoptions('lsqnonlin','Display','off','MaxIterations',100,'MaxFunctionEvaluations',300);
    v0=lsqnonlin(obj,0,-Inf,Inf,op);
else
    v0=fminsearch(@(v)sum(obj(v).^2),0,optimset('Display','off'));
end
end

function yhat=predict(model,t,u,x0,substeps)
if isstruct(model)
    yhat=pendulumlab.predict_recorded_model(model,t,u,x0,substeps);
else
    yhat=pendulumlab.simulate_output(model,t,u,x0,substeps);
end
end

function m=score(e,powered,dt,substepDifference)
e=e(:);powered=logical(powered(:));assert(numel(e)==numel(powered));
m=struct('scored_samples',numel(e),'scored_duration_s',numel(e)*dt, ...
    'rmse_deg',rad2deg(sqrt(mean(e.^2))),'bias_deg',rad2deg(mean(e)), ...
    'peak_abs_error_deg',rad2deg(max(abs(e))),'powered_samples',sum(powered), ...
    'powered_duration_s',sum(powered)*dt,'powered_rmse_deg',NaN, ...
    'powered_bias_deg',NaN,'powered_peak_abs_error_deg',NaN, ...
    'substep_8_vs_16_max_abs_deg',rad2deg(max(abs(substepDifference))));
if any(powered)
    ep=e(powered);m.powered_rmse_deg=rad2deg(sqrt(mean(ep.^2)));
    m.powered_bias_deg=rad2deg(mean(ep));m.powered_peak_abs_error_deg=rad2deg(max(abs(ep)));
end
end

function row=asRow(runId,modelName,v0,m)
row=struct('run_id',runId,'model',modelName,'initial_velocity_fit_rad_s',v0, ...
    'scored_samples',m.scored_samples,'scored_duration_s',m.scored_duration_s, ...
    'rmse_deg',m.rmse_deg,'bias_deg',m.bias_deg,'peak_abs_error_deg',m.peak_abs_error_deg, ...
    'powered_samples',m.powered_samples,'powered_duration_s',m.powered_duration_s, ...
    'powered_rmse_deg',m.powered_rmse_deg,'powered_bias_deg',m.powered_bias_deg, ...
    'powered_peak_abs_error_deg',m.powered_peak_abs_error_deg, ...
    'substep_8_vs_16_max_abs_deg',m.substep_8_vs_16_max_abs_deg);
end

function d=responseFrequencyDiagnostic(r,yRaw,yMapLag)
% Fixed-tone output descriptors compare predictions with the measured output.
% No transfer function, parameter fit, acceptance-criterion change or time shift.
d=struct('status','unavailable','reason','No declared multisine full-amplitude window.');
p=r.metadata.config.protocol;
if ~isfield(p,'multisine_design'),return,end
md=p.multisine_design;
if ~all(isfield(md,{'full_amplitude_interval_s','frequencies_hz'})),return,end
t=double(r.signals.t(:));y=double(r.signals.angle(:));u=double(r.signals.u_command(:));
Ts=double(r.metadata.config.Ts);window=double(md.full_amplitude_interval_s);
tones=double(md.frequencies_hz(:));idx=find(t>=window(1)&t<window(2));
% A response-triggered zero return changes the input. Retain its occurrence,
% and use only the preceding contiguous powered portion of this fixed window.
firstZero=find(u(idx)<=0,1);
if ~isempty(firstZero),idx=idx(1:firstZero-1);end
d.declared_window_s=window;d.frequencies_hz=tones;
d.window_rule='Declared full-amplitude window, truncated at its first actual nonpositive command; no prediction-error-based selection.';
d.actual_powered_samples=numel(idx);
if numel(idx)<4,d.reason='Insufficient actual powered samples in the declared window.';return,end
n=numel(idx);h=.5-.5*cos(2*pi*(0:n-1)'/(n-1));
E=exp(-1i*2*pi*(t(idx)-t(idx(1)))*tones.');
project=@(x)2*(E.'*(h.*(double(x(idx))-mean(double(x(idx))))))/sum(h);
cy=project(y);cRaw=project(yRaw(:));cMap=project(yMapLag(:));cu=project(u);
d.status='finite_window_response_descriptors';d.reason='';
d.actual_window_s=[t(idx(1)) t(idx(end))+Ts];d.duration_s=n*Ts;
d.cycles_at_lowest_declared_tone=n*Ts*min(tones);
d.measured_output_amplitude_deg=rad2deg(abs(cy));
d.raw_model_output_amplitude_deg=rad2deg(abs(cRaw));
d.map_lag_output_amplitude_deg=rad2deg(abs(cMap));
d.raw_model_minus_measured_phase_wrapped_deg=rad2deg(angle(cRaw.*conj(cy)));
d.map_lag_minus_measured_phase_wrapped_deg=rad2deg(angle(cMap.*conj(cy)));
d.transmitted_input_amplitude_raw_units=abs(cu);
d.interpretation=['Mean-removed Hann projections at the declared tones, on an identical actual-input window for both frozen predictions and measurement. ', ...
    'Finite-window leakage, transients and weak response components limit interpretation; these are descriptive amplitudes/phases, not a plant FRF, noise estimate, new accuracy gate or actuator-delay measurement.'];
end
