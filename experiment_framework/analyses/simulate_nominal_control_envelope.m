function records=simulate_nominal_control_envelope()
%SIMULATE_NOMINAL_CONTROL_ENVELOPE Synthetic planned control cases, never UART.
folder=fullfile(tempdir,['pendulum_control_envelope_' char(java.util.UUID.randomUUID)]);
cleanup=onCleanup(@()removeTemporary(folder));records=cell(8,1);k=0;
for protocol={'reference_tracking','injected_disturbance'}
    for setting=[0 .2 .5 1]
        k=k+1;cfg=pendulumlab.default_config('pilot');cfg.experiment_id=protocol{1};
        cfg.mode='mock';cfg.output_dir=folder;cfg.run_id=sprintf('nominal_%d',k);
        cfg.safety.max_host_cycle_s=2;cfg.use_compensation=setting>0;
        if setting>0,cfg.T=setting;end
        records{k}=pendulumlab.run_trial(cfg,pendulumlab.make_schedule(cfg));
    end
end
clear cleanup
end
function removeTemporary(folder)
target=char(java.io.File(folder).getCanonicalPath());base=char(java.io.File(tempdir).getCanonicalPath());
assert(startsWith(lower(target),lower([base filesep]))&&~strcmpi(target,base));
if isfolder(target),rmdir(target,'s');end
end
