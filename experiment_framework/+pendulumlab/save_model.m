function path = save_model(record,registryDir)
%SAVE_MODEL Immutable hash-manifested registry JSON. Existing IDs are never overwritten.
arguments
 record (1,1) struct
 registryDir (1,1) string
end
assert(isfield(record,'model_id')&&~isempty(record.model_id),'pendulumlab:ModelId','Record needs model_id.');
registryDir=char(registryDir);[allowed,reason]=pendulumlab.output_location_allowed(registryDir,'mock');assert(allowed,'pendulumlab:RegistryPath','%s',reason);
if ~isfolder(registryDir),mkdir(registryDir);end
id=char(record.model_id);assert(~contains(id,filesep)&&~contains(id,'..'),'pendulumlab:ModelId','Unsafe model ID.');
path=fullfile(registryDir,[id '.json']);manifestPath=fullfile(registryDir,[id '.sha256']);
assert(~isfile(path)&&~isfile(manifestPath),'pendulumlab:Immutable','Model ID already exists; registry entries are immutable.');
tmp=[tempname(registryDir) '.json'];fid=fopen(tmp,'w');assert(fid>=0,'pendulumlab:Registry','Cannot create temporary record.');c=onCleanup(@()fclose(fid));fwrite(fid,jsonencode(record),'char');clear c;
[ok,msg]=movefile(tmp,path);assert(ok,'pendulumlab:Registry','Cannot commit model record: %s',msg);
digest=pendulumlab.file_hash(path);mtmp=[tempname(registryDir) '.sha256'];fid=fopen(mtmp,'w');assert(fid>=0,'pendulumlab:Registry','Cannot create temporary hash manifest.');c=onCleanup(@()fclose(fid));fprintf(fid,'%s  %s\n',digest,[id '.json']);clear c;
[ok,msg]=movefile(mtmp,manifestPath);assert(ok,'pendulumlab:Registry','Cannot commit model hash manifest: %s',msg);
end
