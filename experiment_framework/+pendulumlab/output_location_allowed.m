function [allowed,reason]=output_location_allowed(folder,mode)
%OUTPUT_LOCATION_ALLOWED Keep new artifacts away from protected project assets.
allowed=false;reason='';
try
    target=char(java.io.File(char(folder)).getCanonicalPath());
    root=pendulumlab.project_root();
    physicalRoot=fullfile(root,'experiment_data','campaign_v2');
    if strcmp(mode,'hardware')
        allowed=inside(target,physicalRoot);
        if ~allowed,reason='Physical campaign outputs must be under experiment_data/campaign_v2';end
        return
    end
    protected={'Arduino','+uartlink','review','publication_results','Definitions', ...
        'submission','tests','archive','experiment_data'};
    for k=1:numel(protected)
        if inside(target,fullfile(root,protected{k}))
            reason=['Output folder is inside protected ' protected{k}];return
        end
    end
    if strcmpi(target,root)
        reason='Use a separate new campaign/output folder, not the project root';return
    end
    allowed=true;
catch err
    reason=['Invalid output location: ' err.message];
end
end
function tf=inside(child,parent)
parent=char(java.io.File(parent).getCanonicalPath());
tf=strcmpi(child,parent)||startsWith(lower([child filesep]),lower([parent filesep]));
end
