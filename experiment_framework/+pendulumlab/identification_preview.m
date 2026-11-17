function [preview,f]=identification_preview(cfg,schedules,showFigure)
%IDENTIFICATION_PREVIEW Nominal free-run predictions; no link or file access.
arguments
    cfg (1,1) struct
    schedules (:,1) cell
    showFigure (1,1) logical = false
end
theta=double(cfg.theta(:).');x0=[0;0];substeps=cfg.integration_substeps;
cases=cell(numel(schedules),1);
for k=1:numel(schedules)
    s=schedules{k};u=double(single(s.command));
    y=pendulumlab.simulate_output(theta,s.t,u,x0,substeps);
    refined=pendulumlab.simulate_output(theta,s.t,u,x0,2*substeps);
    p=s.excitation;active=s.t>=p.baseline_s+p.ramp_s;degrees=rad2deg(y);
    nearSeconds=sum(active & abs(degrees-[30 45 60])<=5,1)*cfg.Ts;
    deviation=u(active)-mean(u(active));n=numel(deviation);
    power=abs(fft(deviation)).^2;frequency=(0:n-1)'/(n*cfg.Ts);
    bandPower=sum(power(frequency>=.4&frequency<=1.6))/max(sum(power(frequency>0&frequency<=1/(2*cfg.Ts))),realmin);
    centre=NaN;ratio=theta(3)*p.bias_command/theta(1);
    if abs(ratio)<=1,centre=asind(ratio);end
    cases{k}=struct('index',k,'protocol',s.name,'seed',s.seed, ...
        'schedule_identity_sha256',pendulumlab.schedule_identity_sha256(s), ...
        't',s.t,'command',u,'angle_rad',y,'duration_s',s.duration_s, ...
        'bias_command',p.bias_command,'amplitude_command',p.amplitude_command, ...
        'baseline_s',p.baseline_s,'ramp_s',p.ramp_s,'dwell_s',p.dwell_s, ...
        'planned_slew_units_s',p.planned_slew_units_s,'nominal_centre_deg',centre, ...
        'active_start_s',p.baseline_s+p.ramp_s,'near_30_45_60_deg_seconds',nearSeconds, ...
        'operating_point_tolerance_deg',5,'input_power_fraction_04_to_16_hz',bandPower, ...
        'command_min',min(u),'command_max',max(u), ...
        'command_slew_peak_units_s',max(abs(diff(u)))/cfg.Ts, ...
        'angle_min_deg',rad2deg(min(y)),'angle_max_deg',rad2deg(max(y)), ...
        'peak_abs_angle_deg',rad2deg(max(abs(y))), ...
        'planning_angle_ceiling_deg',90,'samples_at_or_above_90_deg',sum(abs(degrees)>=90), ...
        'min_secant_speed_deg_s',min(diff(degrees)/cfg.Ts), ...
        'max_secant_speed_deg_s',max(diff(degrees)/cfg.Ts), ...
        'active_angle_min_deg',min(degrees(active)),'active_angle_max_deg',max(degrees(active)), ...
        'integration_refinement_max_abs_rad',max(abs(y-refined)));
end
preview=struct('schema_version','pendulumlab.identification_preview/1', ...
    'recording_kind','synthetic','theta',theta,'initial_state',x0, ...
    'sample_period_s',cfg.Ts,'integration_substeps',substeps, ...
    'slew_limit_units_s',cfg.safety.max_slew_units_s,'cases',vertcat(cases{:}), ...
    'model_note',['Historical command-domain model; initial rest and zero disturbance. ', ...
    'The selected 10-to-180 actuator mapping has not been recalibrated in this model. ', ...
    'No actuator lag, sensor noise, timing faults or hardware interlocks are simulated. ', ...
    'These predictions do not establish physical readiness or model validation.']);
f=gobjects(0);
if ~showFigure,return,end
f=figure('Name','Identification plan: nominal simulation', ...
    'Tag','pendulum_identification_preview','Color','w','Visible','off', ...
    'Units','pixels','Position',[80 40 1440 1380]);
layout=tiledlayout(f,numel(cases),2,'TileSpacing','compact','Padding','compact');
title(layout,'Planned identification experiments: nominal simulation', ...
    'FontSize',16,'FontWeight','bold','Interpreter','none');
plannedRates=[preview.cases.planned_slew_units_s];
if all(isfinite(plannedRates))
    slewNote=sprintf('Planned per-run slew limits: %s command units/s',mat2str(plannedRates,4));
else
    slewNote='Slew limit unset: unshaped input steps';
end
subtitle(layout,{sprintf('Historical theta = [%.4f, %.4f, %.4f]; Ts = %.2f s; initial rest; w = 0',theta,cfg.Ts), ...
    [slewNote '. Real response under the 10-to-180 mapping remains to be measured.']}, ...
    'FontSize',11,'Interpreter','none');
angleMin=min([0 preview.cases.angle_min_deg]);angleMax=max([95 preview.cases.angle_max_deg]);
angleLimits=[5*floor(angleMin/5) 5*ceil(angleMax/5)];
commandMin=min([0 preview.cases.command_min]);commandMax=max([1 preview.cases.command_max]);
commandLimits=[commandMin-1 commandMax+2];
axesList=gobjects(2*numel(cases),1);
for k=1:numel(cases)
    c=preview.cases(k);label='Multilevel';
    if contains(c.protocol,'prbs'),label='Rate-limited PRBS';end
    if contains(c.protocol,'multisine'),label='Multisine';end
    ax=nexttile(layout);axesList(2*k-1)=ax;
    stairs(ax,c.t,c.command,'Color',[.08 .34 .63],'LineWidth',1.1);
    title(ax,sprintf('%d. %s | bias %.1f, amplitude %.1f | seed %d',k,label,c.bias_command,c.amplitude_command,c.seed),'Interpreter','none');
    ylabel(ax,'$u_{\mathrm{cmd}}$ [command units]','Interpreter','latex');
    ylim(ax,commandLimits);
    decorate(ax,c.duration_s,c);
    ax=nexttile(layout);axesList(2*k)=ax;
    plot(ax,c.t,rad2deg(c.angle_rad),'Color',[.82 .29 .10],'LineWidth',1);
    title(ax,sprintf('%d. Nominal response | peak %.1f deg',k,c.peak_abs_angle_deg),'Interpreter','none');
    ylabel(ax,'$y$ [deg]','Interpreter','latex');ylim(ax,angleLimits);
    yline(ax,45,'--','45 deg','Color',[.5 .5 .5],'FontSize',9,'HandleVisibility','off');
    yline(ax,60,'--','60 deg','Color',[.5 .5 .5],'FontSize',9,'HandleVisibility','off');
    yline(ax,90,':','90 deg planning ceiling','Color',[.65 .2 .2],'FontSize',9,'HandleVisibility','off');
    decorate(ax,c.duration_s,c);
end
linkaxes(axesList,'x');
set(f,'Visible',get(groot,'defaultFigureVisible'));
end
function decorate(ax,duration,p)
grid(ax,'on');ax.FontSize=10;ax.Box='on';
xlim(ax,[0 duration]);xlabel(ax,'$t$ [s]','Interpreter','latex');
xline(ax,p.baseline_s,':','Color',[.55 .55 .55],'HandleVisibility','off');
xline(ax,p.baseline_s+p.ramp_s,':','Color',[.55 .55 .55],'HandleVisibility','off');
end
