function schedule = make_schedule(cfg)
%MAKE_SCHEDULE Deterministic plans only; synthetic defaults are not hardware limits.
name=string(cfg.experiment_id);Ts=cfg.Ts;p=cfg.protocol;
plannedSlew=NaN;
switch name
    case {"identification_static_map","identification_angle_coverage","validation_static_map","validation_angle_coverage"}
        assert(isfield(p,'static_waypoints')&&isnumeric(p.static_waypoints)&&isreal(p.static_waypoints)&& ...
            size(p.static_waypoints,2)==2&&size(p.static_waypoints,1)>=4&&all(isfinite(p.static_waypoints(:))), ...
            'pendulumlab:StaticMap','Provide finite [time_s, command] waypoints.');
        w=p.static_waypoints;
        assert(w(1,1)==0&&all(diff(w(:,1))>0)&&abs(w(end,1)-p.duration_s)<1e-9&& ...
            all(w(:,2)>=cfg.u_limits(1)&w(:,2)<=cfg.u_limits(2))&& ...
            w(1,2)==0&&all(w(end-1:end,2)==0)&&diff(w(end-1:end,1))>=20&& ...
            p.amplitude_command==0&&p.bias_command==max(w(:,2)), ...
            'pendulumlab:StaticMap','Static-map bounds/timing must match the protocol and leave at least 20 s at zero.');
        plannedSlew=p.command_slew_units_s;
        assert(isfinite(plannedSlew)&&plannedSlew>0&&plannedSlew<cfg.safety.max_slew_units_s&& ...
            max(abs(diff(w(:,2)))./diff(w(:,1)))<=plannedSlew+1e-10, ...
            'pendulumlab:PlannedSlew','Waypoint slopes must fit the planned slew with runtime headroom.');
        flat=find(diff(w(:,2))==0&w(1:end-1,2)>0);
        assert(~isempty(flat),'pendulumlab:StaticMap','At least one positive-command plateau is required.');
        t=(0:round(p.duration_s/Ts)-1)'*Ts;command=interp1(w(:,1),w(:,2),t,'linear');
        reference=zeros(size(t));injection=zeros(size(t));
    case "identification_ringdown"
        assert(isfield(p,'ramp_down_s')&&isnumeric(p.ramp_down_s)&&isscalar(p.ramp_down_s)&& ...
            isfinite(p.ramp_down_s)&&p.ramp_down_s>0,'pendulumlab:Ringdown','Set a positive ramp_down_s.');
        assert(all(isfinite([p.baseline_s p.ramp_s p.dwell_s p.duration_s p.bias_command]))&& ...
            p.baseline_s>=0&&p.ramp_s>0&&p.dwell_s>0&&p.bias_command>0&&p.amplitude_command==0, ...
            'pendulumlab:Ringdown','Ringdown requires positive rise/hold/command, a nonnegative baseline and zero random amplitude.');
        assert(cfg.u_limits(1)==0&&p.bias_command<=cfg.u_limits(2),'pendulumlab:Ringdown', ...
            'The ringdown protocol must allow zero and contain its plateau command.');
        release=p.baseline_s+p.ramp_s+p.dwell_s;
        zeroStart=release+p.ramp_down_s;
        assert(p.duration_s-zeroStart>=20,'pendulumlab:Ringdown','Allow at least 20 s at zero after the release ramp.');
        plannedSlew=p.command_slew_units_s;
        assert(isfinite(plannedSlew)&&plannedSlew>0&&plannedSlew<cfg.safety.max_slew_units_s&& ...
            max(p.bias_command./[p.ramp_s p.ramp_down_s])<=plannedSlew+1e-10, ...
            'pendulumlab:PlannedSlew','Rise and release slopes must fit the planned slew with runtime headroom.');
        t=(0:round(p.duration_s/Ts)-1)'*Ts;command=zeros(size(t));
        rise=t>=p.baseline_s&t<p.baseline_s+p.ramp_s;
        command(rise)=p.bias_command*(t(rise)-p.baseline_s)/p.ramp_s;
        hold=t>=p.baseline_s+p.ramp_s&t<release;command(hold)=p.bias_command;
        down=t>=release&t<zeroStart;
        command(down)=p.bias_command*(1-(t(down)-release)/p.ramp_down_s);
        reference=zeros(size(t));injection=zeros(size(t));
    case "reference_tracking"
        if isfield(p,'reference_waypoints')
            [t,reference]=reference_from_waypoints(p,cfg,Ts,'pendulumlab:ReferenceWaypoints');
        else
            levels=p.reference_levels_rad(:); dwell=p.plateau_s;
            n=max(1,round(dwell/Ts)); reference=repelem(levels,n);
            t=(0:numel(reference)-1)'*Ts;
        end
        injection=zeros(size(t));command=nan(size(t));
    case "injected_disturbance"
        offset=0;
        if isfield(p,'injection_time_offset_s')
            offset=p.injection_time_offset_s;
            assert(isnumeric(offset)&&isreal(offset)&&isscalar(offset)&&isfinite(offset)&&offset>=0, ...
                'pendulumlab:InjectionOffset','injection_time_offset_s must be finite and nonnegative.');
        end
        duration=offset+70;
        if isfield(p,'reference_waypoints')
            p.duration_s=duration;
            [t,reference]=reference_from_waypoints(p,cfg,Ts,'pendulumlab:ReferenceWaypoints');
        else
            t=(0:round(duration/Ts)-1)'*Ts;reference=repmat(pi/4,size(t));
        end
        injection=zeros(size(t));amp=p.injection_amplitude;
        injection(t>=offset+10&t<offset+20)=amp;injection(t>=offset+30&t<offset+40)=-amp;
        state=rng;guard=onCleanup(@()rng(state));rng(cfg.rng_seed,'twister');
        mask=t>=offset+50&t<offset+70;n=sum(mask);holdN=max(1,round(5/Ts));
        values=amp*(2*rand(ceil(n/holdN),1)-1);
        extended=repelem(values,holdN);injection(mask)=extended(1:n);
        clear guard
        if isfield(p,'injection_ramp_s')
            rampSeconds=p.injection_ramp_s;
            assert(isnumeric(rampSeconds)&&isscalar(rampSeconds)&&isfinite(rampSeconds)&&rampSeconds>=Ts&& ...
                abs(rampSeconds/Ts-round(rampSeconds/Ts))<1e-9,'pendulumlab:InjectionRamp', ...
                'Injection transition time must be a positive whole number of samples.');
            target=injection;steps=round(rampSeconds/Ts);startValue=0;startIndex=1;lastTarget=0;
            for k=1:numel(injection)
                if target(k)~=lastTarget
                    if k>1,startValue=injection(k-1);else,startValue=0;end
                    startIndex=k;lastTarget=target(k);
                end
                fraction=min(1,(k-startIndex+1)/steps);
                injection(k)=startValue+fraction*(lastTarget-startValue);
            end
        end
        command=nan(size(t));
    case {"identification_multilevel","identification_prbs","identification_multisine","validation_multilevel","validation_multisine"}
        n=max(2,round(p.duration_s/Ts));t=(0:n-1)'*Ts;
        assert(p.baseline_s>=0&&p.ramp_s>0&&p.baseline_s+p.ramp_s<p.duration_s, ...
            'pendulumlab:Schedule','Baseline/ramp must leave an excitation interval.');
        assert(p.bias_command-p.amplitude_command>=cfg.u_limits(1)&& ...
            p.bias_command+p.amplitude_command<=cfg.u_limits(2), ...
            'pendulumlab:ExcitationRange','Requested excitation exceeds command limits.');
        command=zeros(size(t));ramp=t>=p.baseline_s&t<p.baseline_s+p.ramp_s;
        command(ramp)=p.bias_command*(t(ramp)-p.baseline_s)/p.ramp_s;
        active=t>=p.baseline_s+p.ramp_s;ta=t(active)-p.baseline_s-p.ramp_s;
        stream=RandStream('mt19937ar','Seed',p.seed);
        if contains(name,'multisine')
            freq=p.multisine_hz(:);
            assert(all(isfinite(freq)&freq>0&freq<1/(2*Ts)),'pendulumlab:Frequency','Excitation frequencies must be positive and below Nyquist.');
            wave=zeros(size(ta));
            for k=1:numel(freq)
                % Seeded phases make independently scheduled validation
                % realizations distinct without changing the frequency set.
                phase=-pi*k*(k-1)/numel(freq)+2*pi*rand(stream);
                wave=wave+sin(2*pi*freq(k)*ta+phase);
            end
            wave=wave/max(max(abs(wave)),eps);
        else
            holdN=max(1,round(p.dwell_s/Ts));count=ceil(numel(ta)/holdN);
            if contains(name,'prbs')
                values=2*randi(stream,2,count,1)-3;
            else
                levels=[-1;-.5;0;.5;1];values=zeros(count,1);
                for k=1:5:count
                    perm=randperm(stream,5);nHere=min(5,count-k+1);
                    values(k:k+nHere-1)=levels(perm(1:nHere));
                end
            end
            wave=repelem(values,holdN);wave=wave(1:numel(ta));
        end
        command(active)=p.bias_command+p.amplitude_command*wave;
        % If configured, shape the planned excitation offline; never alter
        % feedback control to hide a runtime slew interlock.
        plannedSlew=cfg.safety.max_slew_units_s;
        if isfield(p,'command_slew_units_s')
            plannedSlew=p.command_slew_units_s;
            assert(isnumeric(plannedSlew)&&isreal(plannedSlew)&&isscalar(plannedSlew)&& ...
                isfinite(plannedSlew)&&plannedSlew>0,'pendulumlab:PlannedSlew','Planned excitation slew must be positive and finite.');
            if isfinite(cfg.safety.max_slew_units_s)
                assert(plannedSlew<cfg.safety.max_slew_units_s,'pendulumlab:PlannedSlew', ...
                    'Planned excitation slew must be below the approved runtime slew limit, with timing/quantization headroom.');
            end
        end
        if isfinite(plannedSlew)&&plannedSlew>0
            delta=plannedSlew*Ts;
            for k=2:n
                command(k)=command(k-1)+max(-delta,min(delta,command(k)-command(k-1)));
            end
        end
        reference=zeros(size(t));injection=zeros(size(t));
    otherwise
        error('pendulumlab:Protocol','Unsupported protocol %s',name);
end
schedule=struct('name',char(name),'role',cfg.phase,'seed',p.seed, ...
    'injection_seed',cfg.rng_seed,'duration_s',numel(t)*Ts, ...
    't',t,'reference',reference,'injection',injection,'command',command, ...
    'approved_physical_envelope',logical(p.operating_envelope_approved));
if startsWith(name,'identification_')||startsWith(name,'validation_')
    schedule.excitation=struct('bias_command',p.bias_command,'amplitude_command',p.amplitude_command, ...
        'baseline_s',p.baseline_s,'ramp_s',p.ramp_s,'dwell_s',p.dwell_s, ...
        'planned_slew_units_s',plannedSlew,'multisine_hz',p.multisine_hz);
    if name=="identification_ringdown"
        schedule.excitation.command_zero_start_s=zeroStart;
        schedule.excitation.ramp_down_s=p.ramp_down_s;
        schedule.excitation.interpretation='Command-zero ringdown; zero command is not independently verified zero thrust.';
    elseif any(name==["identification_static_map","identification_angle_coverage","validation_static_map","validation_angle_coverage"])
        schedule.excitation.waypoints=p.static_waypoints;
        schedule.excitation.plateau_ranges_s=[w(flat,1) w(flat+1,1)];
        schedule.excitation.plateau_commands=w(flat,2);
        schedule.excitation.command_zero_start_s=w(end-1,1);
        schedule.excitation.interpretation='Ascending/descending command-to-angle pilot; plateau stationarity requires assessment from measured data.';
        if any(name==["identification_angle_coverage","validation_angle_coverage"])
            pendulumlab.identification_return(cfg);
            schedule.return_policy=p.return_policy;
            schedule.excitation.interpretation='Planned excitation with latched angle/deadline-triggered zero return; actual transmitted command may differ from requested schedule.';
        end
    end
end
assert(all(isfinite(t))&&all(diff(t)>0),'pendulumlab:Time','Invalid schedule time.');
end

function [t,reference]=reference_from_waypoints(p,cfg,Ts,errorId)
w=p.reference_waypoints;
assert(isnumeric(w)&&isreal(w)&&ismatrix(w)&&size(w,2)==2&&size(w,1)>=2&&all(isfinite(w(:))), ...
    errorId,'reference_waypoints must be a finite real [time_s, angle_rad] matrix.');
assert(isfield(p,'duration_s')&&isnumeric(p.duration_s)&&isreal(p.duration_s)&&isscalar(p.duration_s)&& ...
    isfinite(p.duration_s)&&p.duration_s>0&&abs(p.duration_s/Ts-round(p.duration_s/Ts))<1e-9, ...
    errorId,'duration_s must be positive and sample aligned when reference_waypoints are used.');
assert(w(1,1)==0&&all(diff(w(:,1))>0)&&abs(w(end,1)-p.duration_s)<1e-9&& ...
    all(abs(w(:,2))<=pi),errorId, ...
    'Reference waypoints must start at zero, end at duration_s, increase strictly, and stay within [-pi,pi].');
n=round(p.duration_s/Ts);t=(0:n-1)'*Ts;
reference=interp1(w(:,1),w(:,2),t,'linear');
assert(all(isfinite(reference))&&all(abs(reference)<=pi),errorId,'Interpolated reference is invalid.');
end
