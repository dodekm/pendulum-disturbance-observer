function report = validate_config(cfg)
%VALIDATE_CONFIG Inspect configuration only; never construct a hardware link.
issues={}; warnings={};
outputAllowed=false;
try
required={'mode','phase','experiment_id','Ts','theta','a','T','u_limits', ...
    'safety','hardware','protocol','hardware_id','model_hardware_id','model_status','output_dir'};
for k=1:numel(required)
    if ~isfield(cfg,required{k}), issues{end+1}=['Missing ' required{k}]; end %#ok<AGROW>
end
if ~isempty(issues), report=finish(); return; end
groups={'safety','hardware','protocol'};
fields={{'max_abs_angle_rad','max_slew_units_s','max_duration_s','max_device_gap_s', ...
    'max_host_cycle_s','rest_samples','rest_range_rad','rest_slope_rad_s'}, ...
    {'enabled','operator_armed','mechanical_ready','angle_zero_confirmed','model_accepted', ...
    'COM_port','baudrate','stream_id','read_timeout_ms','write_timeout_ms'}, ...
    {'duration_s','bias_command','amplitude_command','baseline_s','ramp_s','dwell_s','seed', ...
    'reference_levels_rad','plateau_s','injection_amplitude','operator_excitation_approved', ...
    'multisine_hz','operating_envelope_approved'}};
for k=1:numel(groups)
    g=groups{k};
    if ~isstruct(cfg.(g))||~all(isfield(cfg.(g),fields{k}))
        issues{end+1}=['Configuration group is incomplete: ' g]; %#ok<AGROW>
    end
end
if ~isempty(issues),report=finish();return;end
angleLimit=cfg.safety.max_abs_angle_rad;
if ~isnumeric(angleLimit)||~isreal(angleLimit)||~isscalar(angleLimit)|| ...
        ~(isnan(angleLimit)||(isfinite(angleLimit)&&angleLimit>0&&angleLimit<=pi))
    issues{end+1}='max_abs_angle_rad must be in (0,pi]; NaN is allowed only offline and retains the 180-degree cutoff';
end
[outputAllowed,why]=pendulumlab.output_location_allowed(cfg.output_dir,cfg.mode);
if ~outputAllowed,issues{end+1}=why;end
for key={'max_duration_s','max_device_gap_s','max_host_cycle_s','rest_samples','rest_range_rad','rest_slope_rad_s'}
    name=key{1};value=cfg.safety.(name);
    if ~isnumeric(value)||~isscalar(value)||~isfinite(value)||value<=0
        issues{end+1}=['Invalid positive acquisition setting: ' name]; %#ok<AGROW>
    end
end
if cfg.safety.rest_samples<4||cfg.safety.rest_samples~=round(cfg.safety.rest_samples)
    issues{end+1}='Rest gate requires at least four whole samples';
end
if cfg.safety.max_device_gap_s<cfg.Ts
    issues{end+1}='Device-gap threshold cannot be shorter than the sampling period';
end
for key={'read_timeout_ms','write_timeout_ms','COM_port'}
    name=key{1};value=cfg.hardware.(name);
    if ~isnumeric(value)||~isscalar(value)||~isfinite(value)||value<=0||value~=round(value)
        issues{end+1}=['Require a positive integer hardware setting: ' name]; %#ok<AGROW>
    end
end
for key={'integration_substeps','checkpoint_samples'}
    name=key{1};
    if ~isfield(cfg,name)||~isnumeric(cfg.(name))||~isscalar(cfg.(name))|| ...
            ~isfinite(cfg.(name))||cfg.(name)<1||cfg.(name)~=round(cfg.(name))
        issues{end+1}=['Require a positive whole-sample algorithm setting: ' name]; %#ok<AGROW>
    end
end
if ~isfield(cfg,'use_compensation')||~isscalar(cfg.use_compensation)|| ...
        ~ismember(cfg.use_compensation,[0 1])
    issues{end+1}='use_compensation must be a scalar logical or zero/one';
end
for key={'run_id','campaign_id','block_id'}
    name=key{1};
    if isfield(cfg,name)&&strlength(string(cfg.(name)))>0&& ...
            isempty(regexp(char(cfg.(name)),'^[A-Za-z0-9_-]+$','once'))
        issues{end+1}=['Unsafe identifier: ' name]; %#ok<AGROW>
    end
end
if ~any(string(cfg.mode)==["mock","replay","hardware"]), issues{end+1}='Unknown mode'; end
if ~any(string(cfg.phase)==["identification","validation","pilot","confirmatory"])
    issues{end+1}='Unknown phase';
elseif any(string(cfg.phase)==["pilot","confirmatory"])
    if ~any(string(cfg.experiment_id)==["reference_tracking","injected_disturbance"])
        issues{end+1}='Control phases require an established feedback protocol';
    end
elseif ~startsWith(string(cfg.experiment_id),string(cfg.phase)+"_")
    issues{end+1}='Acquisition phase and excitation protocol do not match';
end
if ~isscalar(cfg.Ts)||~isfinite(cfg.Ts)||abs(cfg.Ts-.05)>1e-12, issues{end+1}='Ts must equal firmware period 0.05 s'; end
if numel(cfg.theta)~=3||any(~isfinite(cfg.theta))||cfg.theta(1)<=0||cfg.theta(2)<0||cfg.theta(3)<=0
    issues{end+1}='Require finite alpha>0, beta>=0, gamma>0 in the established sign convention';
end
if any(string(cfg.phase)==["pilot","confirmatory"])&&numel(cfg.theta)==3&&cfg.theta(2)<=0
    issues{end+1}='Nominal feedback asymptotic stability requires strictly positive damping beta';
end
if ~isscalar(cfg.T)||~isfinite(cfg.T)||cfg.T<=0||~isscalar(cfg.a)||~isfinite(cfg.a)||cfg.a<=0
    issues{end+1}='Positive finite T and a are required';
end
if isscalar(cfg.T)&&isfinite(cfg.T)&&cfg.T>0&&isscalar(cfg.Ts)&&isfinite(cfg.Ts)
    z=-cfg.Ts/cfg.T; rk4Radius=abs(1+z+z^2/2+z^3/6+z^4/24);
    if rk4Radius>=1
        issues{end+1}='The one-step RK4 Q-filter update is not numerically stable at this Ts/T';
    end
end
if numel(cfg.u_limits)~=2||any(~isfinite(cfg.u_limits))||cfg.u_limits(1)<0||cfg.u_limits(2)>100||cfg.u_limits(1)>=cfg.u_limits(2)
    issues{end+1}='Experiment commands must remain within a nonempty subset of [0,100]';
end
try
    if pendulumlab.actuator_coordinates(cfg,'enabled'),pendulumlab.actuator_coordinates(cfg,'limits');end
catch err
    issues{end+1}=['Invalid actuator calibration: ' err.message];
end
numericProtocol={'duration_s','bias_command','amplitude_command','baseline_s','ramp_s','dwell_s', ...
    'plateau_s','injection_amplitude','seed'};
for k=1:numel(numericProtocol)
    key=numericProtocol{k};v=cfg.protocol.(key);
    if ~isnumeric(v)||~isscalar(v)||~isfinite(v)||v<0
        issues{end+1}=['Protocol value must be a finite nonnegative scalar: ' key]; %#ok<AGROW>
    end
end
if cfg.protocol.duration_s<=0||cfg.protocol.ramp_s<=0||cfg.protocol.dwell_s<=0||cfg.protocol.plateau_s<=0
    issues{end+1}='Duration, ramp, dwell and plateau must be positive';
end
if isfield(cfg.protocol,'command_slew_units_s')
    plannedSlew=cfg.protocol.command_slew_units_s;
    if ~isnumeric(plannedSlew)||~isreal(plannedSlew)||~isscalar(plannedSlew)||~isfinite(plannedSlew)||plannedSlew<=0
        issues{end+1}='Planned excitation slew must be positive and finite';
    elseif isfinite(cfg.safety.max_slew_units_s)&&plannedSlew>=cfg.safety.max_slew_units_s
        issues{end+1}='Planned excitation slew must be below the approved runtime slew limit, with headroom';
    end
end
if isempty(cfg.protocol.reference_levels_rad)||any(~isfinite(cfg.protocol.reference_levels_rad))
    issues{end+1}='Reference levels must be a nonempty finite vector in radians';
end
physical=string(cfg.mode)=="hardware";
if strcmp(cfg.experiment_id,'identification_angle_coverage')||isfield(cfg.protocol,'return_policy')
    try,pendulumlab.identification_return(cfg);
    catch err,issues{end+1}=['Invalid identification return policy: ' err.message];end
end
if physical
    gateNames={'enabled','operator_armed','mechanical_ready','angle_zero_confirmed'};
    for k=1:numel(gateNames)
        name=gateNames{k};
        if ~isfield(cfg.hardware,name)||~isequal(cfg.hardware.(name),true)
            issues{end+1}=['Hardware gate not satisfied: ' name]; %#ok<AGROW>
        end
    end
    for name={'max_abs_angle_rad','max_slew_units_s','max_duration_s','max_device_gap_s','max_host_cycle_s'}
        key=name{1};
        if ~isfield(cfg.safety,key)||~isscalar(cfg.safety.(key))||~isfinite(cfg.safety.(key))||cfg.safety.(key)<=0
            issues{end+1}=['Explicit positive physical limit required: ' key]; %#ok<AGROW>
        end
    end
    if cfg.hardware.baudrate~=250000||cfg.hardware.stream_id~=1
        issues{end+1}='The existing firmware interface requires baudrate 250000 and stream 1';
    end
    if strcmp(cfg.experiment_id,'reference_tracking')&&isfinite(cfg.safety.max_abs_angle_rad)&& ...
            any(abs(cfg.protocol.reference_levels_rad)>cfg.safety.max_abs_angle_rad)
        issues{end+1}='A planned reference exceeds the approved absolute-angle envelope';
    end
    if strcmp(cfg.experiment_id,'injected_disturbance')&&isfinite(cfg.safety.max_abs_angle_rad)&& ...
            pi/4>cfg.safety.max_abs_angle_rad
        issues{end+1}='The injection-test 45-degree reference exceeds the approved angle envelope';
    end
    if ~isfield(cfg.protocol,'operating_envelope_approved')||~isequal(cfg.protocol.operating_envelope_approved,true)
        issues{end+1}='Physical operating envelope has not been approved';
    end
    if any(string(cfg.phase)==["identification","validation"])
        if ~isfield(cfg.protocol,'operator_excitation_approved')||~isequal(cfg.protocol.operator_excitation_approved,true)
            issues{end+1}='Physical excitation has not been approved';
        end
    else
        if ~any(string(cfg.model_status)==["validated","characterized"])||string(cfg.model_hardware_id)~=string(cfg.hardware_id)||~isequal(cfg.hardware.model_accepted,true)
            issues{end+1}='Control requires an explicitly accepted validated model or characterized model for this hardware version';
        end
        if ~isfield(cfg,'model_record')||isempty(fieldnames(cfg.model_record))
            issues{end+1}='Control requires an auditable model registry record, not a status string alone';
        else
            issues=[issues model_record_issues(cfg)];
        end
    end
else
    warnings{end+1}='Offline results do not establish physical readiness or model validation';
end

if string(cfg.hardware_id)=="replacement_propeller_01"&&string(cfg.model_hardware_id)=="original_propeller"
    warnings{end+1}='Original-propeller theta is an initial guess, not a replacement-propeller validation';
end
catch err
    issues{end+1}=['Configuration could not be validated: ' err.message];
end
report=finish();
    function out=finish
        out=struct('valid',isempty(issues),'hardware_allowed',isempty(issues)&&isfield(cfg,'mode')&& ...
            (isequal(cfg.mode,'hardware')||isequal(cfg.mode,"hardware")), ...
            'output_allowed',outputAllowed,'issues',{issues},'errors',{issues},'warnings',{warnings});
    end
end

function issues=model_record_issues(cfg)
issues={};
try
    if ~isfield(cfg,'model_registry_dir')
        issues={'The validated model registry location is missing'};return
    end
    auth=pendulumlab.load_model(string(cfg.model_id),string(cfg.model_registry_dir));
    required={'status','model_id','theta','hardware_id','training','validation','approval'};
    if ~all(isfield(auth,required))
        issues={'The registry record lacks model/validation/approval provenance'};return
    end
    if ~any(string(auth.status)==["validated","characterized"])||string(auth.status)~=string(cfg.model_status)||string(auth.hardware_id)~=string(cfg.hardware_id)|| ...
            string(auth.model_id)~=string(cfg.model_id)||numel(auth.theta)~=3|| ...
            max(abs(double(auth.theta(:))-double(cfg.theta(:))))>1e-12
        issues{end+1}='Configured model does not match the checksum-verified validated hardware model';
    end
    if ~isfield(cfg.model_record,'registry_file_hash')|| ...
            ~strcmp(cfg.model_record.registry_file_hash,auth.registry_file_hash)
        issues{end+1}='Configuration must bind the current checksum-verified registry record';
    end
    a=auth.approval;
    hasCalibration=isfield(auth,'actuator_calibration');
    if hasCalibration
        if ~isfield(cfg,'actuator_calibration')|| ...
                ~strcmp(pendulumlab.json_integrity_sha256(cfg.actuator_calibration),pendulumlab.json_integrity_sha256(auth.actuator_calibration))
            issues{end+1}='Runtime actuator calibration differs from the validated registry model';
        end
    elseif pendulumlab.actuator_coordinates(cfg,'enabled')
        issues{end+1}='Runtime calibration has no corresponding validated registry descriptor';
    end
    if ~isequaln(cfg.model_record.approval,a)
        issues{end+1}='Configured model approval differs from the checksum-verified registry';
    end
    issues=[issues pendulumlab.validated_domain_issues(cfg,auth)];
    if ~pendulumlab.model_use_accepted(auth)|| ...
            ~isfield(a,'name')||strlength(string(a.name))==0|| ...
            ~isfield(a,'timestamp')||strlength(string(a.timestamp))==0|| ...
            (isfield(a,'is_test')&&isequal(a.is_test,true))
        issues{end+1}='A real named and timestamped human model acceptance is required';
    end
    sets={auth.training,auth.validation};
    for k=1:2
        v=sets{k};fields={'recording_kinds','hardware_ids','run_ids','raw_hashes'};
        if ~all(isfield(v,fields))
            issues{end+1}='Registry training/validation source provenance is incomplete';continue %#ok<AGROW>
        end
        kinds=string(v.recording_kinds);ids=string(v.run_ids);hashes=string(v.raw_hashes);
        if isempty(ids)||numel(ids)~=numel(hashes)||numel(ids)~=numel(kinds)|| ...
                any(kinds~="physical")||any(string(v.hardware_ids)~=string(cfg.hardware_id))|| ...
                any(strlength(hashes)~=64)||numel(unique(ids))~=numel(ids)||numel(unique(hashes))~=numel(hashes)
            issues{end+1}='Only independent hashed physical sources from the same hardware can authorize control'; %#ok<AGROW>
        end
    end
    v=auth.validation;
    if strcmp(auth.status,'characterized')
        if ~isfield(auth,'validation_report')||~isfield(auth,'accuracy_validation_passed')|| ...
                ~isequal(auth.accuracy_validation_passed,false)
            issues{end+1}='Characterized use must retain its failed complete accuracy assessment';
        else
            original=auth.validation_report;copy=original;copy.include.report_hash='';
            checks={'complete_frozen_plan','preacquisition_candidate_and_criteria_binding','max_substep_doubling_rad'};
            if ~strcmp(pendulumlab.json_integrity_sha256(copy),v.report_hash)|| ...
                    ~isequaln(original.include,v)|| ...
                    ~strcmp(original.candidate_model_descriptor_sha256,pendulumlab.model_descriptor_sha256(auth))|| ...
                    ~all(isfield(original.criteria_evaluation,checks))|| ...
                    ~all(cellfun(@(key)isequal(original.criteria_evaluation.(key),true),checks))
                issues{end+1}='Characterized-use evidence failed integrity, provenance, completeness or numerical checks';
            end
        end
    end
    if ~isfield(v,'criteria_frozen')||~isequal(v.criteria_frozen,true)|| ...
            ~isfield(v,'passed')||~pendulumlab.model_use_accepted(auth)|| ...
            ~isfield(v,'report_hash')||strlength(string(v.report_hash))~=64
        issues{end+1}='Verified held-out validation with frozen criteria is required';
    end
    if all(isfield(auth.training,{'run_ids','raw_hashes'}))&&all(isfield(v,{'run_ids','raw_hashes'}))
        if ~isempty(intersect(string(auth.training.run_ids),string(v.run_ids)))|| ...
                ~isempty(intersect(string(auth.training.raw_hashes),string(v.raw_hashes)))
            issues{end+1}='Training and validation provenance overlaps';
        end
    end
catch err
    issues{end+1}=['Validated registry could not be verified: ' err.message];
end
end
