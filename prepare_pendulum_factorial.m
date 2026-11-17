function out=prepare_pendulum_factorial(modelId,options)
%PREPARE_PENDULUM_FACTORIAL Preview/freeze future calibrated screen or matrix.
% Preparation writes frozen schedules only; physical acquisition is separately guarded.
arguments
    modelId (1,1) string
    options.Plan (1,1) string = "screen"
    options.Mode (1,1) string = "preview"
    options.OrderSeed (1,1) double {mustBeFinite,mustBeNonnegative,mustBeInteger} = 811
end
assert(any(options.Plan==["screen","matrix"])&&any(options.Mode==["preview","freeze"]), ...
    'pendulumlab:FactorialPlan','Choose screen/matrix and preview/freeze.');
root=fileparts(mfilename('fullpath'));addpath(fullfile(root,'experiment_framework'));
phase='pilot';plan='pilot';if options.Plan=="matrix",phase='confirmatory';plan='expanded';end
cfg=pendulumlab.calibrated_control_config(modelId,string(phase));
cfg.mode='mock';cfg.campaign.plan=plan;cfg.campaign.order_seed=options.OrderSeed;
cfg.campaign.additional_settling_s=10;
cfg.order_seed=options.OrderSeed;cfg.session_id='revision_factorial_session_20261106';
cfg.session_deadline_utc='2026-11-06T21:45:00Z'; % 22:45 Europe/Bratislava
cfg.latest_start_utc='2026-11-06T21:40:00Z'; % 22:40 Europe/Bratislava
cfg.experiment_launcher_source_sha256=pendulumlab.file_hash([mfilename('fullpath') '.m']);
if options.Plan=="screen"
    conditions=[condition(25,true,.2,'a25_on_T_0p2'),condition(25,true,1.0,'a25_on_T_1p0'), ...
        condition(20,false,cfg.T,'a20_off'),condition(20,true,.2,'a20_on_T_0p2'), ...
        condition(20,true,.5,'a20_on_T_0p5'),condition(20,true,1.0,'a20_on_T_1p0')];
    expectedRuns=12;repetitions=1;
else
    conditions=repmat(condition(20,false,cfg.T,'a20_off'),1,0);
    for a=[20 25]
        conditions(end+1)=condition(a,false,cfg.T,sprintf('a%d_off',a)); %#ok<AGROW>
        for T=[.2 .5 1.0]
            conditions(end+1)=condition(a,true,T,strrep(sprintf('a%d_on_T_%0.1f',a,T),'.','p')); %#ok<AGROW>
        end
    end
    repetitions=3;expectedRuns=48;cfg.campaign.repetitions_per_protocol=repetitions;
end
cfg.campaign.control_conditions=conditions;

% Preview only constructs schedules in memory; it does not create a campaign,
% open a link, change the registry, or write acquisition artifacts.
protocolNames={'reference_tracking','injected_disturbance'};
preview=struct('protocol',{},'condition',{},'a',{},'use_compensation',{},'T',{}, ...
    'samples',{},'duration_s',{},'schedule_identity_sha256',{},'windows',{});
for pi=1:numel(protocolNames)
    name=protocolNames{pi};
    for rep=1:repetitions
        for ci=1:numel(conditions)
            c=cfg;c.phase=phase;c.experiment_id=name;
            c.protocol=cfg.campaign.control_protocols.(name);
            if options.Plan=="screen",pidx=find(strcmp(protocolNames,name));c.protocol.seed=cfg.protocol.seed+400+pidx;
            else,c.protocol.seed=cfg.protocol.seed;end
            c.a=conditions(ci).a;c.use_compensation=conditions(ci).use_compensation;c.T=conditions(ci).T;
            c.analysis.evaluation_windows=pendulumlab.analysis_windows(c);
            schedule=pendulumlab.make_schedule(c);
            row=struct('protocol',name,'condition',conditions(ci).label,'a',c.a, ...
                'use_compensation',c.use_compensation,'T',c.T,'samples',numel(schedule.t), ...
                'duration_s',schedule.duration_s, ...
                'schedule_identity_sha256',pendulumlab.schedule_identity_sha256(schedule), ...
                'windows',c.analysis.evaluation_windows);
            preview(end+1)=row; %#ok<AGROW>
        end
    end
end
assert(numel(preview)==expectedRuns,'pendulumlab:FactorialCount','Offline preview has the wrong cell/run count.');
out=struct('state','preview','plan',options.Plan,'model_id',modelId, ...
    'conditions',conditions,'repetitions_per_protocol',repetitions, ...
    'expected_runs',expectedRuns,'preview',preview,'manifest_path','');
if options.Mode=="preview",return,end

assert(cfg.hardware.model_accepted,'Explicit accepted characterized-model record is required before freezing.');
cfg.mode='hardware';cfg.output_dir=fullfile(root,'experiment_data','campaign_v2');
cfg.hardware.enabled=true;cfg.hardware.operator_armed=true;
cfg.hardware.mechanical_ready=true;cfg.hardware.angle_zero_confirmed=true;
for j=1:numel(protocolNames)
    cfg.campaign.control_protocols.(protocolNames{j}).operating_envelope_approved=true;
end
cfg.protocol=cfg.campaign.control_protocols.reference_tracking;
for pi=1:numel(protocolNames)
    for ci=1:numel(conditions)
        check=cfg;check.phase=phase;check.experiment_id=protocolNames{pi};
        check.protocol=cfg.campaign.control_protocols.(protocolNames{pi});
        check.a=conditions(ci).a;check.use_compensation=conditions(ci).use_compensation;check.T=conditions(ci).T;
        check.analysis.evaluation_windows=pendulumlab.analysis_windows(check);
        gate=pendulumlab.validate_config(check);
        assert(gate.hardware_allowed,'%s / %s: %s',protocolNames{pi},conditions(ci).label,strjoin(gate.issues,'; '));
    end
end
manifest=pendulumlab.prepare_campaign(cfg,string(plan));
assert(manifest.run_count==expectedRuns,'Frozen campaign has unexpected run count.');
out.state='frozen_not_armed';out.manifest_path=manifest.manifest_path;out.campaign_id=manifest.campaign_id;
out.config=cfg;
derived=fullfile(manifest.campaign_folder,'derived');mkdir(derived);
plan=struct('manifest_path',manifest.manifest_path,'manifest_sha256',manifest.manifest_sha256, ...
    'model_id',char(modelId),'model_record_sha256',cfg.model_record.registry_file_hash, ...
    'raw_motor_limits',double(cfg.u_limits),'controller_a_values',double(manifest.controller_a_values), ...
    'analysis_windows_tracking',pendulumlab.analysis_windows(cfg), ...
    'target_repetitions_per_condition_protocol',repetitions, ...
    'minimum_first_wave_per_condition_protocol',1,'deadline_utc',cfg.session_deadline_utc, ...
    'latest_start_utc',cfg.latest_start_utc,'plan',char(options.Plan), ...
    'conditions',conditions,'repetitions_per_protocol',repetitions,'expected_runs',expectedRuns, ...
    'one_run_per_fresh_arm',true,'cross_campaign_recovery_s',30, ...
    'failure_policy','Preserve every attempted outcome; no automatic retry or exclusion of valid adverse trajectories.', ...
    'screening_data_excluded_from_matrix',true,'current_core_manifest_modified',false);
save(fullfile(derived,'control_plan.mat'),'plan','-v7');
fid=fopen(fullfile(derived,'control_plan.json'),'wt');assert(fid>=0);
h=onCleanup(@()fclose(fid));fprintf(fid,'%s',jsonencode(plan,PrettyPrint=true));clear h
factorial_plan=plan;save(fullfile(derived,'factorial_plan.mat'),'factorial_plan','preview','-v7');
fid=fopen(fullfile(derived,'factorial_plan.json'),'wt');assert(fid>=0);
h=onCleanup(@()fclose(fid));fprintf(fid,'%s',jsonencode(factorial_plan,PrettyPrint=true));clear h
zip(fullfile(manifest.campaign_folder,'factorial_source_used.zip'), ...
    {'prepare_pendulum_factorial.m','prepare_pendulum_campaign.m','verify_pendulum_framework.m','experiment_framework/+pendulumlab'},root);
fprintf('FROZEN %s: %s\n',upper(char(options.Plan)),manifest.manifest_path);
end

function c=condition(a,on,T,label)
c=struct('a',double(a),'use_compensation',logical(on),'T',double(T),'label',char(label));
end


