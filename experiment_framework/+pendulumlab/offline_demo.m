function demo=offline_demo(options)
%OFFLINE_DEMO Exercise acquisition, identification and evaluation without UART.
% Every generated recording is synthetic. Shortened identification waveforms
% keep this demonstration practical; they are not the physical protocol.
arguments
    options.OutputDirectory (1,1) string = ""
    options.ExportFigures (1,1) logical = true
end
root=pendulumlab.project_root();
if strlength(options.OutputDirectory)==0
    folder=fullfile(root,'experiment_framework','verification',['demo_' char(java.util.UUID.randomUUID)]);
else
    folder=char(options.OutputDirectory);
end
[allowed,why]=pendulumlab.output_location_allowed(folder,'mock');
assert(allowed,'pendulumlab:OutputLocation','%s',why);
assert(~isfolder(folder),'pendulumlab:DemoExists','Use a new demo folder.');
mkdir(folder);
baseline=pendulumlab.verify_protected();assert(baseline.passed,'pendulumlab:Protected','Legacy baseline changed.');
truth=[46 .65 .62];
cfg=pendulumlab.default_config('identification');
cfg.hardware_id='synthetic_model';cfg.mock.hardware_id='synthetic_model';
cfg.mock.theta=truth;cfg.mock.noise_std_rad=2e-4;
cfg.output_dir=fullfile(folder,'synthetic');cfg.session_id='offline_demo';
cfg.protocol.duration_s=30;cfg.protocol.baseline_s=2;
cfg.protocol.ramp_s=4;cfg.protocol.dwell_s=1.5;
cfg.checkpoint_samples=600;
idPlan=pendulumlab.prepare_campaign(cfg,'identification');
idStatus=pendulumlab.run_campaign(idPlan.manifest_path);
assert(all(strcmp({idStatus.runs.code},'completed')),'pendulumlab:DemoAcquisition','Synthetic identification run failed.');
training=pendulumlab.load_runs(string(idPlan.campaign_folder));
fitOptions=struct('theta_bounds',[30 70;.1 2;.3 1], ...
    'multi_start',3,'max_iterations',150,'max_function_evaluations',4000, ...
    'bootstrap_replicates',8,'bootstrap_method','whole_run');
[candidate,fitReport]=pendulumlab.identify_model(training,fitOptions);
registry=fullfile(folder,'synthetic_model_registry');
pendulumlab.save_model(candidate,string(registry));
candidate=pendulumlab.load_model(string(candidate.model_id),string(registry));
% Freeze the illustrative limit before generating held-out recordings.
criteria=pendulumlab.freeze_model_criteria(struct('id','synthetic_demo_only', ...
    'max_candidate_rmse_rad',.02),'automated offline fixture; not human physical acceptance');
cfg.phase='validation';cfg.experiment_id='validation_multilevel';
valPlan=pendulumlab.prepare_campaign(cfg,'validation');
valStatus=pendulumlab.run_campaign(valPlan.manifest_path);
assert(all(strcmp({valStatus.runs.code},'completed')),'pendulumlab:DemoValidation','Synthetic validation acquisition failed.');
holdout=pendulumlab.load_runs(string(valPlan.campaign_folder));
validation=pendulumlab.validate_model(candidate,holdout, ...
    struct('initial_state_fit_window_s',1,'criteria',criteria));
promotionRejected=false;
try
    pendulumlab.promote_model(candidate,validation,struct('registry_dir',string(registry), ...
        'approval',struct('accepted_for_control',false)));
catch err
    promotionRejected=strcmp(err.identifier,'pendulumlab:ValidationKind');
end
assert(promotionRejected,'pendulumlab:SyntheticPromotion','Synthetic data must never authorize physical control.');
% Offline control uses the candidate only to verify software. No validated
% physical registry record or hardware acceptance is manufactured.
ctl=pendulumlab.default_config('confirmatory');
ctl.hardware_id='synthetic_model';ctl.mock.hardware_id='synthetic_model';
ctl.mock.theta=truth;ctl.mock.noise_std_rad=2e-4;ctl.mock.disturbance=1;
ctl.mock.disturbance_start_read=ctl.safety.rest_samples+1;
ctl.theta=candidate.theta;ctl.model_id=candidate.model_id;ctl.model_status='candidate';
ctl.model_hardware_id='synthetic_model';ctl.session_id='offline_demo';
ctl.output_dir=fullfile(folder,'synthetic');ctl.checkpoint_samples=600;
core=pendulumlab.prepare_campaign(ctl,'core');
expanded=pendulumlab.prepare_campaign(ctl,'expanded');
coreStatus=pendulumlab.run_campaign(core.manifest_path);
assert(all(strcmp({coreStatus.runs.code},'completed')),'pendulumlab:DemoControl','Synthetic core campaign failed.');
records=pendulumlab.load_runs(string(core.campaign_folder));
evaluation=pendulumlab.evaluate_campaign(records);
assert(numel(evaluation.trials)==20&&numel(evaluation.groups)==4, ...
    'pendulumlab:DemoGrouping','Expected four groups with five synthetic trials each.');
assert(all([evaluation.groups.n_primary_complete]==5),'pendulumlab:DemoCoverage','Incomplete synthetic coverage.');
assert(numel(evaluation.paired_block_effects)==6&&all([evaluation.paired_block_effects.n_pairs]==5), ...
    'pendulumlab:DemoPairing','Expected five paired blocks for each of three metrics and two protocols.');
if options.ExportFigures
    pendulumlab.evaluate_campaign(records,OutputDirectory=string(fullfile(folder,'evaluation')));
end
after=pendulumlab.verify_protected();assert(after.passed,'pendulumlab:Protected','Protected files changed.');
demo=struct('schema_version','pendulumlab.offline_demo/1', ...
    'recording_kind','synthetic','no_hardware_executed',true, ...
    'folder',folder,'synthetic_truth',truth,'candidate',candidate,'fit',fitReport, ...
    'validation',validation,'synthetic_promotion_rejected',promotionRejected, ...
    'identification_run_count',idPlan.run_count,'validation_run_count',valPlan.run_count, ...
    'core_run_count',core.run_count,'expanded_planned_run_count',expanded.run_count, ...
    'core_manifest',core.manifest_path,'evaluation',evaluation,'protected_after',after, ...
    'scope','Software demonstration only; no replacement-propeller model or repeatability result is established. Eight bootstrap resamples are a smoke check, not an adequate final uncertainty analysis.');
save(fullfile(folder,'offline_demo.mat'),'demo','-v7');
summary=rmfield(demo,{'candidate','fit','validation','evaluation'});
summary.fitted_theta=candidate.theta;
summary.relative_parameter_error=(candidate.theta(:).'-truth)./truth;
assert(max(abs(summary.relative_parameter_error))<.05, ...
    'pendulumlab:DemoRecovery','Synthetic parameter recovery exceeds the five-percent verification tolerance.');
summary.validation_candidate_rmse_rad=validation.summary.candidate_rmse_by_run_rad;
summary.validation_baseline_rmse_rad=validation.summary.baseline_rmse_by_run_rad;
summary.paired_counts=[evaluation.paired_block_effects.n_pairs];
fid=fopen(fullfile(folder,'offline_demo_summary.json'),'wt');
assert(fid>=0,'pendulumlab:DemoSave','Cannot save demo summary.');
cleanup=onCleanup(@()fclose(fid));fprintf(fid,'%s',jsonencode(summary,PrettyPrint=true));clear cleanup
fprintf('Synthetic demonstration complete: %s\n',folder);
end
