function record = load_model(modelId,registryDir)
%LOAD_MODEL Load a registry record only when its immutable hash verifies.
arguments
    modelId (1,1) string
    registryDir (1,1) string
end
registryDir=char(registryDir);id=char(modelId);assert(~contains(id,filesep)&&~contains(id,'..'),'pendulumlab:ModelId','Unsafe model ID.');
path=fullfile(registryDir,[id '.json']);mf=fullfile(registryDir,[id '.sha256']);
assert(isfile(path)&&isfile(mf),'pendulumlab:RegistryMissing','Record or hash manifest missing.');
expected=strtrim(extractBefore(string(fileread(mf)),"  "));actual=string(pendulumlab.file_hash(path));
assert(expected==actual,'pendulumlab:RegistryHash','Model record hash mismatch; refusing altered record.');
record=jsondecode(fileread(path));assert(string(record.model_id)==modelId,'pendulumlab:RegistryIdentity','Record ID mismatch.');
record.registry_file_hash=char(actual);record.registry_path=path;
end


