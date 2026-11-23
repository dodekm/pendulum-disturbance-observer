function result = reproduce_pendulum_revision(options)
%REPRODUCE_PENDULUM_REVISION Recompute the revised paper's recorded evidence.
% No serial connection, firmware, acquisition driver or physical trial is used.
% Run from an extracted supplement: result = reproduce_pendulum_revision;
% All control metrics are compared with the archived CSVs. Use
% RegenerateCampaignFigures=false to skip only the control figure exports.
arguments
    options.OutputDirectory (1,1) string = ""
    options.RegenerateCampaignFigures (1,1) logical = true
end
root=fileparts(mfilename('fullpath'));previous=pwd;cd(root);
restore=onCleanup(@()cd(previous)); %#ok<NASGU>
previousPath=path;
restorePath=onCleanup(@()path(previousPath)); %#ok<NASGU>
addpath(root,fullfile(root,'experiment_framework'));
for name=["analyze_calibrated_pendulum_campaign","verify_pendulum_control_replay", ...
          "audit_pendulum_excitation_coverage","compare_frozen_validation_models_secondary","verify_frozen_identification_predictions", ...
          "pendulumlab.file_hash","pendulumlab.evaluate_campaign","pendulumlab.predict_recorded_model"]
    resolved=char(java.io.File(which(char(name))).getCanonicalPath());
    assert(within(resolved,root),'A reproduction dependency resolves outside this copy: %s',resolved);
end
if strlength(options.OutputDirectory)==0
    out=fullfile(root,'analysis_results', ...
        ['reproduced_revision_' char(datetime('now','TimeZone','UTC','Format','yyyyMMdd_HHmmss_SSS'))]);
else
    out=char(java.io.File(char(options.OutputDirectory)).getCanonicalPath());
end
[allowed,why]=pendulumlab.output_location_allowed(out,'offline');assert(allowed,'%s',why);
assert(~isfolder(out),'Refusing to overwrite an existing output directory.');
manifestFile=fullfile(root,'supplement_manifest.json');
if isfile(manifestFile),package=verifyPackage(root,manifestFile);else,package=struct('verified',false,'reason','Running in the development project, not a packaged supplement.');end

ids={'cmp_ac34c50875f94531b548614a871c7dd6','cmp_19a9518f3c3c4ec6bb284a8056259c36','cmp_72165335448e4327876f08a7054a3bd0'};
names={'primary','matrix','unpaired_makeup'};expectedComplete=[20 47 1];
manifests=strings(3,1);rawFiles=strings(0,1);campaigns=cell(3,1);
allLedgers=dir(fullfile(root,'experiment_data','campaign_v2','campaigns','*','campaign_status.json'));
for k=1:numel(allLedgers)
    l=jsondecode(fileread(fullfile(allLedgers(k).folder,allLedgers(k).name)));
    assert(~any(strcmp({l.runs.code},'running')),'An acquisition ledger is active; defer offline reproduction.');
end
for k=1:3
    d=fullfile(root,'experiment_data','campaign_v2','campaigns',ids{k});
    manifests(k)=fullfile(d,'campaign_manifest.json');m=jsondecode(fileread(manifests(k)));
    l=jsondecode(fileread(fullfile(d,'campaign_status.json')));
    assert(strcmpi(strtrim(fileread(fullfile(d,'campaign_manifest.sha256'))),pendulumlab.file_hash(manifests(k))));
    assert(numel(m.runs)==numel(l.runs));
    nComplete=sum(strcmp({l.runs.code},'completed'));nInterlock=sum(strcmp({l.runs.code},'interlock'));
    assert(nComplete==expectedComplete(k)&&nInterlock==(k==2));
    for j=1:numel(m.runs)
        assert(strcmp(m.runs(j).run_id,l.runs(j).run_id));
        p=fullfile(d,'runs',[m.runs(j).run_id '.mat']);assert(isfile(p));
        rawFiles(end+1,1)=p; %#ok<AGROW>
    end
    campaigns{k}=struct('cohort',names{k},'campaign_id',ids{k},'manifest',char(manifests(k)), ...
        'planned',numel(m.runs),'complete',nComplete,'interlock',nInterlock,'analysis_directory','');
end
assert(numel(rawFiles)==69&&numel(unique(rawFiles))==69);
mkdir(out);
fprintf('OFFLINE_ONLY: replaying 69 recorded control attempts in %s\n',root);
replay=verify_pendulum_control_replay(rawFiles,string(fullfile(out,'replay')));
assert(replay.summary.full_pass==68&&replay.summary.partial==1&&replay.summary.failed==0&&replay.summary.incomplete==0);
assert(all(arrayfun(@(r)within(r.source_file,root),replay.trials)),'Replay read a file outside the extracted copy.');
for k=1:3
    dest=fullfile(out,names{k});
    a=analyze_calibrated_pendulum_campaign(manifests(k),string(dest), ...
        GenerateFigures=options.RegenerateCampaignFigures);
    assert(all(arrayfun(@(r)within(r.result_file,root),a.planned_runs)));
    assert(all([a.planned_runs.integrity_verified]));
    checkArchivedNumbers(root,names{k},dest);
    campaigns{k}.analysis_directory=dest;
    fprintf('COHORT_REPRODUCED %s\n',names{k});
end
coverageDir=audit_pendulum_excitation_coverage(manifests,string(fullfile(out,'coverage')));
coverage=jsondecode(fileread(fullfile(coverageDir,'coverage_audit.json')));
outcomes=coverage.control_outcomes;if iscell(outcomes),outcomes=[outcomes{:}];end
training=coverage.training_sources;if iscell(training),training=[training{:}];end
assert(sum([outcomes.eligible_for_coverage])==68&&~any(strlength(string({outcomes.raw_load_error}))>0));
assert(all(arrayfun(@(r)within(r.source_file,root),training)));
assert(all(arrayfun(@(r)within(r.result_file,root),outcomes)));
modelDir=compare_frozen_validation_models_secondary(string(fullfile(out,'model_comparison')));
model=jsondecode(fileread(fullfile(modelDir,'secondary_comparison.json')));
assert(~model.original_frozen_assessment_passed);
identification=verify_frozen_identification_predictions(string(fullfile(out,'development_replay')));
assert(strcmp(identification.state,'passed'));
result=struct('schema_version','pendulumlab.revision_reproduction/1','state','passed', ...
    'execution_mode','offline recorded-data analysis; no UART or hardware calls', ...
    'root',root,'output_directory',out,'package_integrity',package,'campaigns',{campaigns}, ...
    'control_replay',replay.summary,'coverage_directory',coverageDir,'model_comparison_directory',modelDir, ...
    'development_replay_directory',fullfile(out,'development_replay'), ...
    'all_campaign_figures_regenerated',options.RegenerateCampaignFigures, ...
    'limitations','Reproduces recorded evidence, not new physical repetition, accuracy approval, robust stability or between-day reproducibility.');
writeJson(fullfile(out,'reproduction_report.json'),result);
fprintf('REVISION_REPRODUCTION_PASSED %s\n',out);
end

function proof=verifyPackage(root,path)
m=jsondecode(fileread(path));assert(strcmp(m.schema_version,'pendulumlab.supplement_manifest/1'));
assert(~isempty(m.files));
for k=1:numel(m.files)
    relative=char(m.files(k).relative_path);p=char(java.io.File(fullfile(root,strrep(relative,'/',filesep))).getCanonicalPath());
    assert(within(p,root),'Package member escapes extraction root.');
    assert(isfile(p)&&strcmpi(pendulumlab.file_hash(p),m.files(k).sha256),'Supplement file hash mismatch: %s',relative);
end
proof=struct('verified',true,'files_checked',numel(m.files),'manifest_sha256',pendulumlab.file_hash(path));
end

function checkArchivedNumbers(root,cohort,destination)
p=fullfile(root,'analysis_results','revision_20261106','campaigns_20261106_214004_145',cohort,'trial_metrics.csv');
assert(isfile(p),'Missing archived numeric reference.');
expected=readtable(p,'TextType','string');
actual=readtable(fullfile(destination,'trial_metrics.csv'),'TextType','string');
assert(isequal(expected.Properties.VariableNames,actual.Properties.VariableNames) && ...
    height(expected)==height(actual),'Archived and reproduced trial CSV schemas or row counts differ.');
assert(numel(unique(expected.run_id))==height(expected) && ...
    numel(unique(actual.run_id))==height(actual),'Trial CSV contains duplicate run IDs.');
expected=sortrows(expected,'run_id');actual=sortrows(actual,'run_id');
for name=string(expected.Properties.VariableNames)
    want=expected.(name);got=actual.(name);
    if isnumeric(want)&&isnumeric(got)
        matches=(want==got)|(isnan(want)&isnan(got))| ...
            (isfinite(want)&isfinite(got)&abs(want-got)<1e-9);
        pass=all(matches);
    else
        pass=isequaln(want,got);
    end
    assert(pass,'Recomputed %s column differs in the %s cohort.',name,cohort);
end
end

function tf=within(path,root)
path=char(java.io.File(char(path)).getCanonicalPath());root=char(java.io.File(char(root)).getCanonicalPath());
tf=startsWith(lower([path filesep]),lower([root filesep]));
end

function writeJson(path,value)
fid=fopen(path,'w','n','UTF-8');assert(fid>=0);c=onCleanup(@()fclose(fid));
fprintf(fid,'%s',jsonencode(value,PrettyPrint=true));clear c
end
