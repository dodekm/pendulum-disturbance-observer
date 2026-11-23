function runs = import_legacy(source)
%IMPORT_LEGACY Import historical MAT files without changing their contents.
%   R = pendulumlab.import_legacy(FILE) imports one file. Passing a folder
%   imports all *.mat files in that folder in lexical filename order.
%   Imported records are tagged as legacy measurements on the original
%   propeller. Their trial identifiers are stable content-derived IDs; they
%   remain single recordings and are never treated as campaign repetitions.

arguments
    source (1,1) string
end
if isfolder(source)
    files = dir(fullfile(source,'*.mat'));
    [~,ix] = sort({files.name}); files = files(ix);
    paths = strings(numel(files),1);
    for k=1:numel(files), paths(k)=fullfile(files(k).folder,files(k).name); end
elseif isfile(source)
    paths = source;
else
    error('pendulumlab:LegacySourceNotFound','Source does not exist: %s',source);
end
if isempty(paths), error('pendulumlab:NoLegacyFiles','No MAT files found in %s.',source); end

runs = repmat(emptyRun(),numel(paths),1);
for k=1:numel(paths)
    path=char(paths(k)); loaded=load(path,'result');
    if ~isfield(loaded,'result') || ~isstruct(loaded.result) || ...
            ~isfield(loaded.result,'metadata') || ~isfield(loaded.result,'signals')
        error('pendulumlab:LegacySchema','Expected result.metadata and result.signals in %s.',path);
    end
    old=loaded.result; m=old.metadata; s=old.signals;
    digest=pendulumlab.file_hash(path);
    % Preserve every imported signal, including historical extras, as columns.
    signalNames=fieldnames(s);
    for j=1:numel(signalNames)
        value=s.(signalNames{j});
        if isnumeric(value) || islogical(value), s.(signalNames{j})=value(:); end
    end
    if ~isfield(m,'experiment_id'), m.experiment_id='unknown_legacy_protocol'; end
    if ~isfield(m,'Ts'), m.Ts=NaN; end
    if ~isfield(m,'theta'), m.theta=[NaN NaN NaN]; end
    if ~isfield(m,'a'), m.a=NaN; end
    if ~isfield(m,'T'), m.T=NaN; end
    if ~isfield(m,'use_compensation'), m.use_compensation=NaN; end
    if ~isfield(m,'u_limits'), m.u_limits=[NaN NaN]; end
    if ~isfield(m,'rng_seed'), m.rng_seed=NaN; end
    m.hardware_id='original_propeller';
    m.model_hardware_id='original_propeller';
    m.model_id='legacy_original_theta';
    m.source_class='legacy';
    m.recording_kind='physical';
    m.source_file=path;
    m.source_sha256=digest;
    m.imported_utc=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z'''));
    m.repetition_status='single historical recording; not a repeat';
    m.legacy_trial_id=['legacy-' digest(1:16)];
    status=struct('code','legacy_imported','reason','Historical acquisition; original completion status retained in source file.', ...
        'read_count',NaN,'write_count',NaN,'stop_requested',false,'stop_succeeded',NaN, ...
        'link_closed',NaN,'exception','');
    if isfield(old,'status'), status.legacy_source_status=old.status; end
    runs(k)=struct('schema_version','pendulumlab.run/1','recording_kind','physical', ...
        'metadata',m,'signals',s,'metrics',getfieldOr(old,'metrics',struct()), ... %#ok<GFLD>
        'status',status,'provenance',struct('source_sha256',digest,'source_file',path, ...
        'source_class','historical legacy recording','importer','pendulumlab.import_legacy'));
end
end

function r=emptyRun()
r=struct('schema_version','','recording_kind','','metadata',struct(),'signals',struct(), ...
    'metrics',struct(),'status',struct(),'provenance',struct());
end

function value=getfieldOr(s,name,default)
if isfield(s,name), value=s.(name); else, value=default; end
end
