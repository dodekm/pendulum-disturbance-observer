function cfg=calibrated_control_config(modelId,phase)
%CALIBRATED_CONTROL_CONFIG Shared frozen study settings; never arms hardware.
arguments
    modelId (1,1) string
    phase (1,1) string = "pilot"
end
registry=fullfile(pendulumlab.project_root(),'experiment_framework','model_registry');
cfg=pendulumlab.config_from_model(modelId,string(registry),phase);
assert(isfield(cfg,'actuator_calibration')&&pendulumlab.actuator_coordinates(cfg,'enabled'), ...
    'pendulumlab:CalibrationRequired','Select a model carrying the static actuator calibration.');
cfg.a=25;cfg.T=.5;cfg.use_compensation=false;cfg.u_limits=[0 62];
cfg.safety.max_slew_units_s=40;cfg.campaign.intertrial_recovery_s=20;
cfg.session_id='revision_calibrated_session_20261106';
cfg.session_deadline_utc='2026-11-06T19:45:00Z';cfg.latest_start_utc='2026-11-06T19:40:00Z';
cfg.async_checkpoint=true;
p=cfg.protocol;p.duration_s=144;p.reference_levels_rad=deg2rad([30 45 60 45 30]);p.plateau_s=25;
p.reference_waypoints=[0 0;5 0;15 pi/6;40 pi/6;41 pi/4;66 pi/4;67 pi/3;92 pi/3;93 pi/4;118 pi/4;119 pi/6;144 pi/6];
p.reference_plateau_ranges_s=[15 40;41 66;67 92;93 118;119 144];p.startup_end_s=15;
tracking=p;
p=cfg.protocol;p.duration_s=100;p.reference_levels_rad=pi/4;p.plateau_s=100;
p.reference_waypoints=[0 0;5 0;15 pi/4;100 pi/4];p.reference_plateau_ranges_s=[15 100];
p.injection_time_offset_s=30;p.injection_amplitude=3;p.injection_ramp_s=.2;p.startup_end_s=40;
injection=p;
cfg.campaign.control_protocols=struct('reference_tracking',tracking,'injected_disturbance',injection);
cfg.protocol=tracking;cfg.experiment_id='reference_tracking';cfg.analysis.evaluation_windows=pendulumlab.analysis_windows(cfg);
cfg.experiment_notes=['Calibrated input u=G(q)/gamma_ref; gamma_ref=G(52)/52. Raw q limits [0,62] and raw slew40 retained. ', ...
    'Reference ramps are frozen protocol inputs, not online command slew shaping. Injection3 is in calibrated model-input units with frozen0.2s transitions. ', ...
    'Full identified rig includes lag; the nominal two-state DOB/controller do not invert that extra state. ', ...
    'Use status is carried by the immutable model record; characterized use retains failed accuracy targets and does not certify stability or predictive accuracy.'];
end
