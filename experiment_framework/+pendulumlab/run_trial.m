function result=run_trial(cfg,schedule,runtimeArm,stopFcn)
%RUN_TRIAL Execute one bounded trial through mock, replay, or gated hardware.
% Hardware is constructed only after offline config validation and explicit
% gate checks. Function-scope cleanup requests best-effort zero, closes, and
% atomically saves partial measurements on exceptions/interruption.
arguments
    cfg (1,1) struct
    schedule (1,1) struct
    runtimeArm (1,1) struct = struct()
    stopFcn (1,1) function_handle = @() false
end
n=0; target=''; checkpointTarget=''; allowSave=true; finalized=false; link=[]; hostClock=[];
writeAttempts=0; readAttempts=0; readSuccesses=0; restReads=0; trialReads=0;
commandWrites=0; stopRequested=false;
checkpointWriter=[];
result=empty_result(cfg,schedule);
report=pendulumlab.validate_config(cfg);
blockReason='';
if ~isfield(report,'valid')||~report.valid|| ...
        (isfield(report,'output_allowed')&&~report.output_allowed)
    blockReason=issues_text(report);
    if isfield(report,'output_allowed')&&~report.output_allowed
        blockReason='Configuration output location is blocked; no result file was written.';
        allowSave=false;
    end
elseif string(cfg.mode)=="hardware"
    [hardwareOK,blockReason]=physical_preflight(cfg,runtimeArm);
end
if ~isempty(blockReason)
    result.status.code='blocked'; result.status.reason=issues_text(report);
    result.status.reason=blockReason;
    result.status.link_closed=true;
    if allowSave, allowSave=prepare_save_target(); end
    if allowSave, save_result(); end
    return
end
try
    [schedule,n]=validate_schedule(schedule,cfg);
    excitationReturn=pendulumlab.identification_return(cfg);
    result=empty_result(cfg,schedule);
    result.metadata.excitation_return=excitationReturn;
    if string(cfg.mode)=="hardware"
        result.metadata.runtime_arm=struct('operator_id',char(runtimeArm.operator_id), ...
            'confirmed_utc',char(runtimeArm.confirmed_utc),'arm_id',char(runtimeArm.arm_id), ...
            'session_id',char(runtimeArm.session_id),'source_sha256',runtimeArm.source_sha256);
        result.metadata.session_id=char(runtimeArm.session_id);
    end
    target=run_path(cfg);
    checkpointTarget=fullfile(fileparts(target),[char(cfg.run_id) '.checkpoint.mat']);
    allowSave=~isfile(target);
    if ~allowSave
        result.status.code='blocked'; result.status.reason='Stable run_id already has a saved record; refusing overwrite or implicit retry.';
        result.status.link_closed=true; return
    end
catch err
    result.status.code='blocked'; result.status.reason=err.message;
    result.status.exception=exception_text(err); result.status.link_closed=true;
    allowSave=prepare_save_target(); if allowSave, save_result(); end
    return
end

result.status.code='aborted';
result.status.reason='Run ended before completion; cleanup saved partial state.';
result.signals=preallocate_signals(n,schedule);
result.metadata.planned_sample_count=n;
result.metadata.initialization=struct('rest_angle_rad',zeros(0,1), ...
    'rest_t_device_raw',zeros(0,1),'rest_t_host',zeros(0,1), ...
    'rest_range_rad',NaN,'rest_slope_rad_s',NaN,'rest_passed',false);
cleanupGuard=onCleanup(@finalize_run); %#ok<NASGU>
try
    if string(cfg.mode)=="hardware"||isequal(getfield_default(cfg,'async_checkpoint',false),true)
        checkpointWriter=pendulumlab.AsyncCheckpoint(checkpointTarget,result);
        result.metadata.checkpoint_mode='asynchronous_background';
        result.metadata.checkpoint_writer_warmup_s=checkpointWriter.WarmupSeconds;
    else
        result.metadata.checkpoint_mode='synchronous_offline';
    end
    % The absolute 180-degree trip cannot be disabled. A reviewed lower
    % limit takes precedence; NaN in offline fixtures retains this ceiling.
    angleLimit=pi;
    if isfinite(cfg.safety.max_abs_angle_rad)
        angleLimit=min(angleLimit,double(cfg.safety.max_abs_angle_rad));
    end
    hostClock=tic;
    switch string(cfg.mode)
        case "mock"
            link=pendulumlab.MockLink(cfg,schedule);
        case "replay"
            link=pendulumlab.ReplayLink(cfg);
        case "hardware"
            if ~report.hardware_allowed||~hardware_gate_complete(cfg)
                result.status.code='blocked'; result.status.reason='Physical hardware gates are incomplete.';
                clear cleanupGuard; return
            end
            [used,receiptReason]=consume_arm_id(cfg,runtimeArm);
            if ~used
                result.status.code='blocked'; result.status.reason=receiptReason;
                clear cleanupGuard; return
            end
            % This constructor is unreachable in mock/replay and is never
            % invoked by preparation, validation, campaign freezing, or tests.
            link=uartlink.Connection(double(cfg.hardware.COM_port), ...
                double(cfg.hardware.baudrate), ...
                ReadTimeoutMs=double(cfg.hardware.read_timeout_ms), ...
                WriteTimeoutMs=double(cfg.hardware.write_timeout_ms));
        otherwise
            error('pendulumlab:Mode','Unsupported run mode.');
    end
    stream=double(cfg.hardware.stream_id);
    restN=max(2,round(double(cfg.safety.rest_samples)));
    restAngle=nan(restN,1); restRaw=nan(restN,1); restHost=nan(restN,1);
    result.metadata.initialization=struct('rest_angle_rad',restAngle, ...
        'rest_t_device_raw',restRaw,'rest_t_host',restHost, ...
        'rest_range_rad',NaN,'rest_slope_rad_s',NaN,'rest_passed',false, ...
        'sensor_health_limitation','Constant finite encoder readings with advancing device time are not independently diagnosed as sensor failure.');
    restClock=tic; lastRestRaw=NaN; previousRestStart=NaN; previousWriteHost=NaN;
    for k=1:restN
        if stopFcn(), error('pendulumlab:OperatorAbort','Stop callback requested cancellation during rest preflight.'); end
        if toc(hostClock)>double(cfg.safety.max_duration_s)
            error('pendulumlab:Interlock','Configured maximum duration exceeded during rest preflight.');
        end
        restStart=toc(hostClock);
        readAttempts=readAttempts+1;
        [rawAngle,rawTime]=link.read(stream,1);
        readSuccesses=readSuccesses+1; restReads=restReads+1;
        restAngle(k)=deg2rad(double(rawAngle));
        restRaw(k)=double(rawTime); restHost(k)=toc(restClock);
        result.metadata.initialization.rest_angle_rad(k)=restAngle(k);
        result.metadata.initialization.rest_t_device_raw(k)=restRaw(k);
        result.metadata.initialization.rest_t_host(k)=restHost(k);
        if ~isfinite(restAngle(k))||~isfinite(restRaw(k))
            error('pendulumlab:Interlock','Rest measurement is nonfinite.');
        end
        if isfinite(previousRestStart)&&isfinite(cfg.safety.max_host_cycle_s)&& ...
                restStart-previousRestStart>cfg.safety.max_host_cycle_s
            error('pendulumlab:Interlock','Rest-preflight host cycle exceeded the configured maximum.');
        end
        previousRestStart=restStart;
        if abs(restAngle(k))>=angleLimit
            error('pendulumlab:Interlock','Rest-preflight angle reached or exceeded the %.6g-degree absolute-angle limit.',rad2deg(angleLimit));
        end
        if toc(hostClock)-restStart>double(cfg.safety.max_host_cycle_s)
            error('pendulumlab:Interlock','Rest measurement transaction exceeded configured host-cycle maximum.');
        end
        if isfinite(lastRestRaw)
            dt=restRaw(k)-lastRestRaw;
            if dt<=0||dt>double(cfg.safety.max_device_gap_s)
                error('pendulumlab:Interlock','Rest device timestamp is duplicate, reversed, or beyond the configured gap.');
            end
        end
        lastRestRaw=restRaw(k);
        restWriteStart=toc(hostClock);
        writeAttempts=writeAttempts+1;
        link.write(stream,single(0));
        previousWriteHost=restWriteStart;
    end
    restRange=max(restAngle)-min(restAngle);
    restSlope=abs(polyfit(restRaw-restRaw(1),restAngle,1)); restSlope=restSlope(1);
    result.metadata.initialization.rest_range_rad=restRange;
    result.metadata.initialization.rest_slope_rad_s=restSlope;
    result.metadata.initialization.rest_passed=restRange<=cfg.safety.rest_range_rad && ...
        restSlope<=cfg.safety.rest_slope_rad_s;
    if ~result.metadata.initialization.rest_passed
        error('pendulumlab:Interlock','Initial rest range or slope exceeds the configured gate.');
    end
    y0=mean(restAngle(max(1,end-4):end));
    theta=double(cfg.theta(:)); gamma=theta(3); beta=theta(2); T=double(cfg.T);
    calibrated=pendulumlab.actuator_coordinates(cfg,'enabled');
    modelLimits=pendulumlab.actuator_coordinates(cfg,'limits');
    % The source experiment assumes zero initial angular velocity after the
    % rest gate; this is an assumption, not a measured velocity.
    z=[beta*y0/gamma; -y0/(gamma*T^2)];
    previousRaw=restRaw(end); previousReadHost=previousRestStart;
    previousCommand=0; firstRaw=NaN; lastHostCycle=NaN;
    injectionFilter=[0;0];
    for i=1:n
        if stopFcn(), error('pendulumlab:OperatorAbort','Stop callback requested cancellation.'); end
        if ~isempty(checkpointWriter),checkpointWriter.poll();end
        if toc(hostClock)>double(cfg.safety.max_duration_s)
            error('pendulumlab:Interlock','Configured maximum trial duration exceeded.');
        end
        tReadStart=toc(hostClock); result.signals.read_start_host(i)=tReadStart;
        result.signals.read_attempted(i)=true;
        readAttempts=readAttempts+1;
        [rawAngle,rawTime]=link.read(stream,1);
        tReadEnd=toc(hostClock); result.signals.read_end_host(i)=tReadEnd;
        result.signals.t_host(i)=tReadEnd;
        result.signals.t_device_raw(i)=double(rawTime);
        result.signals.angle(i)=deg2rad(double(rawAngle));
        readSuccesses=readSuccesses+1; trialReads=trialReads+1;
        result.signals.read_valid(i)=isfinite(result.signals.angle(i)) && isfinite(result.signals.t_device_raw(i));
        if ~result.signals.read_valid(i)
            error('pendulumlab:Interlock','Nonfinite angle or device timestamp; no command sent for this sample.');
        end
        if isfinite(cfg.safety.max_host_cycle_s)&&tReadEnd-tReadStart>cfg.safety.max_host_cycle_s
            error('pendulumlab:Interlock','Current read transaction exceeded configured host-cycle maximum; no command was sent.');
        end
        deviceDelta=result.signals.t_device_raw(i)-previousRaw;
        if deviceDelta<=0
            error('pendulumlab:Interlock','Device timestamp is duplicate or reversed; no catch-up sample is fabricated.');
        end
        if deviceDelta>double(cfg.safety.max_device_gap_s)
            error('pendulumlab:Interlock','Device timestamp gap exceeds configured maximum.');
        end
        if ~isfinite(firstRaw)
            firstRaw=result.signals.t_device_raw(i); result.signals.t_device(i)=0;
        else
            result.signals.t_device(i)=result.signals.t_device_raw(i)-firstRaw;
        end
        if isfinite(previousReadHost)
            cycle=tReadStart-previousReadHost;
            if isfinite(cfg.safety.max_host_cycle_s)&&cycle>cfg.safety.max_host_cycle_s
                error('pendulumlab:Interlock','Host read cycle exceeded configured maximum; no synthetic catch-up sample is inserted.');
            end
            lastHostCycle=cycle;
        end
        previousRaw=result.signals.t_device_raw(i); previousReadHost=tReadStart;
        y=result.signals.angle(i);
        if abs(y)>=angleLimit
            error('pendulumlab:Interlock','Measured angle reached or exceeded the %.6g-degree absolute-angle limit.',rad2deg(angleLimit));
        end
        returnTransition=false;
        if excitationReturn.enabled
            [excitationReturn,returnTransition]=pendulumlab.identification_return(excitationReturn,y,double(schedule.t(i)),i);
            if returnTransition
                excitationReturn.trigger_device_s=result.signals.t_device(i);
                excitationReturn.trigger_host_s=tReadEnd;
            end
            result.metadata.excitation_return=excitationReturn;
            result.signals.excitation_return_latched(i)=excitationReturn.latched;
        end
        if string(cfg.mode)=="hardware"&&any(string(cfg.phase)==["pilot","confirmatory"])
            domain=cfg.model_record.approval.validated_angle_range_rad;
            if y<domain(1)||y>domain(2)
                error('pendulumlab:Interlock','Measured angle left the accepted empirical model-use domain.');
            end
        end
        v=double(schedule.reference(i)); injection=double(schedule.injection(i));
        if isfinite(v), result.signals.error(i)=v-y; end
        what=pendulumlab.observer_output(z,y,theta,T);
        if ~isfinite(double(what))||any(~isfinite(z))
            error('pendulumlab:Interlock','Observer output or state is nonfinite.');
        end
        result.signals.observer_z1_pre(i)=z(1);
        result.signals.observer_z2_pre(i)=z(2);
        result.signals.w_hat(i)=double(what);
        if isfinite(schedule.command(i))
            % Open-loop identification/validation: full transmitted input is
            % retained as u_command, with no feedback-controller claim.
            rawControl=double(schedule.command(i)); uC=NaN;
            result.signals.u_excitation_requested(i)=rawControl;
            if excitationReturn.enabled&&excitationReturn.latched,rawControl=0;end
        else
            uC=(theta(1)*sin(y)-double(cfg.a)*y+double(cfg.a)*v)/gamma;
            rawControl=uC-double(logical(cfg.use_compensation))*double(what);
        end
        if ~isfinite(rawControl)||(~isfinite(uC)&&~isnan(uC))
            error('pendulumlab:Interlock','Raw controller/open-loop command is nonfinite.');
        end
        result.signals.u_C(i)=uC;
        result.signals.u_control_raw(i)=rawControl;
        lo=double(cfg.u_limits(1)); hi=double(cfg.u_limits(2));
        if calibrated
            if isfinite(schedule.command(i))
                % Open-loop schedules remain raw motor commands. Conversion
                % affects the known observer input, never the frozen waveform.
                qNomRequested=min(max(rawControl,lo),hi);qNom=double(single(qNomRequested));
                uNom=pendulumlab.actuator_coordinates(cfg,'forward',qNom);uNomClipped=uNom;
                uCmdRequested=qNomRequested;uCmdPayload=qNom;
                saturated=rawControl<lo||rawControl>hi;
            else
                % Feedback/injection are in the calibrated model coordinate.
                uNomClipped=min(max(rawControl,modelLimits(1)),modelLimits(2));
                qNomRequested=pendulumlab.actuator_coordinates(cfg,'inverse',uNomClipped);
                qNom=double(single(min(max(qNomRequested,lo),hi)));
                uNom=pendulumlab.actuator_coordinates(cfg,'forward',qNom);
                totalModel=min(max(uNom+injection,modelLimits(1)),modelLimits(2));
                if injection==0
                    uCmdRequested=qNomRequested;uCmdPayload=qNom;
                else
                    uCmdRequested=pendulumlab.actuator_coordinates(cfg,'inverse',totalModel);
                    uCmdPayload=double(single(min(max(uCmdRequested,lo),hi)));
                end
                saturated=rawControl<modelLimits(1)||rawControl>modelLimits(2)|| ...
                    uNom+injection<modelLimits(1)||uNom+injection>modelLimits(2);
            end
            modelPayload=pendulumlab.actuator_coordinates(cfg,'forward',uCmdPayload);
        else
            uNomClipped=min(max(rawControl,lo),hi);
            uNom=double(single(uNomClipped)); % float32 known-input component
            qNom=uNom;
            uCmdRequested=min(max(uNom+injection,lo),hi);
            uCmdPayload=double(single(uCmdRequested)); % exact float32 payload passed to adapter
            modelPayload=uCmdPayload;
            saturated=rawControl<lo||rawControl>hi||uNom+injection<lo||uNom+injection>hi;
        end
        if any(~isfinite([uNomClipped,uNom,uCmdRequested,uCmdPayload]))
            error('pendulumlab:Interlock','Command became nonfinite before transmission.');
        end
        result.signals.u_nominal(i)=uNom;
        result.signals.q_nominal(i)=qNom;
        result.signals.u_command_payload(i)=uCmdPayload;
        result.signals.u_command_prequantized(i)=uCmdRequested;
        result.signals.w_injected_requested(i)=injection;
        result.signals.w_injected_filtered(i)=injectionFilter(1);
        result.signals.w_injected_effective_requested(i)=modelPayload-uNom;
        result.signals.saturated(i)=saturated;
        if isfinite(cfg.safety.max_slew_units_s)
            if string(cfg.mode)=="hardware"
                % Measured at the planned current write time, after the read.
                elapsed=toc(hostClock)-previousWriteHost;
            else
                % Virtual-time adapters advance by the sample interval, not
                % wall-clock compute time.
                elapsed=deviceDelta;
            end
            if ~isfinite(elapsed)||elapsed<=0
                error('pendulumlab:Interlock','Invalid command interval for slew check.');
            end
            if abs(uCmdPayload-previousCommand)/elapsed>cfg.safety.max_slew_units_s
                if excitationReturn.enabled&&returnTransition&&excitationReturn.latched&& ...
                        uCmdPayload==0&&previousCommand>=0
                    % Explicitly frozen input shutdown, analogous to cleanup's
                    % immediate zero request. Only this one downward step is
                    % exempt; positive-command and timing checks stay active.
                    result.signals.zero_return_slew_exception(i)=true;
                else
                    error('pendulumlab:Interlock','Command slew exceeded configured limit; command was not transmitted.');
                end
            end
        end
        result.signals.write_start_host(i)=toc(hostClock);
        result.signals.write_attempted(i)=true;
        writeAttempts=writeAttempts+1;
        link.write(stream,single(uCmdPayload));
        result.signals.write_end_host(i)=toc(hostClock);
        % A returned write call records a transmitted request, not measured
        % actuator application. A thrown write leaves u_command/effective
        % injection NaN while retaining the attempted payload separately.
        result.signals.u_command(i)=uCmdPayload;
        result.signals.u_model_command(i)=modelPayload;
        result.signals.w_injected_effective(i)=modelPayload-uNom;
        result.signals.write_succeeded(i)=true; commandWrites=commandWrites+1;
        if excitationReturn.enabled&&excitationReturn.latched
            excitationReturn.zero_write_count=excitationReturn.zero_write_count+1;
            result.metadata.excitation_return=excitationReturn;
        end
        previousWriteHost=result.signals.write_start_host(i); previousCommand=uCmdPayload;
        if isfinite(cfg.safety.max_host_cycle_s)&& ...
                result.signals.write_end_host(i)-tReadStart>double(cfg.safety.max_host_cycle_s)
            error('pendulumlab:Interlock','Read-to-write transaction exceeded configured host-cycle maximum after command acknowledgement.');
        end
        % The deliberate effective injection is withheld from the observer;
        % known input is the clipped controller/open-loop base component.
        z=pendulumlab.rk4(@(zz)pendulumlab.observer_dx(zz,y,uNom,theta,T), ...
            double(cfg.Ts),z);
        injectionFilter=pendulumlab.rk4(@(xx)[xx(2); ...
            (result.signals.w_injected_effective(i)-xx(1)-2*T*xx(2))/T^2], ...
            double(cfg.Ts),injectionFilter);
        checkpointEvery=max(1,round(double(cfg.checkpoint_samples)));
        if mod(i,checkpointEvery)==0, save_checkpoint(i); end
    end
    result.status.code='completed'; result.status.reason='All scheduled samples acquired and writes returned successfully.';
    result.metadata.last_host_cycle_s=lastHostCycle;
catch err
    result.status.code=classify_error(err);
    result.status.reason=err.message;
    result.status.exception=exception_text(err);
end
clear cleanupGuard

    function ok=prepare_save_target()
        try
            target=run_path(cfg); ok=~isfile(target);
        catch
            ok=false;
        end
    end
    function finalize_run()
        if finalized, return; end
        finalized=true;
        if ~isempty(link)
            try
                if link.isOpen()
                    stopRequested=true; result.status.stop_requested=true;
                    writeAttempts=writeAttempts+1;
                    link.write(double(cfg.hardware.stream_id),single(0));
                    result.status.stop_succeeded=true;
                end
            catch stopErr
                result.status.stop_succeeded=false;
                result.status.stop_exception=exception_text(stopErr);
            end
            try
                if link.isOpen(), link.close(); end
            catch closeErr
                try, delete(link); catch, end
                result.status.close_exception=exception_text(closeErr);
            end
        end
        result.status.read_count=readSuccesses;
        result.status.read_attempt_count=readAttempts;
        result.status.rest_read_count=restReads;
        result.status.trial_read_count=trialReads;
        result.status.write_count=writeAttempts;
        result.status.command_write_count=commandWrites;
        result.status.link_closed=isempty(link)||~safe_is_open(link);
        result.status.stop_requested=stopRequested;
        if ~isempty(checkpointWriter)
            drainClock=tic;
            try
                checkpointWriter.finish();
            catch checkpointErr
                result.metadata.checkpoint_exception=exception_text(checkpointErr);
                if strcmp(result.status.code,'completed')
                    result.status.code='fault';result.status.reason=['Checkpoint writer failed: ' checkpointErr.message];
                end
            end
            result.metadata.checkpoint_drain_after_shutdown_s=toc(drainClock);
            result.metadata.checkpoint_submitted_count=checkpointWriter.Submitted;
            result.metadata.checkpoint_committed_sample=checkpointWriter.LastCommittedSample;
            result.metadata.last_checkpoint_duration_s=checkpointWriter.LastIOSeconds;
        end
        if strcmp(result.status.code,'completed')&&~result.status.link_closed
            result.status.code='fault'; result.status.reason='Link did not close cleanly.';
        end
        if strcmp(result.status.code,'completed')&&~result.status.stop_succeeded
            result.status.code='fault';
            result.status.reason='Best-effort zero-command request failed during cleanup.';
        end
        extent=find(result.signals.read_attempted|result.signals.write_attempted,1,'last');
        if isempty(extent), extent=0; end
        result.metadata.recorded_sample_count=extent;
        result.metadata.valid_sample_count=sum(result.signals.read_valid);
        result.signals=trim_signals(result.signals,extent);
        if allowSave
            try
                save_result();
                if isfile(checkpointTarget), delete(checkpointTarget); end
            catch saveErr
                result.status.save_exception=exception_text(saveErr);
                result.status.code='fault';
                result.status.reason=['Final result could not be saved: ' saveErr.message];
            end
        end
    end
    function save_checkpoint(sampleIndex)
        if isempty(checkpointTarget)||~allowSave, return; end
        checkpointClock=tic;
        result.status.read_count=readSuccesses;
        result.status.read_attempt_count=readAttempts;
        result.status.rest_read_count=restReads;
        result.status.trial_read_count=trialReads;
        result.status.write_count=writeAttempts;
        result.status.command_write_count=commandWrites;
        checkpointResult=result;
        checkpointResult.metadata.checkpoint_sample=sampleIndex;
        checkpointResult.metadata.checkpoint_state='in_progress';
        checkpointResult.metadata.recorded_sample_count=sampleIndex;
        checkpointResult.metadata.valid_sample_count=sum(result.signals.read_valid);
        checkpointResult.signals=trim_signals(result.signals,sampleIndex);
        if isempty(checkpointWriter)
            folder=fileparts(checkpointTarget);if ~isfolder(folder),mkdir(folder);end
            tmp=[tempname(folder) '.mat'];
            pendulumlab.write_checkpoint(checkpointTarget,tmp,checkpointResult);
        else
            checkpointWriter.submit(checkpointResult);
        end
        elapsed=toc(checkpointClock);
        result.metadata.last_checkpoint_submission_s=elapsed;
        if string(cfg.mode)=="hardware"&&isfinite(cfg.safety.max_host_cycle_s)&& ...
                elapsed>cfg.safety.max_host_cycle_s
            error('pendulumlab:Interlock','Checkpoint snapshot/submission exceeded the configured host-cycle budget; requesting zero and closing.');
        end
    end
    function save_result()
        if isempty(target), target=run_path(cfg); end
        if isfile(target), return; end
        folder=fileparts(target); if ~isfolder(folder), mkdir(folder); end
        result.metadata.saved_at=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss.SSSXXX'));
        tmp=[tempname(folder) '.mat'];
        save(tmp,'result','-v7');
        if isfile(target), delete(tmp); return; end
        [ok,msg]=movefile(tmp,target);
        if ~ok, if isfile(tmp), delete(tmp); end; error('pendulumlab:Save','Atomic result move failed: %s',msg); end
    end
end

function result=empty_result(cfg,schedule)
result=struct('schema_version','pendulumlab.run/1','recording_kind',recording_kind(cfg), ...
    'metadata',struct(),'signals',struct(),'status',struct());
result.metadata.config=cfg;
flat={'experiment_id','phase','Ts','T','a','theta','u_limits','use_compensation', ...
    'model_id','model_status','model_hardware_id','model_version','hardware_id', ...
    'run_id','campaign_id','block_id','trial_id','session_id','rng_seed'};
for k=1:numel(flat), if isfield(cfg,flat{k}), result.metadata.(flat{k})=cfg.(flat{k}); end, end
result.metadata.schedule_name=getfield_default(schedule,'name','');
result.metadata.schedule_role=getfield_default(schedule,'role','');
result.metadata.schedule_seed=getfield_default(schedule,'seed',NaN);
result.metadata.schedule_duration_s=getfield_default(schedule,'duration_s',NaN);
if isstruct(schedule)&&all(isfield(schedule,{'t','reference','injection','command','name','role','seed','injection_seed','duration_s'}))
    result.metadata.schedule_identity_sha256=pendulumlab.schedule_identity_sha256(schedule);
else
    result.metadata.schedule_identity_sha256='';
end
result.metadata.config_sha256=pendulumlab.json_value_sha256(cfg);
result.metadata.planned_session_id=getfield_default(cfg,'planned_session_id','');
result.metadata.frozen_provenance=struct('manifest_sha256',getfield_default(schedule,'manifest_sha256',''), ...
    'config_sha256',result.metadata.config_sha256, ...
    'schedule_sha256',getfield_default(schedule,'schedule_sha256',''), ...
    'schedule_identity_sha256',result.metadata.schedule_identity_sha256, ...
    'source_sha256',struct());
if isfield(schedule,'source_sha256'), result.metadata.frozen_provenance.source_sha256=schedule.source_sha256; end
result.metadata.timestamp=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss.SSSXXX'));
result.metadata.software=struct('matlab_version',version,'framework_schema','pendulumlab.run/1');
result.metadata.experiment_notes=getfield_default(cfg,'experiment_notes','');
result.metadata.deviations=getfield_default(cfg,'deviations','');
result.metadata.units=struct('t','s nominal schedule grid','t_device_raw', ...
    's raw firmware float32 timestamp (not atomic)','t_device','s relative to first valid run sample', ...
    't_host','s host-relative wall time','angle','rad','reference','rad','error','rad', ...
    'theta_alpha','rad/s^2','theta_beta','s^-1','theta_gamma','rad/s^2 per command unit', ...
    'a','s^-2','T','s','command_signals','actuator command units; no thrust/torque calibration', ...
    'w_hat','command units equivalent residual estimate','observer_z1_pre','command unit*s', ...
    'observer_z2_pre','command units');
if pendulumlab.actuator_coordinates(cfg,'enabled')
    result.metadata.actuator_calibration=cfg.actuator_calibration;
    result.metadata.units.u_command='raw transmitted motor command units';
    result.metadata.units.q_nominal='raw motor command before deliberate calibrated-input injection';
    result.metadata.units.u_nominal='known calibrated model input G(q_nominal)/gamma_ref';
    result.metadata.units.u_model_command='total calibrated model input G(u_command)/gamma_ref';
    result.metadata.units.u_C='calibrated model-input units';
    result.metadata.units.u_control_raw='calibrated model-input units for feedback; raw motor units for open-loop schedules';
    result.metadata.units.w_hat='calibrated model-input units; equivalent residual, not measured torque';
    result.metadata.units.w_injected_effective='u_model_command minus u_nominal, calibrated model-input units';
    result.metadata.units.observer_z1_pre='calibrated model-input unit*s';
    result.metadata.units.observer_z2_pre='calibrated model-input units';
    result.metadata.input_identity='u_nominal + w_injected_effective = u_model_command; u_command retains the raw wire payload. Static calibration does not measure actual thrust or remove actuator lag.';
end
result.metadata.provenance=struct('mode',cfg.mode,'synthetic_only',strcmp(cfg.mode,'mock'), ...
    'actuator_application_independently_measured',false,'device_timestamp_atomic',false);
result.status=struct('code','blocked','reason','','read_count',0,'write_count',0, ...
    'command_write_count',0,'read_attempt_count',0,'rest_read_count',0,'trial_read_count',0, ...
    'stop_requested',false,'stop_succeeded',false, ...
    'stop_semantics','Successful zero-command write request only; mechanical stopping is not measured.', ...
    'link_closed',true,'exception','','save_exception','');
end
function signals=preallocate_signals(n,schedule)
num={'t','t_device_raw','t_device','t_host','read_start_host','read_end_host', ...
    'write_start_host','write_end_host','reference','angle','error','u_C', ...
    'u_control_raw','u_nominal','u_command','w_hat','w_injected_requested', ...
        'u_excitation_requested', ...
    'w_injected_effective','w_injected_filtered','u_command_prequantized', ...
    'u_command_payload','w_injected_effective_requested','observer_z1_pre','observer_z2_pre', ...
    'q_nominal','u_model_command'};
signals=struct(); for k=1:numel(num), signals.(num{k})=nan(n,1); end
signals.t=double(schedule.t(:)); signals.reference=double(schedule.reference(:));
signals.w_injected_requested=double(schedule.injection(:));
signals.saturated=false(n,1); signals.read_valid=false(n,1); signals.write_succeeded=false(n,1);
signals.excitation_return_latched=false(n,1);signals.zero_return_slew_exception=false(n,1);
signals.read_attempted=false(n,1); signals.write_attempted=false(n,1);
end
function signals=trim_signals(signals,n)
names=fieldnames(signals);
for k=1:numel(names)
    value=signals.(names{k});
    if isvector(value)&&numel(value)>=n, signals.(names{k})=value(1:n); end
end
end
function [s,n]=validate_schedule(s,cfg)
required={'t','reference','injection','command','name','role','seed','duration_s'};
for k=1:numel(required), if ~isfield(s,required{k}), error('pendulumlab:Schedule','Schedule missing %s.',required{k}); end, end
s.t=double(s.t(:)); s.reference=double(s.reference(:)); s.injection=double(s.injection(:)); s.command=double(s.command(:));
n=numel(s.t);
if n<2||numel(s.reference)~=n||numel(s.injection)~=n||numel(s.command)~=n|| ...
        any(~isfinite(s.t))||any(diff(s.t)<=0)||any(~isfinite(s.injection))|| ...
        any(~isfinite(s.reference))||any(isinf(s.command))
    error('pendulumlab:Schedule','Schedule vectors must have equal length, finite increasing times, finite reference/injection, and finite-or-NaN command.');
end
if abs(s.t(1))>1e-12||any(abs(diff(s.t)-double(cfg.Ts))>1e-9)|| ...
        abs(double(s.duration_s)-n*double(cfg.Ts))>1e-9
    error('pendulumlab:Schedule','Schedule must start at zero, use exactly Ts-spaced samples, and report duration n*Ts.');
end
if ~strcmp(char(s.name),char(cfg.experiment_id))||~strcmp(char(s.role),char(cfg.phase))
    error('pendulumlab:Schedule','Schedule name/role do not match frozen experiment_id/phase.');
end
if string(cfg.mode)=="hardware"&&~pendulumlab.schedule_matches_config(cfg,s)
    error('pendulumlab:Schedule','Actual schedule vectors differ from the reviewed configuration; refusing physical execution.');
end
openLoop=any(string(cfg.phase)==["identification","validation"]);
if openLoop
    if any(~isfinite(s.command))||any(s.command<double(cfg.u_limits(1)))|| ...
            any(s.command>double(cfg.u_limits(2)))||any(s.injection~=0)
        error('pendulumlab:Schedule','Identification/validation requires finite in-limit full commands and zero separate injection.');
    end
elseif any(~isnan(s.command))
    error('pendulumlab:Schedule','Feedback schedules must use NaN command vectors.');
end
if double(cfg.safety.max_device_gap_s)>1.5*double(cfg.Ts)+10*eps(double(cfg.Ts))
    error('pendulumlab:Schedule','Configured device-gap limit exceeds 1.5 sample periods.');
end
if any(diff(s.t)>min(double(cfg.safety.max_device_gap_s),1.5*double(cfg.Ts))+10*eps(double(cfg.Ts)))
    error('pendulumlab:Schedule','Schedule itself contains a gap beyond the configured device-gap limit.');
end
if s.t(end)-s.t(1)>double(cfg.safety.max_duration_s)
    error('pendulumlab:Schedule','Schedule duration exceeds the configured maximum.');
end
end
function path=run_path(cfg)
if isempty(cfg.run_id), error('pendulumlab:RunId','run_id must be assigned before running.'); end
if isempty(regexp(char(cfg.run_id),'^[A-Za-z0-9_-]+$','once'))
    error('pendulumlab:RunId','run_id must contain only letters, digits, underscore, or hyphen.');
end
path=fullfile(char(cfg.output_dir),'runs',[char(cfg.run_id) '.mat']);
end
function ok=hardware_gate_complete(cfg)
ok=false;
if ~isfield(cfg,'hardware'), return; end
names={'enabled','operator_armed','mechanical_ready','angle_zero_confirmed'};
for k=1:numel(names), if ~isfield(cfg.hardware,names{k})||~isequal(cfg.hardware.(names{k}),true), return; end, end
ok=true;
end
function s=issues_text(report)
s='Configuration blocked.';
if isfield(report,'issues')&&~isempty(report.issues), s=strjoin(string(report.issues),'; '); elseif isfield(report,'errors')&&~isempty(report.errors), s=strjoin(string(report.errors),'; '); end
end
function code=classify_error(err)
if strcmp(err.identifier,'pendulumlab:OperatorAbort'), code='aborted';
elseif strcmp(err.identifier,'pendulumlab:Interlock'), code='interlock';
else, code='fault'; end
end
function s=exception_text(err)
s=sprintf('%s: %s',err.identifier,err.message);
end
function kind=recording_kind(cfg)
switch string(cfg.mode)
    case "mock", kind='synthetic';
    case "replay", kind='replay';
    otherwise, kind='physical';
end
end
function v=getfield_default(s,n,d)
if isfield(s,n), v=s.(n); else, v=d; end
end
function tf=safe_is_open(link)
try, tf=link.isOpen(); catch, tf=false; end
end
function tf=valid_runtime_arm(arm)
tf=false;
if ~isstruct(arm)||~all(isfield(arm,{'HardwareArmed','operator_id','confirmed_utc','arm_id','session_id'}))|| ...
        ~isequal(arm.HardwareArmed,true)||strlength(strtrim(string(arm.operator_id)))==0|| ...
        strlength(strtrim(string(arm.arm_id)))==0||strlength(strtrim(string(arm.session_id)))==0
    return
end
try
    confirmed=pendulumlab.parse_utc(arm.confirmed_utc);
    age=seconds(datetime('now','TimeZone','UTC')-confirmed);
    tf=isfinite(age)&&age>=-30&&age<=300;
catch
    tf=false;
end
end
function [ok,reason]=physical_preflight(cfg,arm)
ok=false; reason='';
if ~valid_runtime_arm(arm)
    reason='Fresh runtime arm requires HardwareArmed=true, operator_id, actual session_id, unique arm_id, and a confirmation time no older than five minutes.'; return
end
if ~isfield(arm,'source_sha256')||~isstruct(arm.source_sha256)
    reason='A verified frozen campaign source-hash map is required for direct physical execution.'; return
end
hashes=arm.source_sha256; fields=fieldnames(hashes); pkgDir=fileparts(mfilename('fullpath'));
if isempty(fields), reason='Frozen source-hash map is empty.'; return; end
expected=pendulumlab.source_fingerprint(); expectedNames=sort(fieldnames(expected)); actualNames=sort(fields);
if ~isequal(expectedNames,actualNames)
    reason='Frozen source inventory differs from the active package/public wrappers.'; return
end
for k=1:numel(expectedNames)
    name=expectedNames{k};
    if ~strcmpi(char(expected.(name)),char(hashes.(name)))
        reason=['Frozen source changed or missing: ' name]; return
    end
end
try
    protected=pendulumlab.verify_protected();
    if ~protected.passed, reason='Protected legacy project baseline verification failed.'; return; end
catch err
    reason=['Protected baseline could not be verified: ' err.message]; return
end
projectRoot=pendulumlab.project_root();
physicalRoot=fullfile(projectRoot,'experiment_data','campaign_v2');
output=char(cfg.output_dir);
physicalPrefix=[lower(physicalRoot) filesep];
if ~startsWith(lower([output filesep]),physicalPrefix)
    reason='Physical output_dir must be inside experiment_data/campaign_v2.'; return
end
ok=true;
end
function root=project_root_for_trial()
root=pendulumlab.project_root();
end
function [ok,reason]=consume_arm_id(cfg,arm)
ok=false; reason=''; id=char(arm.arm_id);
if ~strcmp(id,regexprep(id,'[^A-Za-z0-9_-]',''))
    reason='arm_id must contain only letters, digits, underscore, or hyphen.'; return
end
folder=fullfile(pendulumlab.project_root(),'experiment_data','campaign_v2','runtime_arms');
if ~isfolder(folder), mkdir(folder); end
receiptPath=fullfile(folder,[id '.json']);
if isfile(receiptPath), reason='Runtime arm ID was already consumed; obtain a fresh operator arm.'; return; end
receipt=struct('arm_id',id,'operator_id',char(arm.operator_id), ...
    'confirmed_utc',char(arm.confirmed_utc),'session_id',char(arm.session_id), ...
    'consumed_utc',char(datetime('now', ...
    'TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss.SSSXXX')), ...
    'campaign_id',char(cfg.campaign_id),'run_id',char(cfg.run_id), ...
    'source_sha256',arm.source_sha256);
tmp=[tempname(folder) '.json']; fid=fopen(tmp,'wt');
if fid<0, reason='Could not write durable runtime-arm receipt.'; return; end
guard=onCleanup(@()fclose(fid)); fwrite(fid,jsonencode(receipt),'char'); clear guard
if isfile(receiptPath), delete(tmp); reason='Runtime arm ID was consumed concurrently.'; return; end
[moved,msg]=movefile(tmp,receiptPath);
if ~moved
    if isfile(tmp), delete(tmp); end
    reason=['Could not atomically consume runtime arm: ' msg]; return
end
ok=true;
end

