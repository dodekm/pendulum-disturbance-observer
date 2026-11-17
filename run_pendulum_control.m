function report=run_pendulum_control(manifestPath,options)
%RUN_PENDULUM_CONTROL One fresh-arm pilot/confirmatory recording with deadline.
arguments
    manifestPath (1,1) string
    options.HardwareArmed (1,1) logical = false
    options.MechanicalReady (1,1) logical = false
    options.AngleZeroConfirmed (1,1) logical = false
    options.OperatorId (1,1) string = ""
    options.SessionId (1,1) string = ""
    options.StopFile (1,1) string = ""
end
root=fileparts(mfilename('fullpath'));addpath(fullfile(root,'experiment_framework'));
assert(options.HardwareArmed&&options.MechanicalReady&&options.AngleZeroConfirmed,'pendulumlab:HardwareArm','Current-session readiness is required.');
assert(strlength(options.OperatorId)>0&&strlength(options.SessionId)>0,'pendulumlab:OperatorIdentity','Supply actual operator/session.');
assert(strlength(options.StopFile)>0&&~isfile(options.StopFile),'pendulumlab:StopFlagExists','Stop flag exists or is missing from configuration.');
m=jsondecode(fileread(manifestPath));folder=fileparts(char(manifestPath));
[allowed,why]=pendulumlab.output_location_allowed(folder,'hardware');assert(allowed,'pendulumlab:OutputLocation','%s',why);
assert(strcmp(m.recording_mode,'hardware')&&any(strcmp(m.phase,{'pilot','confirmatory'})),'Control-only runner.');
z=load(fullfile(folder,'derived','control_plan.mat'),'plan');plan=z.plan;
assert(strcmp(plan.manifest_sha256,pendulumlab.file_hash(char(manifestPath))),'Frozen control plan changed.');
status=jsondecode(fileread(fullfile(folder,'campaign_status.json')));next=find(strcmp({status.runs.code},'planned'),1);
assert(~isempty(next),'No pending control recording.');
z=load(fullfile(folder,m.runs(next).schedule_file),'cfgRun','schedule');cfg=z.cfgRun;
assert(strcmp(pendulumlab.file_hash(fullfile(folder,m.runs(next).schedule_file)),m.runs(next).schedule_sha256)&& ...
    strcmp(pendulumlab.json_value_sha256(cfg),m.runs(next).config_sha256)&& ...
    strcmp(pendulumlab.schedule_identity_sha256(z.schedule),m.runs(next).schedule_identity_sha256),'Frozen schedule/config changed.');
auth=pendulumlab.load_model(string(cfg.model_id),string(cfg.model_registry_dir));
assert(strcmp(auth.registry_file_hash,plan.model_record_sha256)&&strcmp(options.SessionId,cfg.planned_session_id), ...
    'Accepted model or actual session differs from the plan.');
recovery=m.intertrial_recovery_s+cfg.campaign.additional_settling_s;
campaignRoot=fullfile(root,'experiment_data','campaign_v2','campaigns');
while true
    state=pendulumlab.physical_recovery_state(campaignRoot,recovery);
    assert(~state.blocked,'pendulumlab:RecoveryUnresolved','%s',state.reason);
    if state.ready,break,end
    assert(~isfile(options.StopFile),'Stop requested during recovery.');pause(.5);
end
warm=pendulumlab.default_config('pilot');warm.mode='mock';warm.theta=cfg.theta;warm.mock.theta=cfg.theta;
warm.actuator_calibration=cfg.actuator_calibration;warm.safety.max_slew_units_s=40;
warm.output_dir=fullfile(tempdir,['pendulum_control_warm_' char(java.util.UUID.randomUUID)]);
warm.run_id=['warm_' char(java.util.UUID.randomUUID)];warm.async_checkpoint=true;
w=struct('name','reference_tracking','role','pilot','seed',warm.protocol.seed,'injection_seed',warm.rng_seed, ...
    'duration_s',2,'t',(0:39)'*.05,'reference',zeros(40,1),'injection',zeros(40,1),'command',nan(40,1));
r=pendulumlab.run_trial(warm,w);assert(strcmp(r.status.code,'completed')&&strcmp(r.recording_kind,'synthetic'),'Offline warmup failed.');
[stop,receipt]=pendulumlab.deadline_guard(pendulumlab.parse_utc(cfg.session_deadline_utc),z.schedule.duration_s+30, ...
    LatestStart=pendulumlab.parse_utc(cfg.latest_start_utc),StopFile=options.StopFile);
arm=struct('HardwareArmed',true,'operator_id',char(options.OperatorId),'session_id',char(options.SessionId), ...
    'arm_id',['arm_' char(java.util.UUID.randomUUID)], ...
    'confirmed_utc',char(datetime('now','TimeZone','UTC','Format',"yyyy-MM-dd'T'HH:mm:ss.SSSXXX")));
receipt.arm_id=arm.arm_id;receipt.runner_sha256=pendulumlab.file_hash([mfilename('fullpath') '.m']);
file=fullfile(folder,'derived',['deadline_' arm.arm_id '.json']);fid=fopen(file,'wt');assert(fid>=0);
g=onCleanup(@()fclose(fid));fprintf(fid,'%s',jsonencode(receipt,PrettyPrint=true));clear g
zip(fullfile(folder,'derived',['runner_' arm.arm_id '.zip']),{'run_pendulum_control.m'},root);
report=pendulumlab.run_campaign(manifestPath,arm,stop);
fprintf('CONTROL %d/%d completed; aborted%d interlock%d fault%d\n',report.summary.completed,m.run_count, ...
    report.summary.aborted,report.summary.interlock,report.summary.fault);
end
