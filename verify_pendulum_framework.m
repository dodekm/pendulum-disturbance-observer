function report=verify_pendulum_framework()
%VERIFY_PENDULUM_FRAMEWORK Execute ONLY offline regression/mock/model tests.
clock=tic;
root=fileparts(mfilename('fullpath'));framework=fullfile(root,'experiment_framework');
oldPath=path;guard=onCleanup(@()path(oldPath));addpath(framework);
before=pendulumlab.verify_protected();assert(before.passed,'pendulumlab:Protected','Protected baseline differs before tests.');
legacy=runtests(fullfile(root,'tests','test_offline_analysis.m'));
current=runtests(fullfile(framework,'tests'),'IncludeSubfolders',true);
after=pendulumlab.verify_protected();
report=struct('legacy_results',legacy,'framework_results',current, ...
    'protected_before',before,'protected_after',after,'physical_experiments_run',false);
save(fullfile(framework,'verification','offline_verification.mat'),'report','-v7');
allResults=[legacy(:);current(:)];
items=arrayfun(@(r)struct('name',r.Name,'passed',r.Passed,'failed',r.Failed, ...
    'incomplete',r.Incomplete,'duration_s',r.Duration),allResults);
summary=struct('schema_version','pendulumlab.verification/1', ...
    'verified_utc',char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z''')), ...
    'matlab_version',version,'physical_experiments_run',false,'total_tests',numel(items), ...
    'passed_tests',sum([items.passed]),'failed_tests',sum([items.failed]), ...
    'incomplete_tests',sum([items.incomplete]),'elapsed_s',toc(clock), ...
    'protected_before',before,'protected_after',after,'tests',items);
fid=fopen(fullfile(framework,'verification','offline_verification_summary.json'),'wt');
assert(fid>=0,'pendulumlab:VerificationSave','Could not save verification summary.');
fileGuard=onCleanup(@()fclose(fid));fprintf(fid,'%s',jsonencode(summary,PrettyPrint=true));clear fileGuard
assert(after.passed,'pendulumlab:Protected','A protected file changed during offline verification.');
assertSuccess(legacy);assertSuccess(current);
clear guard
end
