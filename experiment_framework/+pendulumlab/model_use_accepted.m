function tf=model_use_accepted(record)
%MODEL_USE_ACCEPTED Distinguish accuracy validation from limited empirical use.
tf=false;
if ~all(isfield(record,{'status','approval','validation'})),return,end
a=record.approval;v=record.validation;
if strcmp(record.status,'validated')
    tf=isfield(a,'accepted_for_control')&&isequal(a.accepted_for_control,true)&& ...
        isfield(v,'passed')&&isequal(v.passed,true);
elseif strcmp(record.status,'characterized')
    fields={'accepted_for_characterized_experiments','acknowledge_accuracy_failure', ...
        'accuracy_validation_passed','accepted_for_control','reason'};
    tf=all(isfield(a,fields))&&isequal(a.accepted_for_characterized_experiments,true)&& ...
        isequal(a.acknowledge_accuracy_failure,true)&&isequal(a.accuracy_validation_passed,false)&& ...
        isequal(a.accepted_for_control,false)&&strlength(string(a.reason))>0&& ...
        isfield(v,'passed')&&isequal(v.passed,false);
end
end
