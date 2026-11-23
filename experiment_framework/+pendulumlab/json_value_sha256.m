function digest=json_value_sha256(value)
%JSON_VALUE_SHA256 SHA-256 over MATLAB's UTF-8 JSON representation.
text=jsonencode(value); md=java.security.MessageDigest.getInstance('SHA-256');
md.update(uint8(unicode2native(text,'UTF-8')));
digest=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
end
