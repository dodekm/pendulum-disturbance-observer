function matches=schedule_matches_config(cfg,schedule)
%SCHEDULE_MATCHES_CONFIG Compare actual vectors with the reviewed protocol.
% Extra provenance fields do not change the prescribed excitation/reference.
matches=false;
try
    expected=pendulumlab.make_schedule(cfg);
    matches=strcmp(pendulumlab.schedule_identity_sha256(expected), ...
        pendulumlab.schedule_identity_sha256(schedule));
catch
end
end
