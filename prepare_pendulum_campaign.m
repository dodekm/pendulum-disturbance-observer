function bundle=prepare_pendulum_campaign(options)
%PREPARE_PENDULUM_CAMPAIGN Build offline plans/config templates; NEVER open UART.
% This does not execute runs or establish readiness of the replacement propeller.
arguments
    options.OutputDirectory (1,1) string = ""
    options.IncludeExpanded (1,1) logical = true
end
root=fileparts(mfilename('fullpath'));framework=fullfile(root,'experiment_framework');
oldPath=path;guard=onCleanup(@()path(oldPath));addpath(framework);
protected=pendulumlab.verify_protected();assert(protected.passed,'pendulumlab:Protected','A protected legacy/interface/manuscript file changed.');
if strlength(options.OutputDirectory)==0
    folder=fullfile(framework,'plans',['preparation_' char(java.util.UUID.randomUUID)]);
else
    folder=char(options.OutputDirectory);
end
canonical=char(java.io.File(folder).getCanonicalPath());
frameworkCanonical=char(java.io.File(framework).getCanonicalPath());
assert(startsWith(lower([canonical filesep]),lower([frameworkCanonical filesep])), ...
    'pendulumlab:PreparationLocation','Store preparation bundles inside experiment_framework.');
if isfolder(folder)
    entries=dir(folder);entries=entries(~ismember({entries.name},{'.','..'}));
    assert(isempty(entries),'pendulumlab:PreparationExists', ...
        'Use a new output folder; preparation bundles are not overwritten.');
end
if ~isfolder(folder),mkdir(folder);end
planNames={'identification','validation','pilot','core'};
if options.IncludeExpanded,planNames{end+1}='expanded';end
manifests=cell(size(planNames));templates=cell(size(planNames));readiness=cell(size(planNames));
for k=1:numel(planNames)
    name=planNames{k};phase=name;
    if any(strcmp(name,{'core','expanded'})),phase='confirmatory';end
    cfg=pendulumlab.default_config(phase);cfg.output_dir=fullfile(folder,'synthetic_plans');
    manifests{k}=pendulumlab.prepare_campaign(cfg,string(name));
    cfg.mode='hardware';cfg.output_dir=fullfile(root,'experiment_data','campaign_v2');
    templates{k}=cfg;readiness{k}=pendulumlab.validate_config(cfg);
    assert(~readiness{k}.hardware_allowed,'pendulumlab:UnexpectedArming','A default hardware template unexpectedly passed arming.');
end
excitation=pendulumlab.excitation_audit();
bundle=struct('schema_version','pendulumlab.preparation/1','prepared_utc', ...
    char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z''')), ...
    'folder',folder,'no_hardware_executed',true,'plans',{manifests}, ...
    'operator_templates',{templates},'readiness',{readiness},'excitation_audit',excitation, ...
    'protected_baseline',protected,'hardware_transition', ...
    'All fourteen legacy runs: original propeller. Planned campaign: replacement_propeller_01; same geometry is not dynamic equivalence.');
save(fullfile(folder,'preparation_bundle.mat'),'bundle','-v7');
fid=fopen(fullfile(folder,'preparation_bundle.json'),'wt');
assert(fid>=0,'pendulumlab:PreparationSave','Cannot save preparation summary.');
fileGuard=onCleanup(@()fclose(fid));fprintf(fid,'%s',jsonencode(bundle,PrettyPrint=true));clear fileGuard
fprintf('Offline preparation written to %s\n',folder);
fprintf('No hardware accessed. Physical bounds, mechanical readiness and model validation remain operator/data gates.\n');
clear guard
end
