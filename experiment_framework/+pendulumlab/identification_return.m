function [state,transition]=identification_return(arg,y,t,index)
%IDENTIFICATION_RETURN Frozen one-way excitation termination, not angle control.
% One argument validates/initializes from cfg. Four arguments advance state.
transition=false;
if nargin==1
    cfg=arg;state=struct('enabled',false);
    enabled=any(strcmp(cfg.experiment_id,{'identification_angle_coverage','validation_angle_coverage'}));
    if ~enabled
        assert(~isfield(cfg.protocol,'return_policy'),'pendulumlab:ReturnPolicy','Return policy is reserved for angle-coverage identification.');return
    end
    phaseMatches=strcmp(cfg.phase,'identification')&&strcmp(cfg.experiment_id,'identification_angle_coverage')|| ...
        strcmp(cfg.phase,'validation')&&strcmp(cfg.experiment_id,'validation_angle_coverage');
    assert(phaseMatches&&~cfg.use_compensation&&cfg.u_limits(1)==0, ...
        'pendulumlab:ReturnPolicy','Angle return requires a matching open-loop identification/validation phase, zero lower command, and no compensation.');
    assert(isfield(cfg.protocol,'return_policy'),'pendulumlab:ReturnPolicy','Return policy is missing.');
    p=cfg.protocol.return_policy;
    assert(all(isfield(p,{'version','target_abs_angle_rad','active_deadline_s','required_zero_tail_s','direct_zero_approved'})), ...
        'pendulumlab:ReturnPolicy','Incomplete return policy.');
    assert(strcmp(p.version,'angle_zero_return_v1')&&isequal(p.direct_zero_approved,true), ...
        'pendulumlab:ReturnPolicy','The direct-zero return must be explicitly approved.');
    vals=[p.target_abs_angle_rad p.active_deadline_s p.required_zero_tail_s];
    assert(isnumeric(vals)&&isreal(vals)&&numel(vals)==3&&all(isfinite(vals))&&all(vals>0)&& ...
        p.target_abs_angle_rad<cfg.safety.max_abs_angle_rad&&p.required_zero_tail_s>=20&& ...
        p.active_deadline_s+p.required_zero_tail_s<=cfg.protocol.duration_s, ...
        'pendulumlab:ReturnPolicy','Target must precede absolute trip; deadline must leave the required zero tail.');
    state=struct('enabled',true,'policy',p,'latched',false,'reason','', ...
        'target_reached',false,'target_reached_in_active_phase',false,'first_target_t_s',NaN, ...
        'trigger_sample',NaN,'trigger_t_s',NaN,'trigger_angle_rad',NaN, ...
        'trigger_device_s',NaN,'trigger_host_s',NaN,'zero_write_count',0);
    return
end
state=arg;if ~state.enabled,return,end
assert(isscalar(y)&&isfinite(y)&&isscalar(t)&&isfinite(t),'pendulumlab:ReturnPolicy','Invalid return-policy measurement.');
hit=abs(y)>=state.policy.target_abs_angle_rad;
if hit&&~state.target_reached,state.target_reached=true;state.first_target_t_s=t;end
if ~state.latched
    if t>=state.policy.active_deadline_s
        state.latched=true;state.reason='active_deadline';
    elseif hit
        state.latched=true;state.reason='angle_target';state.target_reached_in_active_phase=true;
    end
    if state.latched
        transition=true;state.trigger_sample=index;state.trigger_t_s=t;state.trigger_angle_rad=y;
    end
end
end
