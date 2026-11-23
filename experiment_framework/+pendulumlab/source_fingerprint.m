function hashes=source_fingerprint()
%SOURCE_FINGERPRINT Hash every active package m-file plus public wrappers.
pkgDir=fileparts(mfilename('fullpath')); hashes=struct(); files=dir(fullfile(pkgDir,'*.m'));
for k=1:numel(files)
    key=['pkg_' matlab.lang.makeValidName(files(k).name)];
    hashes.(key)=pendulumlab.file_hash(fullfile(files(k).folder,files(k).name));
end
root=pendulumlab.project_root(); wrappers={'prepare_pendulum_campaign.m','verify_pendulum_framework.m', ...
    'prepare_calibrated_experiments.m','run_pendulum_control.m','prepare_pendulum_factorial.m'};
for k=1:numel(wrappers)
    p=fullfile(root,wrappers{k});
    if isfile(p),hashes.(['root_' matlab.lang.makeValidName(wrappers{k})])=pendulumlab.file_hash(p);end
end
end

