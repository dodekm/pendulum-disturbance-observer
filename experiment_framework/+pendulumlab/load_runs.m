function runs=load_runs(source)
%LOAD_RUNS Load new run/1 records and bind their actual raw-file SHA-256.
% Legacy data have a separate read-only importer. This function never changes
% a recording kind, a hardware identity, or a source recording on disk.
arguments
    source (1,1) string
end
if isfolder(source)
    folder=char(source);
    if isfolder(fullfile(folder,'runs')),folder=fullfile(folder,'runs');end
    files=dir(fullfile(folder,'*.mat'));
    files=files(~contains({files.name},'.checkpoint.'));
    [~,order]=sort({files.name});files=files(order);
    paths=string(fullfile({files.folder},{files.name}));
elseif isfile(source)
    paths=source;
else
    error('pendulumlab:SourceNotFound','Run source not found: %s',source);
end
assert(~isempty(paths),'pendulumlab:NoRuns','No final run files found.');
records=cell(numel(paths),1);
for k=1:numel(paths)
    p=char(paths(k));s=load(p,'result');
    assert(isfield(s,'result')&&isstruct(s.result)&& ...
        all(isfield(s.result,{'schema_version','recording_kind','metadata','signals','status'})), ...
        'pendulumlab:RunSchema','Use import_legacy for historical records: %s',p);
    r=s.result;
    assert(strcmp(r.schema_version,'pendulumlab.run/1'),'pendulumlab:RunSchema','Unsupported run schema: %s',p);
    assert(any(strcmp(r.recording_kind,{'physical','synthetic','replay'})), ...
        'pendulumlab:RunKind','Unknown recording kind: %s',p);
    r.provenance=struct('source_file',p,'source_sha256',pendulumlab.file_hash(p));
    records{k}=r;
end
runs=vertcat(records{:});
end
