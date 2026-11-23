function out=run_identification_main(s,stopFcn)
%RUN_IDENTIFICATION_MAIN Scoped implementation of the editable main script.
% No hardware access in preview/mock. A label binds one immutable campaign;
% runtime operator/session identities are deliberately outside frozen config.
arguments
    s (1,1) struct
    stopFcn (1,1) function_handle = @() false
end
mode=string(s.mode);
assert(isscalar(mode)&&any(mode==["preview","mock","hardware"]), ...
    'pendulumlab:LauncherMode','Use preview, mock, or hardware mode.');
assert(~isempty(regexp(char(s.campaign_label),'^[A-Za-z0-9_-]+$','once')), ...
    'pendulumlab:LauncherLabel','campaign_label must use letters, digits, underscore or hyphen.');
for key={'arm_hardware','mechanical_ready','angle_zero_confirmed','excitation_approved', ...
        'operating_envelope_approved','show_figures','save_figures'}
    assert(islogical(s.(key{1}))&&isscalar(s.(key{1})), ...
        'pendulumlab:LauncherSetting','%s must be scalar true or false.',key{1});
end
cfg=make_config(s,mode);
out=struct('state','preview','mode',char(mode),'config',cfg,'campaign_folder','', ...
    'manifest_path','','report',struct(),'status',struct(),'record_files',{{}});
protected=pendulumlab.verify_protected();
assert(protected.passed,'pendulumlab:Protected','Protected project files changed; inspect before acquisition.');

if ~isempty(cfg.campaign.identification_bias_commands)
    assert(isnumeric(s.bias_commands)&&numel(s.bias_commands)==5&&all(isfinite(s.bias_commands(:))), ...
        'pendulumlab:StageBias','bias_commands must be empty or contain five finite values.');
end
% Check every proposed stage before creating any campaign files.
stages=pendulumlab.identification_stages(cfg);
previewSchedules=cell(5,1);
for k=1:5
    previewCfg=cfg;previewCfg.experiment_id=stages(k).experiment_id;previewCfg.protocol=stages(k).protocol;
    previewCfg.rng_seed=cfg.rng_seed+k;
    previewSchedule=pendulumlab.make_schedule(previewCfg);
    previewSchedules{k}=previewSchedule;
    if k==1,firstSchedule=previewSchedule;end
end
out.readiness=pendulumlab.validate_config(cfg);
if mode=="preview"
    fprintf('PREVIEW ONLY: five planned inputs and nominal responses; no UART or files.\n');
    fprintf('Five recordings: multilevel x3, PRBS, multisine; %.3g s each.\n',cfg.protocol.duration_s);
    [out.preview,out.preview_figure]=pendulumlab.identification_preview(cfg,previewSchedules,s.show_figures);
    for k=1:numel(out.preview.cases)
        c=out.preview.cases(k);
        fprintf(' %d. %s | seed %d | predicted peak %.3f deg\n',k,c.protocol,c.seed,c.peak_abs_angle_deg);
    end
    fprintf('%s\n',out.preview.model_note);
    if ~out.readiness.valid
        fprintf('Hardware/configuration checks still required:\n - %s\n',strjoin(out.readiness.issues,'\n - '));
    end
    return
end
assert(out.readiness.valid,'pendulumlab:LauncherConfig','%s',strjoin(out.readiness.issues,'; '));
if mode=="hardware"
    assert(isnumeric(s.recovery_s)&&isscalar(s.recovery_s)&&isfinite(s.recovery_s)&&s.recovery_s>0, ...
        'pendulumlab:LauncherRecovery','Set a reviewed positive recovery_s.');
    assert(strlength(strtrim(string(s.operator_id)))>0&&strlength(strtrim(string(s.session_id)))>0, ...
        'pendulumlab:LauncherOperator','Provide the actual operator_id and session_id.');
    assert(cfg.safety.max_duration_s>=cfg.protocol.duration_s+cfg.safety.rest_samples*cfg.Ts, ...
        'pendulumlab:LauncherDuration','max_run_time_s must allow the waveform plus initial rest.');
end
assert(cfg.safety.max_device_gap_s<=1.5*cfg.Ts+10*eps(cfg.Ts), ...
    'pendulumlab:LauncherTiming','max_device_gap_s cannot exceed 1.5 sample periods.');
fingerprint=pendulumlab.json_value_sha256(cfg);
pointerFolder=fullfile(cfg.output_dir,'identification_campaigns');
pointerPath=fullfile(pointerFolder,[char(s.campaign_label) '.json']);
if isfile(pointerPath)
    pointer=jsondecode(fileread(pointerPath));
    assert(strcmp(pointer.schema_version,'pendulumlab.identification_launcher/1')&& ...
        strcmp(pointer.mode,char(mode))&&strcmp(pointer.campaign_label,char(s.campaign_label)), ...
        'pendulumlab:LauncherPointer','Saved campaign pointer does not match this launcher.');
    assert(strcmp(pointer.config_sha256,fingerprint),'pendulumlab:LauncherChanged', ...
        'Settings changed under campaign_label %s. Restore them to resume, or use a new label for the revised protocol.',s.campaign_label);
    manifestPath=char(pointer.manifest_path);
    assert(isfile(manifestPath),'pendulumlab:LauncherMissing', ...
        'The saved campaign is missing. Restore it or choose a new campaign_label; no replacement was created.');
    assert(isfield(pointer,'manifest_sha256')&&strcmp(pendulumlab.file_hash(manifestPath),pointer.manifest_sha256), ...
        'pendulumlab:LauncherPointer','The campaign manifest differs from the saved label pointer.');
else
    plan=pendulumlab.prepare_campaign(cfg,'identification');
    first=load(fullfile(plan.campaign_folder,plan.runs(1).schedule_file),'schedule');
    assert(strcmp(pendulumlab.schedule_identity_sha256(first.schedule), ...
        pendulumlab.schedule_identity_sha256(firstSchedule)), ...
        'pendulumlab:LauncherPreview','The prepared first schedule differs from the preview.');
    manifestPath=plan.manifest_path;
    pointer=struct('schema_version','pendulumlab.identification_launcher/1', ...
        'campaign_label',char(s.campaign_label),'mode',char(mode), ...
        'config_sha256',fingerprint,'manifest_path',manifestPath,'manifest_sha256',plan.manifest_sha256);
    write_pointer(pointerPath,pointer);
end
out.manifest_path=manifestPath;out.campaign_folder=fileparts(manifestPath);
before=pendulumlab.campaign_status(string(manifestPath));
fprintf('%s identification: %d/%d completed.\n',upper(char(mode)),before.completed,before.planned);
fprintf('Campaign: %s\nData: %s\n',manifestPath,fullfile(out.campaign_folder,'runs'));
if before.completed==before.planned
    out.state='completed';out.status=before;
    fprintf('Campaign already complete; no recording repeated.\n');return
end
arm=struct();
if mode=="hardware"
    arm=struct('HardwareArmed',s.arm_hardware,'operator_id',char(s.operator_id), ...
        'session_id',char(s.session_id),'arm_id',['arm_' char(java.util.UUID.randomUUID)], ...
        'confirmed_utc',char(datetime('now','TimeZone','UTC','Format',"yyyy-MM-dd'T'HH:mm:ss.SSSXXX")));
end
out.report=pendulumlab.run_campaign(string(manifestPath),arm,stopFcn);
out.status=pendulumlab.campaign_status(string(manifestPath));
out.state='held';if out.status.completed==out.status.planned,out.state='completed';
elseif out.status.completed>before.completed,out.state='recorded';end
fprintf('%d/%d completed; %d pending.\n',out.status.completed,out.status.planned,out.status.pending);
if ~isempty(out.report.pause_reason),fprintf('%s\n',out.report.pause_reason);end
changed=find(before.code~=out.status.code);
for k=reshape(changed,1,[])
    path=fullfile(out.campaign_folder,'runs',[char(out.status.run_id(k)) '.mat']);
    if ~isfile(path),continue,end
    out.record_files{end+1}=path;
    if s.show_figures||s.save_figures
        try
            plot_record(path,out.campaign_folder,s);
        catch err
            warning('pendulumlab:IdentificationPlot','Raw data saved; figure generation failed: %s',err.message);
        end
    end
end
if mode=="hardware"&&out.status.pending>0
    fprintf('Inspect this result and wait the recovery interval. Press Run again with the same campaign_label for the next recording.\n');
end
end

function cfg=make_config(s,mode)
cfg=pendulumlab.default_config('identification');
cfg.mode='hardware';if mode=="mock",cfg.mode='mock';end
cfg.theta=double(s.theta_initial(:).');cfg.hardware_id='replacement_propeller_01';
if ~isequal(cfg.theta,[49.3401 0.4569 0.5586])
    cfg.model_id='user_identification_initial_guess';cfg.model_status='initial_guess';
    cfg.model_hardware_id='unvalidated_initial_guess';
end
cfg.u_limits=s.command_limits;cfg.session_id='';
cfg.protocol.duration_s=s.duration_s;cfg.protocol.bias_command=s.bias_command;
cfg.protocol.amplitude_command=s.amplitude_command;cfg.protocol.baseline_s=s.baseline_s;
cfg.protocol.ramp_s=s.ramp_s;cfg.protocol.dwell_s=s.dwell_s;
cfg.protocol.multisine_hz=s.multisine_hz;cfg.protocol.seed=s.excitation_seed;
cfg.campaign.identification_bias_commands=s.bias_commands;
if isfield(s,'stage_settings')&&~isempty(s.stage_settings)
    m=s.stage_settings;
    assert(isnumeric(m)&&isreal(m)&&isequal(size(m),[5 5])&&all(isfinite(m(:)))&&all(m(:)>=0), ...
        'pendulumlab:StageProfile','stage_settings must be a finite nonnegative 5-by-5 matrix.');
    assert(isempty(s.bias_commands),'pendulumlab:StageProfile', ...
        'Use stage_settings or bias_commands, not both.');
    names={'identification_multilevel','identification_prbs','identification_multilevel', ...
        'identification_multilevel','identification_multisine'};
    for k=1:5
        cfg.campaign.identification_profiles(k)=struct('experiment_id',names{k}, ...
            'bias_command',m(k,1),'amplitude_command',m(k,2),'ramp_s',m(k,3), ...
            'dwell_s',m(k,4),'command_slew_units_s',m(k,5));
    end
end
cfg.campaign.label=char(s.campaign_label);
cfg.campaign.intertrial_recovery_s=s.recovery_s;
cfg.safety.max_abs_angle_rad=deg2rad(s.max_abs_angle_deg);
cfg.safety.max_slew_units_s=s.max_slew_units_s;cfg.safety.max_duration_s=s.max_run_time_s;
cfg.safety.max_device_gap_s=s.max_device_gap_s;cfg.safety.max_host_cycle_s=s.max_host_cycle_s;
cfg.safety.rest_samples=s.rest_samples;cfg.safety.rest_range_rad=deg2rad(s.rest_range_deg);
cfg.safety.rest_slope_rad_s=deg2rad(s.rest_slope_deg_s);cfg.checkpoint_samples=s.checkpoint_samples;
cfg.hardware.COM_port=s.com_port;cfg.hardware.read_timeout_ms=s.read_timeout_ms;
cfg.hardware.write_timeout_ms=s.write_timeout_ms;
cfg.hardware.enabled=s.arm_hardware;cfg.hardware.operator_armed=s.arm_hardware;
cfg.hardware.mechanical_ready=s.mechanical_ready;cfg.hardware.angle_zero_confirmed=s.angle_zero_confirmed;
cfg.protocol.operator_excitation_approved=s.excitation_approved;
cfg.protocol.operating_envelope_approved=s.operating_envelope_approved;
cfg.output_dir=fullfile(pendulumlab.project_root(),'experiment_data','campaign_v2');
if mode=="mock"
    cfg.hardware_id='synthetic_model';cfg.mock.theta=cfg.theta;cfg.session_id='synthetic_identification';
    cfg.output_dir=fullfile(pendulumlab.project_root(),'experiment_framework','verification','synthetic_runs');
    if strlength(string(s.mock_output_dir))>0,cfg.output_dir=char(s.mock_output_dir);end
end
end

function write_pointer(path,pointer)
folder=fileparts(path);if ~isfolder(folder),mkdir(folder);end
temp=[tempname(folder) '.json'];fid=fopen(temp,'wt');
assert(fid>=0,'pendulumlab:LauncherSave','Cannot save campaign pointer.');
guard=onCleanup(@()fclose(fid));fprintf(fid,'%s',jsonencode(pointer,PrettyPrint=true));clear guard
assert(~isfile(path),'pendulumlab:LauncherPointer','Campaign label was created concurrently; refusing replacement.');
[ok,msg]=movefile(temp,path);assert(ok,'pendulumlab:LauncherSave','Cannot commit campaign pointer: %s',msg);
end

function plot_record(path,folder,s)
loaded=load(path,'result');r=loaded.result;
f=figure('Name',r.metadata.run_id,'Visible','off');
setappdata(f,'pendulumlabKeepFigure',false);
guard=onCleanup(@()cleanup_figure(f));
tiledlayout(f,2,1,'TileSpacing','compact');
ax=nexttile;plot(ax,r.signals.t,r.signals.angle);grid(ax,'on');
ylabel(ax,'$y$ [rad]','Interpreter','latex');
title(ax,sprintf('%s | %s | %s',r.recording_kind,r.metadata.experiment_id,r.status.code),'Interpreter','none');
ax=nexttile;stairs(ax,r.signals.t,r.signals.u_command);grid(ax,'on');
xlabel(ax,'$t$ [s]','Interpreter','latex');ylabel(ax,'$u_{\mathrm{cmd}}$ [command units]','Interpreter','latex');
if s.save_figures
    figures=fullfile(folder,'figures');if ~isfolder(figures),mkdir(figures);end
    base=fullfile(figures,r.metadata.run_id);
    assert(~isfile([base '.fig'])&&~isfile([base '.eps']),'pendulumlab:LauncherFigure','Figure files already exist.');
    savefig(f,[base '.fig']);exportgraphics(f,[base '.eps'],'ContentType','vector');
end
if s.show_figures
    set(f,'Visible',get(groot,'defaultFigureVisible'));
    setappdata(f,'pendulumlabKeepFigure',true);
end
clear guard
end

function cleanup_figure(f)
if isgraphics(f)&&~getappdata(f,'pendulumlabKeepFigure'),close(f);end
end
