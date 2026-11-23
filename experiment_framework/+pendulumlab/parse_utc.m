function time=parse_utc(value)
%PARSE_UTC Parse an explicit ISO-8601 timezone, independent of MATLAB locale.
text=string(value);
assert(isscalar(text)&&strlength(text)>0,'pendulumlab:UtcTimestamp','Supply one ISO-8601 timestamp with timezone.');
formats=["yyyy-MM-dd'T'HH:mm:ss.SSSXXX","yyyy-MM-dd'T'HH:mm:ssXXX", ...
    "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'","yyyy-MM-dd'T'HH:mm:ss'Z'"];
for k=1:numel(formats)
    try
        candidate=datetime(text,'InputFormat',formats(k),'TimeZone','UTC');
        if ~isnat(candidate),time=candidate;return,end
    catch
    end
end
error('pendulumlab:UtcTimestamp','Unrecognized timestamp: use ISO-8601 with Z or an explicit timezone offset.');
end
