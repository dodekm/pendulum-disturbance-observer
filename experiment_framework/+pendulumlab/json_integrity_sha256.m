function digest=json_integrity_sha256(value)
%JSON_INTEGRITY_SHA256 Digest a stable MATLAB JSON round-trip representation.
% MATLAB collapses singleton arrays and decodes scalar null as []. Normalize
% to a fixed point before hashing so saved reports verify after reloading.
% Nonfinite scientific settings must also have an explicit textual replay
% representation: this integrity encoding is not a lossless numeric codec.
encoded=jsonencode(value);stable=false;
for k=1:64
    next=jsonencode(jsondecode(encoded));
    if strcmp(encoded,next),stable=true;break,end
    encoded=next;
end
assert(stable,'pendulumlab:JsonCanonicalization','JSON normalization did not reach a stable representation.');
md=java.security.MessageDigest.getInstance('SHA-256');
md.update(uint8(unicode2native(encoded,'UTF-8')));
digest=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
end
