function digest=model_descriptor_sha256(model)
%MODEL_DESCRIPTOR_SHA256 Bind nominal parameters and optional physical/input model.
s=struct('theta',double(model.theta(:).'));
for key={'actuator_calibration','plant_characterization','nominal_inverse_scope'}
    if isfield(model,key{1}),s.(key{1})=model.(key{1});end
end
digest=pendulumlab.json_integrity_sha256(s);
end
