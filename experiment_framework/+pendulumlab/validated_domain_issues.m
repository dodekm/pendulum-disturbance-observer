function issues=validated_domain_issues(cfg,record)
%VALIDATED_DOMAIN_ISSUES Enforce the human-accepted empirical model domain.
% Observed angle/command coverage is necessary evidence, not a stability or
% full-state validation certificate. No unmeasured range is invented here.
issues={};
for name={'validated_angle_range_rad','validated_command_range'}
    key=name{1};
    if ~isfield(record.approval,key)||~validRange(record.approval.(key))
        issues{end+1}=['Explicit accepted model domain required: ' key]; %#ok<AGROW>
    end
end
if ~isempty(issues),return,end
a=double(record.approval.validated_angle_range_rad(:));
u=double(record.approval.validated_command_range(:));
if ~isfield(record.validation,'observed_angle_range_rad')|| ...
        ~isfield(record.validation,'observed_command_range')|| ...
        ~validRange(record.validation.observed_angle_range_rad)|| ...
        ~validRange(record.validation.observed_command_range)
    issues{end+1}='Held-out model-domain coverage is missing';return
end
oa=double(record.validation.observed_angle_range_rad(:));ou=double(record.validation.observed_command_range(:));
if a(1)<oa(1)-1e-10||a(2)>oa(2)+1e-10||u(1)<ou(1)-1e-10||u(2)>ou(2)+1e-10
    issues{end+1}='Accepted model domain extends beyond observed held-out angle/command coverage';
end
if strcmp(cfg.experiment_id,'reference_tracking'),refs=cfg.protocol.reference_levels_rad(:);else,refs=pi/4;end
if any(refs<a(1))||any(refs>a(2))
    issues{end+1}='Planned references extend beyond the accepted validated model angle range';
end
if cfg.u_limits(1)<u(1)-1e-10||cfg.u_limits(2)>u(2)+1e-10
    issues{end+1}='Configured command limits extend beyond the accepted validated model command range';
end
end
function tf=validRange(x)
tf=isnumeric(x)&&isreal(x)&&numel(x)==2&&all(isfinite(x(:)))&&x(1)<x(2);
end
