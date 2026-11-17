function audit=review_campaign_hold(manifestPath,decision)
%REVIEW_CAMPAIGN_HOLD Append immutable human review before campaign continuation.
% This never retries a failed run. A replacement/retry requires a distinct run
% ID and its own documented plan.
arguments
    manifestPath (1,1) string
    decision (1,1) struct
end
required={'run_id','reviewer_id','cause','resolution','allow_continue'};
for k=1:numel(required)
    if ~isfield(decision,required{k}), error('pendulumlab:Review','Decision requires %s.',required{k}); end
end
if strlength(strtrim(string(decision.reviewer_id)))==0|| ...
        strlength(strtrim(string(decision.cause)))==0|| ...
        strlength(strtrim(string(decision.resolution)))==0|| ...
        ~islogical(decision.allow_continue)||~isscalar(decision.allow_continue)
    error('pendulumlab:Review','Reviewer, cause, resolution, and scalar allow_continue are required.');
end
path=char(manifestPath); folder=fileparts(path);
manifestHash=strtrim(fileread(fullfile(folder,'campaign_manifest.sha256')));
if ~strcmpi(manifestHash,pendulumlab.file_hash(path))
    error('pendulumlab:ManifestHash','Frozen campaign manifest checksum mismatch.');
end
manifest=jsondecode(fileread(path));
[allowed,why]=pendulumlab.output_location_allowed(folder,char(manifest.recording_mode));
if ~allowed, error('pendulumlab:OutputLocation','%s',why); end
runIds=string({manifest.runs.run_id}); id=string(decision.run_id);
if ~any(runIds==id), error('pendulumlab:Review','run_id does not belong to this manifest.'); end
status=jsondecode(fileread(fullfile(folder,'campaign_status.json')));
ix=find(strcmp({status.runs.run_id},char(id)),1);
if isempty(ix)||~any(string(status.runs(ix).code)==["aborted","fault","interlock","blocked"])
    error('pendulumlab:Review','Only an abnormal terminal run can be reviewed.');
end
if isfield(decision,'replacement_run_id')&&strlength(string(decision.replacement_run_id))>0&& ...
        strcmp(char(decision.replacement_run_id),char(id))
    error('pendulumlab:Review','A replacement/retry must use a distinct run ID.');
end
resultPath=fullfile(folder,'runs',[char(id) '.mat']);
checkpointPath=fullfile(folder,'runs',[char(id) '.checkpoint.mat']);
if isfile(resultPath), evidencePath=resultPath;
elseif isfile(checkpointPath), evidencePath=checkpointPath;
else, evidencePath=''; end
resultHash=''; if ~isempty(evidencePath), resultHash=pendulumlab.file_hash(evidencePath); end
audit=struct('schema_version','pendulumlab.review/1','review_id',['review_' uuid_text()], ...
    'campaign_id',manifest.campaign_id,'manifest_sha256',manifestHash, ...
    'run_id',char(id),'original_status',char(status.runs(ix).code), ...
    'original_reason',char(status.runs(ix).reason),'reviewer_id',char(decision.reviewer_id), ...
    'cause',char(decision.cause),'resolution',char(decision.resolution), ...
    'allow_continue',logical(decision.allow_continue), ...
    'replacement_run_id',char(getfield_default(decision,'replacement_run_id','')), ...
    'result_file',evidencePath,'result_sha256',resultHash, ...
    'reviewed_utc',char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss.SSSXXX')));
reviewFolder=fullfile(folder,'reviews'); if ~isfolder(reviewFolder), mkdir(reviewFolder); end
reviewPath=fullfile(reviewFolder,[audit.review_id '.json']);
write_json_create(reviewPath,audit); audit.audit_path=reviewPath;
hash=pendulumlab.file_hash(reviewPath);
write_text_create([reviewPath '.sha256'],[hash newline]);
end
function write_text_create(path,text)
fid=fopen(path,'wt');if fid<0,error('pendulumlab:Review','Cannot create review checksum.');end
guard=onCleanup(@()fclose(fid));fwrite(fid,text,'char');clear guard
end
function write_json_create(path,value)
folder=fileparts(path);tmp=[tempname(folder) '.json'];fid=fopen(tmp,'wt');
if fid<0,error('pendulumlab:Review','Cannot create review record.');end
guard=onCleanup(@()fclose(fid));fwrite(fid,jsonencode(value),'char');clear guard
if isfile(path),delete(tmp);error('pendulumlab:Review','Review record already exists.');end
[ok,msg]=movefile(tmp,path);if ~ok,if isfile(tmp),delete(tmp);end,error('pendulumlab:Review','Review write failed: %s',msg);end
end
function id=uuid_text()
id=erase(char(java.util.UUID.randomUUID()),'-');
end
function v=getfield_default(s,name,d)
if isfield(s,name),v=s.(name);else,v=d;end
end
