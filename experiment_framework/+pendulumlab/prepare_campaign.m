function manifest=prepare_campaign(cfg,plan)
%PREPARE_CAMPAIGN Freeze a deterministic campaign without opening any link.
% manifest=prepare_campaign(cfg,plan) supports identification, validation,
% pilot, confirmatory-core (20 runs), and confirmatory-expanded (40 runs).
arguments
    cfg (1,1) struct
    plan (1,1) string = ""
end
if strlength(plan)==0
    if isfield(cfg,'campaign')&&isfield(cfg.campaign,'plan'), plan=string(cfg.campaign.plan);
    else, plan=string(cfg.phase); end
end
plan=lower(plan);
validPlans=["identification","validation","pilot","core","expanded","confirmatory-core","confirmatory-expanded"];
assert(any(plan==validPlans),'pendulumlab:CampaignPlan','Unsupported campaign plan %s.',plan);
if startsWith(plan,"confirmatory-"), plan=extractAfter(plan,"confirmatory-"); end
base=cfg;
if ~isfield(base,'campaign')||~isstruct(base.campaign), base.campaign=struct(); end
if ~isfield(base.campaign,'intertrial_recovery_s'), base.campaign.intertrial_recovery_s=NaN; end
base.campaign.max_physical_runs_per_invocation=1;
if string(base.mode)=="hardware"
    base.output_dir=fullfile(char(base.source_root),'experiment_data','campaign_v2');
end
[outputAllowed,outputReason]=pendulumlab.output_location_allowed(base.output_dir,base.mode);
if ~outputAllowed, error('pendulumlab:OutputLocation','%s',outputReason); end
% Make/validate the complete spec inventory before creating any campaign
% folder. Invalid generic conditions/repetition counts leave no orphan folder.
[specs,randomized]=make_specs(base,plan);
if isempty(specs), error('pendulumlab:CampaignEmpty','Plan produced no runs.'); end
campaignId=['cmp_' uuid_text()]; campaignFolder=fullfile(char(base.output_dir),'campaigns',campaignId);
if isfolder(campaignFolder), error('pendulumlab:CampaignExists','Campaign folder already exists.'); end
mkdir(campaignFolder); mkdir(fullfile(campaignFolder,'schedules')); mkdir(fullfile(campaignFolder,'runs'));
base.campaign_id=campaignId;
runRows=repmat(struct('run_id','','block_id','','session_id','','planned_session_id','', ...
    'planned_session_slot','', ...
    'trial_id',0, ...
    'phase','','protocol','','condition','','use_compensation',false,'T',NaN,'a',NaN, ...
    'model_id','','hardware_id','','config_sha256','','schedule_file','', ...
    'schedule_sha256','','schedule_identity_sha256','', ...
    'schedule_name','','schedule_seed',NaN,'injection_seed',NaN,'planned_order',0),numel(specs),1);
for k=1:numel(specs)
    spec=specs(k); runId=['run_' uuid_text()];
    cfgRun=base; cfgRun.phase=spec.phase; cfgRun.experiment_id=spec.experiment_id;
    cfgRun.protocol=spec.protocol; cfgRun.use_compensation=spec.use_compensation;
    cfgRun.T=spec.T; cfgRun.a=spec.a; cfgRun.rng_seed=spec.injection_seed;
    cfgRun.campaign_id=campaignId; cfgRun.run_id=runId;
    cfgRun.block_id=spec.block_id; cfgRun.planned_session_id=char(base.session_id);
    if string(base.mode)=="hardware", cfgRun.session_id='';
    else, cfgRun.session_id=char(base.session_id); end
    cfgRun.trial_id=spec.trial_id; cfgRun.output_dir=campaignFolder;
    if isfield(cfgRun,'mock'), cfgRun.mock.seed=spec.mock_seed; end
    cfgRun.analysis.evaluation_windows=pendulumlab.analysis_windows(cfgRun);
    schedule=pendulumlab.make_schedule(cfgRun);
    scheduleFile=fullfile(campaignFolder,'schedules',[runId '.mat']);
    tmp=[tempname(fileparts(scheduleFile)) '.mat'];
    save(tmp,'cfgRun','schedule','-v7');
    [ok,msg]=movefile(tmp,scheduleFile);
    if ~ok, if isfile(tmp), delete(tmp); end
        error('pendulumlab:CampaignFreeze','Could not freeze schedule: %s',msg);
    end
    relSchedule=fullfile('schedules',[runId '.mat']);
    runRows(k)=struct('run_id',runId,'block_id',spec.block_id, ...
        'session_id',char(cfgRun.session_id),'planned_session_id',char(cfgRun.planned_session_id), ...
        'planned_session_slot',spec.session_id, ...
        'trial_id',spec.trial_id,'phase',spec.phase, ...
        'protocol',spec.experiment_id,'condition',spec.condition, ...
        'use_compensation',logical(spec.use_compensation),'T',double(spec.T),'a',double(cfgRun.a), ...
        'model_id',char(cfgRun.model_id),'hardware_id',char(cfgRun.hardware_id), ...
        'config_sha256',pendulumlab.json_value_sha256(cfgRun), ...
        'schedule_file',relSchedule,'schedule_sha256',pendulumlab.file_hash(scheduleFile), ...
        'schedule_identity_sha256',pendulumlab.schedule_identity_sha256(schedule), ...
        'schedule_name',char(schedule.name),'schedule_seed',double(schedule.seed), ...
        'injection_seed',double(schedule.injection_seed),'planned_order',k);
end
sourceHashes=pendulumlab.source_fingerprint();
controllerAValues=sort(unique([runRows.a]));controllerA=controllerAValues(1);
if numel(controllerAValues)>1,controllerA=NaN;end
manifest=struct('schema_version','pendulumlab.campaign/1','campaign_id',campaignId, ...
    'plan',char(plan),'phase',char(runRows(1).phase),'created_utc',utc_now(), ...
    'frozen',true,'run_count',numel(runRows),'order_seed',double(base.order_seed), ...
    'randomization',randomized,'hardware_id',char(base.hardware_id), ...
    'model_id',char(base.model_id),'model_status',char(base.model_status), ...
    'model_hardware_id',char(base.model_hardware_id),'theta',double(base.theta), ...
    'controller_a',double(controllerA),'controller_a_values',double(controllerAValues), ...
    'observer_T_values',unique([runRows.T]), ...
    'u_limits',double(base.u_limits),'sample_period_s',double(base.Ts), ...
    'synthetic_only',strcmp(base.mode,'mock'),'recording_mode',char(base.mode), ...
    'physical_hardware_note','Historical recordings use original_propeller; this campaign is replacement_propeller_01. Versions are not pooled.', ...
    'max_physical_runs_per_invocation',1, ...
    'intertrial_recovery_s',double(base.campaign.intertrial_recovery_s), ...
    'intertrial_recovery_policy','At most one physical trial per invocation; a later invocation requires a fresh operator arm after the configured recovery interval. Missing interval blocks physical execution.', ...
    'source_sha256',sourceHashes,'runs',runRows, ...
    'status_file','campaign_status.json');
manifestPath=fullfile(campaignFolder,'campaign_manifest.json');
write_json_atomic(manifestPath,manifest,false);
manifestHash=pendulumlab.file_hash(manifestPath);
write_text_atomic(fullfile(campaignFolder,'campaign_manifest.sha256'),[manifestHash newline],false);
status=struct('schema_version','pendulumlab.campaign_status/1', ...
    'campaign_id',campaignId,'updated_utc',utc_now(), ...
    'runs',repmat(struct('run_id','','code','planned','reason','', ...
    'result_file','','started_utc','','finished_utc','','read_count',0, ...
    'read_attempt_count',0,'rest_read_count',0,'trial_read_count',0, ...
    'write_count',0,'operator_id','', ...
    'runtime_arm_utc','','runtime_arm_id','','actual_session_id',''),numel(runRows),1));
for k=1:numel(runRows), status.runs(k).run_id=runRows(k).run_id; end
write_json_atomic(fullfile(campaignFolder,'campaign_status.json'),status,false);
manifest.manifest_path=manifestPath; manifest.manifest_sha256=manifestHash;
manifest.campaign_folder=campaignFolder;
end

function [specs,randomized]=make_specs(base,plan)
specs=repmat(empty_spec(),0,1); phase=string(base.phase); order=RandStream('mt19937ar','Seed',double(base.order_seed));
[controlConditions,hasControlConditions]=validated_control_conditions(base);
repetitions=5;
if isfield(base.campaign,'repetitions_per_protocol')
    repetitions=base.campaign.repetitions_per_protocol;
    assert(isnumeric(repetitions)&&isreal(repetitions)&&isscalar(repetitions)&&isfinite(repetitions)&& ...
        repetitions>=1&&repetitions==round(repetitions), ...
        'pendulumlab:Repetitions','repetitions_per_protocol must be a positive whole number.');
end
randomized=struct('method','MT19937 seeded local randomization; generic balanced grids use prefix-balanced blocks; schedule RNG is separately seeded.', ...
    'order_seed',double(base.order_seed),'unit','complete physical run','block_order',[],'within_block_orders',{{}});
if plan=="identification"
    phase="identification";stages=pendulumlab.identification_stages(base);
    for j=1:numel(stages)
        p=stages(j).protocol;name=string(stages(j).experiment_id);
        specs(end+1)=new_spec(phase,name,p,false,base.T, ...
            sprintf('id_%02d',j),sprintf('session_%02d',j),j, ...
            double(base.rng_seed)+j,double(base.mock.seed)+j,name); %#ok<AGROW>
    end
elseif plan=="validation"
    phase="validation"; names=["validation_multilevel","validation_multilevel", ...
        "validation_multisine","validation_multisine"];
    custom=isfield(base.campaign,'validation_profiles')&&~isempty(base.campaign.validation_profiles);
    if custom
        profiles=base.campaign.validation_profiles;
        assert(isstruct(profiles)&&isvector(profiles)&&all(isfield(profiles,{'experiment_id','protocol'})), ...
            'pendulumlab:ValidationProfile','Supply complete validation protocol profiles.');
        names=string({profiles.experiment_id});
        assert(all(ismember(names,["validation_multilevel","validation_multisine","validation_static_map","validation_angle_coverage"])), ...
            'pendulumlab:ValidationProfile','Custom profiles must remain open-loop validation protocols.');
    end
    for j=1:numel(names)
        if custom,p=profiles(j).protocol;
        else,p=base.protocol;p.bias_command=stage_bias(base,'validation_bias_commands',j,numel(names));end
        p.seed=base.protocol.seed+300+j;
        specs(end+1)=new_spec(phase,names(j),p,false,base.T, ...
            sprintf('val_%02d',j),sprintf('session_%02d',j),j, ...
            double(base.rng_seed)+300+j,double(base.mock.seed)+300+j,names(j)); %#ok<AGROW>
    end
elseif plan=="pilot"
    phase="pilot"; protocols=["reference_tracking","injected_disturbance"];
    if hasControlConditions
        protocolOrder=randperm(order,numel(protocols));randomized.block_order=protocolOrder;
        for bi=1:numel(protocolOrder)
            pidx=protocolOrder(bi);name=protocols(pidx);p=control_protocol(base,name);
            p.seed=base.protocol.seed+400+pidx;conditionOrder=randperm(order,numel(controlConditions));labels={};
            for ci=1:numel(conditionOrder)
                cc=controlConditions(conditionOrder(ci));label=cc.label;
                spec=new_spec(phase,name,p,cc.use_compensation,cc.T, ...
                    sprintf('pilot_%s_%s',char(name),label),sprintf('pilot_session_%s',char(name)), ...
                    ci,double(base.rng_seed),double(base.mock.seed)+400+pidx+ci,label);
                spec.a=cc.a;specs(end+1)=spec;labels{end+1}=label; %#ok<AGROW>
            end
            randomized.within_block_orders{end+1}=struct('block_id',char(name),'order',{labels}); %#ok<AGROW>
        end
    else
        % Preserve the legacy pilot grid/order exactly when no generic grid is supplied.
        for pidx=1:2
            pilotT=[NaN 0.2 0.5 1.0];
            if isfield(base.campaign,'pilot_primary_only')&&isequal(base.campaign.pilot_primary_only,true)
                pilotT=[NaN base.T];
            end
            for ci=1:numel(pilotT)
                on=ci>1; T=base.T; if on, T=pilotT(ci); end
                name=protocols(pidx); p=control_protocol(base,name);
                p.seed=base.protocol.seed+400+pidx; label=condition_label(on,T);
                safeLabel=strrep(label,'.','p');
                specs(end+1)=new_spec(phase,name,p,on,T, ...
                    sprintf('pilot_%s_%s',char(name),safeLabel),sprintf('pilot_session_%s',char(name)), ...
                    ci,double(base.rng_seed), ...
                    double(base.mock.seed)+400+pidx+ci,label); %#ok<AGROW>
            end
        end
    end
elseif any(plan==["core","expanded"])
    phase="confirmatory"; protocols=["reference_tracking","injected_disturbance"];
    genericGrid=hasControlConditions||isfield(base.campaign,'repetitions_per_protocol');
    if genericGrid
        if hasControlConditions
            conditions=controlConditions;
        elseif plan=="core"
            conditions=[control_condition(base.a,false,base.T,'off'), ...
                control_condition(base.a,true,base.T,condition_label(true,base.T))];
        else
            conditions=[control_condition(base.a,false,base.T,'off'), ...
                control_condition(base.a,true,.2,condition_label(true,.2)), ...
                control_condition(base.a,true,.5,condition_label(true,.5)), ...
                control_condition(base.a,true,1.0,condition_label(true,1.0))];
        end
        blockSpecs=repmat(struct('pidx',0,'rep',0,'order',[]),2*repetitions,1);q=0;
        for pidx=1:2
            for rep=1:repetitions
                q=q+1;blockSpecs(q).pidx=pidx;blockSpecs(q).rep=rep;
                blockSpecs(q).order=balanced_condition_order(order,conditions);
            end
        end
        pidxs=[blockSpecs.pidx];blockOrder=balanced_protocol_order(order,pidxs);randomized.block_order=blockOrder;
        for oi=1:numel(blockOrder)
            bspec=blockSpecs(blockOrder(oi));protocol=protocols(bspec.pidx);
            block=sprintf('%s_rep%02d',char(protocol),bspec.rep);session=sprintf('session_%02d',oi);
            seed=double(base.rng_seed);mockSeed=double(base.mock.seed)+1000*bspec.pidx+bspec.rep;within={};
            for ci=bspec.order
                cc=conditions(ci);p=control_protocol(base,protocol);p.seed=base.protocol.seed;
                spec=new_spec(phase,protocol,p,cc.use_compensation,cc.T,block,session,ci,seed,mockSeed,cc.label);
                spec.a=cc.a;specs(end+1)=spec;within{end+1}=cc.label; %#ok<AGROW>
            end
            randomized.within_block_orders{end+1}=struct('block_id',block,'order',{within}); %#ok<AGROW>
        end
    else
        % Preserve the existing core/expanded condition and random draw sequence
        % when both generic fields are absent.
        if plan=="core", onT=base.T; else, onT=[0.2 0.5 1.0]; end
        if plan=="core", runT=[NaN onT]; else, runT=[NaN onT]; end
        conditionCount=numel(runT); blockSpecs=repmat(struct('pidx',0,'rep',0,'order',[]),10,1); q=0;
        for pidx=1:2
            for rep=1:5
                q=q+1; blockSpecs(q).pidx=pidx; blockSpecs(q).rep=rep;
                blockSpecs(q).order=randperm(order,conditionCount);
            end
        end
        blockOrder=randperm(order,q); randomized.block_order=blockOrder;
        for oi=1:numel(blockOrder)
            bspec=blockSpecs(blockOrder(oi)); protocol=protocols(bspec.pidx);
            block=sprintf('%s_rep%02d',char(protocol),bspec.rep);session=sprintf('session_%02d',oi);
            seed=double(base.rng_seed); % keep rng(1,'twister') sequence fixed across blocks
            mockSeed=double(base.mock.seed)+1000*bspec.pidx+bspec.rep;within={};
            for ci=bspec.order
                on=ci>1;T=base.T;if on,T=onT(ci-1);end
                label=condition_label(on,T);p=control_protocol(base,protocol);p.seed=base.protocol.seed;
                specs(end+1)=new_spec(phase,protocol,p,on,T,block,session,ci,seed,mockSeed,label); %#ok<AGROW>
                within{end+1}=label; %#ok<AGROW>
            end
            randomized.within_block_orders{end+1}=struct('block_id',block,'order',{within}); %#ok<AGROW>
        end
    end
elseif plan=="expanded"
    error('pendulumlab:Plan','Expanded plan is internally represented by the branch above.');
else
    error('pendulumlab:Plan','Invalid campaign plan.');
end
for k=1:numel(specs)
    specs(k).trial_id=k;
    if ~isfinite(specs(k).a),specs(k).a=double(base.a);end
end
randomized.actual_run_order={specs.condition};
end
function [conditions,found]=validated_control_conditions(base)
conditions=struct('a',{},'use_compensation',{},'T',{},'label',{});found=false;
if ~isfield(base.campaign,'control_conditions'),return,end
x=base.campaign.control_conditions;
required={'a','use_compensation','T','label'};
assert(isstruct(x)&&~isempty(x)&&isvector(x)&&all(isfield(x,required)), ...
    'pendulumlab:ControlConditions','control_conditions must be a nonempty struct vector with a, use_compensation, T and label.');
labels=strings(1,numel(x));conditions=repmat(struct('a',NaN,'use_compensation',false,'T',NaN,'label',''),1,numel(x));
for k=1:numel(x)
    a=x(k).a;on=x(k).use_compensation;T=x(k).T;label=string(x(k).label);
    assert(isnumeric(a)&&isreal(a)&&isscalar(a)&&isfinite(a)&&a>0&& ...
        (islogical(on)||isnumeric(on))&&isreal(on)&&isscalar(on)&&ismember(double(on),[0 1])&& ...
        isnumeric(T)&&isreal(T)&&isscalar(T)&&isfinite(T)&&T>0&&isscalar(label)&&strlength(label)>0&& ...
        ~isempty(regexp(char(label),'^[A-Za-z0-9_-]+$','once')), ...
        'pendulumlab:ControlConditions','Each condition requires positive finite a/T, scalar boolean compensation, and a safe label.');
    labels(k)=label;conditions(k)=struct('a',double(a),'use_compensation',logical(on), ...
        'T',double(T),'label',char(label));
end
assert(numel(unique(labels))==numel(labels),'pendulumlab:ControlConditions','Condition labels must be unique.');found=true;
end
function c=control_condition(a,on,T,label)
c=struct('a',double(a),'use_compensation',logical(on),'T',double(T),'label',char(label));
end
function orderOut=balanced_condition_order(stream,conditions)
% For equal-count two-gain matrices, constrain every within-block prefix so
% the cumulative count difference stays <=1. This ensures adjacent pairs
% contain one condition at each gain. Unequal grids retain random order.
gains=unique([conditions.a]);counts=arrayfun(@(g)sum([conditions.a]==g),gains);
if numel(gains)~=2||counts(1)~=counts(2)
    orderOut=randperm(stream,numel(conditions));return
end
for attempt=1:10000
    candidate=randperm(stream,numel(conditions));ordered=[conditions(candidate).a];
    first=cumsum(ordered==gains(1));second=cumsum(ordered==gains(2));
    if all(abs(first-second)<=1),orderOut=candidate;return,end
end
error('pendulumlab:ConditionRandomization','Could not draw a prefix-balanced equal-gain condition order.');
end
function orderOut=balanced_protocol_order(stream,pidxs)
for attempt=1:10000
    candidate=randperm(stream,numel(pidxs));ordered=pidxs(candidate);
    first=cumsum(ordered==1);second=cumsum(ordered==2);
    if all(abs(first-second)<=1),orderOut=candidate;return,end
end
error('pendulumlab:BlockRandomization','Could not draw a prefix-balanced protocol block order.');
end
function p=control_protocol(base,name)
p=base.protocol;
if ~isfield(base.campaign,'control_protocols')||isempty(base.campaign.control_protocols),return;end
overrides=base.campaign.control_protocols;
assert(isstruct(overrides)&&isscalar(overrides), ...
    'pendulumlab:ControlProtocol','campaign.control_protocols must be a scalar struct.');
field=char(name);
if ~isfield(overrides,field),return;end
candidate=overrides.(field);
assert(isstruct(candidate)&&isscalar(candidate)&&all(isfield(candidate,fieldnames(base.protocol))), ...
    'pendulumlab:ControlProtocol','Each control protocol override must be a complete protocol struct.');
p=candidate;
end
function spec=new_spec(phase,name,p,on,T,block,session,trial,seed,mockSeed,label)
spec=empty_spec(); spec.phase=char(phase); spec.experiment_id=char(name); spec.protocol=p;
spec.use_compensation=logical(on); spec.T=double(T); spec.block_id=char(block);
spec.session_id=char(session); spec.trial_id=double(trial); spec.injection_seed=double(seed);
spec.mock_seed=double(mockSeed); spec.condition=char(label);
end
function value=stage_bias(base,field,index,count)
value=base.protocol.bias_command;
if isfield(base.campaign,field)&&~isempty(base.campaign.(field))
    values=base.campaign.(field);
    assert(isnumeric(values)&&numel(values)==count&&all(isfinite(values(:))), ...
        'pendulumlab:StageBias','%s requires one finite command bias per planned run.',field);
    value=values(index);
end
end
function s=empty_spec()
s=struct('phase','','experiment_id','','protocol',struct, ...
    'use_compensation',false,'T',NaN,'a',NaN,'block_id','','session_id','', ...
    'trial_id',0,'injection_seed',1,'mock_seed',1,'condition','');
end
function label=condition_label(on,T)
if ~on, label='off'; else, label=sprintf('on_T_%0.1f',T); end
end
function id=uuid_text()
id=char(java.util.UUID.randomUUID()); id=erase(id,'-');
end
function t=utc_now()
t=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss.SSSXXX'));
end
function write_json_atomic(path,value,replace)
text=jsonencode(value); write_text_atomic(path,text,replace);
end
function write_text_atomic(path,text,replace)
if isfile(path)&&~replace, error('pendulumlab:Frozen','Refusing to overwrite frozen file %s.',path); end
folder=fileparts(path); if ~isfolder(folder), mkdir(folder); end
fid=fopen([tempname(folder) '.tmp'],'wt'); if fid<0, error('pendulumlab:Write','Could not create atomic temp file.'); end
name=fopen(fid); guard=onCleanup(@()fclose(fid)); fwrite(fid,text,'char'); clear guard
if isfile(path)&&~replace, delete(name); error('pendulumlab:Frozen','Refusing to overwrite frozen file.'); end
[ok,msg]=movefile(name,path,'f'); if ~ok, if isfile(name), delete(name); end
    error('pendulumlab:Write','Atomic write failed: %s',msg); end
end
