function cfg=config_from_model(modelId,registryDir,phase)
%CONFIG_FROM_MODEL Bind a checksum-verified model; never grants hardware arming.
arguments
    modelId (1,1) string
    registryDir (1,1) string
    phase (1,1) string = "pilot"
end
record=pendulumlab.load_model(modelId,registryDir);
cfg=pendulumlab.default_config(phase);
cfg.theta=double(record.theta(:)');cfg.model_id=char(record.model_id);
cfg.model_status=char(record.status);cfg.model_hardware_id=char(record.hardware_id);
cfg.model_record=record;cfg.model_registry_dir=char(registryDir);
if isfield(record,'actuator_calibration')
    cfg.actuator_calibration=record.actuator_calibration;
end
if isfield(record,'plant_characterization')
    cfg.mock.theta=cfg.theta;cfg.mock.actuator_lag_s=record.plant_characterization.lag_s;
end
% Retain the planned replacement-hardware identity. A model for the original
% propeller must not silently change the target hardware to pass a gate.
cfg.hardware.model_accepted=pendulumlab.model_use_accepted(record);
end
