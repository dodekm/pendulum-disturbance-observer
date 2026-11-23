function digest = file_hash(path)
%FILE_HASH SHA-256 of exact bytes; read-only provenance helper.
fid=fopen(path,'rb');assert(fid>=0,'pendulumlab:File','Cannot read %s',path);
guard=onCleanup(@()fclose(fid));
md=java.security.MessageDigest.getInstance('SHA-256');
while ~feof(fid)
    bytes=fread(fid,1048576,'*uint8');
    if ~isempty(bytes), md.update(bytes); end
end
digest=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
clear guard
end
