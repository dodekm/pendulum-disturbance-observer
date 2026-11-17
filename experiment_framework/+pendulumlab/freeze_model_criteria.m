function criteria = freeze_model_criteria(criteria,approver)
%FREEZE_MODEL_CRITERIA Timestamp and digest a pre-validation acceptance rule.
% This records the caller's rule; it is not a cryptographic signature.
arguments
 criteria (1,1) struct
 approver (1,1) string
end
assert(strlength(strtrim(approver))>0,'pendulumlab:CriteriaOwner','Name the person freezing the criterion.');
assert(isfield(criteria,'id')&&isfield(criteria,'max_candidate_rmse_rad')&&isfinite(criteria.max_candidate_rmse_rad)&&criteria.max_candidate_rmse_rad>=0, ...
 'pendulumlab:Criteria','Provide id and finite nonnegative max_candidate_rmse_rad.');
criteria.criteria_frozen=true;criteria.frozen_by=char(approver);
criteria.frozen_at_utc=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z'''));
criteria.criteria_sha256='';criteria.criteria_sha256=localHash(criteria);
end
function h=localHash(s),h=pendulumlab.json_integrity_sha256(s);end
