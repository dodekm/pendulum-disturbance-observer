function report=verify_protected()
%VERIFY_PROTECTED Recheck the read-only baseline; no file writes.
root=pendulumlab.project_root();
path=fullfile(root,'experiment_framework','verification','protected_files.json');
assert(isfile(path),'pendulumlab:Baseline','Protected baseline is missing.');
baseline=jsondecode(fileread(path));missing={};changed={};
for k=1:numel(baseline.files)
    row=baseline.files(k);file=fullfile(root,strrep(row.relative_path,'/',filesep));
    if ~isfile(file),missing{end+1}=row.relative_path; %#ok<AGROW>
    elseif ~strcmpi(pendulumlab.file_hash(file),row.sha256),changed{end+1}=row.relative_path; %#ok<AGROW>
    end
end
report=struct('passed',isempty(missing)&&isempty(changed),'file_count',numel(baseline.files), ...
    'missing',{missing},'changed',{changed});
end
