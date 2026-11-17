function out=prepare_calibrated_experiments(modelId,options)
%PREPARE_CALIBRATED_EXPERIMENTS Freeze primary pilots or matched repetitions.
% Preparation never opens UART; model acceptance and a later runtime arm apply.
arguments
    modelId (1,1) string
    options.Plan (1,1) string = "pilot"
    options.Mode (1,1) string = "preview"
end
root=fileparts(mfilename('fullpath'));addpath(fullfile(root,'experiment_framework'));
assert(any(options.Plan==["pilot","core"])&&any(options.Mode==["preview","freeze"]));
phase='pilot';if options.Plan=="core",phase='confirmatory';end
cfg=pendulumlab.calibrated_control_config(modelId,string(phase));cfg.campaign.plan=char(options.Plan);
cfg.campaign.pilot_primary_only=true;
cfg.experiment_launcher_source_sha256=pendulumlab.file_hash([mfilename('fullpath') '.m']);
cfg.campaign.additional_settling_s=10; % in addition to the 20-s recovery floor
if options.Plan=="core"
    [seed,order]=restrictedSeed();cfg.order_seed=seed;
    cfg.campaign.order_selection=struct('rule','First seed in 1:10000 satisfying protocol balance after 2,4,6 blocks and 2/3 split of first-condition order per protocol.', ...
        'selected_seed',seed,'selected_block_order',order,'selection_used_outcomes',false);
end
out=struct('state','preview','config',cfg,'manifest_path','');
if options.Mode=="preview",return,end
assert(cfg.hardware.model_accepted,'Explicit accepted model record is required before freezing physical control.');
cfg.mode='hardware';cfg.output_dir=fullfile(root,'experiment_data','campaign_v2');
cfg.hardware.enabled=true;cfg.hardware.operator_armed=true;cfg.hardware.mechanical_ready=true;cfg.hardware.angle_zero_confirmed=true;
names={'reference_tracking','injected_disturbance'};
for j=1:2,cfg.campaign.control_protocols.(names{j}).operating_envelope_approved=true;end
cfg.protocol=cfg.campaign.control_protocols.reference_tracking;
ready=pendulumlab.validate_config(cfg);assert(ready.hardware_allowed,'%s',strjoin(ready.issues,'; '));
m=pendulumlab.prepare_campaign(cfg,options.Plan);
if options.Plan=="pilot",assert(m.run_count==4,'Primary pilot must contain exactly four planned runs.');
else
    assert(m.run_count==20);first=string({m.runs(1:12).protocol});
    assert(sum(first=="reference_tracking")==6&&sum(first=="injected_disturbance")==6, ...
        'The first twelve recordings must contain three paired blocks per protocol.');
end
out.state='frozen_not_armed';out.config=cfg;out.manifest_path=m.manifest_path;
derived=fullfile(m.campaign_folder,'derived');mkdir(derived);
repetitions=1;minimum=1;if options.Plan=="core",repetitions=5;minimum=3;end
plan=struct('manifest_path',m.manifest_path,'manifest_sha256',m.manifest_sha256, ...
    'model_id',char(modelId),'model_record_sha256',cfg.model_record.registry_file_hash, ...
    'raw_motor_limits',cfg.u_limits,'a',cfg.a,'T',cfg.T,'plan',char(options.Plan), ...
    'analysis_windows_tracking',pendulumlab.analysis_windows(cfg), ...
    'target_repetitions_per_condition_protocol',repetitions,'minimum_first_wave_per_condition_protocol',minimum, ...
    'failure_policy','Preserve every attempted outcome; no automatic retry or exclusion of valid adverse trajectories.', ...
    'deadline_utc',cfg.session_deadline_utc,'latest_start_utc',cfg.latest_start_utc);
save(fullfile(derived,'control_plan.mat'),'plan','-v7');
fid=fopen(fullfile(derived,'control_plan.json'),'wt');assert(fid>=0);g=onCleanup(@()fclose(fid));fprintf(fid,'%s',jsonencode(plan,PrettyPrint=true));clear g
zip(fullfile(m.campaign_folder,'acquisition_source_used.zip'), ...
    {'prepare_calibrated_experiments.m','prepare_pendulum_campaign.m','verify_pendulum_framework.m','experiment_framework/+pendulumlab'},root);
fprintf('FROZEN %s: %s\n',upper(char(options.Plan)),m.manifest_path);
end
function [seed,order]=restrictedSeed()
for seed=1:10000
    stream=RandStream('mt19937ar','Seed',seed);within=zeros(10,2);
    for j=1:10,within(j,:)=randperm(stream,2);end
    order=randperm(stream,10);
    if sum(order(1:2)<=5)~=1||sum(order(1:4)<=5)~=2||sum(order(1:6)<=5)~=3,continue,end
    first=within(:,1)==1;
    if ~ismember(sum(first(1:5)),[2 3])||~ismember(sum(first(6:10)),[2 3]),continue,end
    return
end
error('No seed met the predeclared restricted randomization constraints.');
end
