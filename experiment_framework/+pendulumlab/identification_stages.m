function stages=identification_stages(cfg)
%IDENTIFICATION_STAGES Default five-run plan or explicitly specified profiles.
names={'identification_multilevel','identification_multilevel', ...
    'identification_multilevel','identification_prbs','identification_multisine'};
profiles=[];
nStages=5;
if isfield(cfg.campaign,'identification_profiles'),profiles=cfg.campaign.identification_profiles;end
if ~isempty(profiles)
    fields={'experiment_id','bias_command','amplitude_command','ramp_s','dwell_s','command_slew_units_s'};
    assert(isstruct(profiles)&&isvector(profiles)&&all(isfield(profiles,fields)), ...
        'pendulumlab:StageProfile','Provide a nonempty vector of complete identification profiles.');
    nStages=numel(profiles);
end
stages=repmat(struct('experiment_id','','protocol',struct()),nStages,1);
for k=1:nStages
    p=cfg.protocol;name=names{min(k,numel(names))};
    if ~isempty(profiles)
        name=char(profiles(k).experiment_id);
        assert(any(strcmp(name,[names {'identification_ringdown','identification_static_map','identification_angle_coverage'}])),'pendulumlab:StageProfile','Invalid identification protocol.');
        for key={'bias_command','amplitude_command','ramp_s','dwell_s','command_slew_units_s'}
            value=profiles(k).(key{1});
            assert(isnumeric(value)&&isreal(value)&&isscalar(value)&&isfinite(value)&&value>=0, ...
                'pendulumlab:StageProfile','Stage %d has an invalid %s.',k,key{1});
            p.(key{1})=value;
        end
        assert(p.ramp_s>0&&p.dwell_s>0&&p.command_slew_units_s>0, ...
            'pendulumlab:StageProfile','Stage timing and planned slew must be positive.');
    elseif isfield(cfg.campaign,'identification_bias_commands')&&~isempty(cfg.campaign.identification_bias_commands)
        values=cfg.campaign.identification_bias_commands;
        assert(isnumeric(values)&&numel(values)==5&&all(isfinite(values(:))), ...
            'pendulumlab:StageBias','identification_bias_commands requires five finite values.');
        p.bias_command=values(k);
    end
    p.seed=cfg.protocol.seed+100*k;
    stages(k)=struct('experiment_id',name,'protocol',p);
end
end
