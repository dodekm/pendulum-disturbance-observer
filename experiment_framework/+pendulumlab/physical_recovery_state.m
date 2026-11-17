function state=physical_recovery_state(campaignRoot,recoverySeconds,nowUtc)
%PHYSICAL_RECOVERY_STATE Read-only cross-campaign physical recovery gate.
% Scan hardware campaign manifests under campaignRoot. Any unresolved or
% malformed physical status blocks; otherwise require recoverySeconds after
% the latest terminal physical recording. This function never sleeps or opens
% hardware.
arguments
    campaignRoot (1,1) string
    recoverySeconds (1,1) double {mustBeFinite,mustBePositive}
    nowUtc (1,1) datetime = datetime('now','TimeZone','UTC')
end
state=struct('ready',false,'blocked',true,'reason','','remaining_s',Inf,'latest_finished_utc','');
try
    if isnat(nowUtc)||strlength(string(nowUtc.TimeZone))==0
        error('pendulumlab:RecoveryClock','nowUtc must be a valid timezone-aware datetime.');
    end
    nowUtc.TimeZone='UTC';
    root=char(java.io.File(char(campaignRoot)).getCanonicalPath());
    if ~isfolder(root),error('pendulumlab:RecoveryRoot','Physical campaign root does not exist.');end
    folders=dir(root);latest=NaT(1,1,'TimeZone','UTC');
    for k=1:numel(folders)
        if ~folders(k).isdir||any(strcmp(folders(k).name,{'.','..'})),continue,end
        campaignDir=fullfile(root,folders(k).name);
        manifestPath=fullfile(campaignDir,'campaign_manifest.json');
        statusPath=fullfile(campaignDir,'campaign_status.json');
        if ~isfile(manifestPath)
            if isfile(statusPath)
                state=blocked(state,sprintf('Status exists without a manifest in %s.',folders(k).name));return
            end
            continue
        end
        try
            manifest=jsondecode(fileread(manifestPath));
        catch err
            state=blocked(state,sprintf('Malformed manifest in %s: %s',folders(k).name,err.message));return
        end
        if ~isfield(manifest,'recording_mode')
            state=blocked(state,sprintf('Manifest lacks recording_mode in %s.',folders(k).name));return
        end
        if ~strcmpi(char(string(manifest.recording_mode)),'hardware'),continue,end
        if ~isfile(statusPath)
            state=blocked(state,sprintf('Hardware campaign %s has no campaign_status.json.',folders(k).name));return
        end
        try
            status=jsondecode(fileread(statusPath));
        catch err
            state=blocked(state,sprintf('Malformed status for hardware campaign %s: %s',folders(k).name,err.message));return
        end
        if ~isfield(manifest,'campaign_id')||~isfield(status,'campaign_id')|| ...
                ~strcmp(char(string(manifest.campaign_id)),char(string(status.campaign_id)))
            state=blocked(state,sprintf('Campaign identity mismatch in %s.',folders(k).name));return
        end
        if ~isfield(manifest,'runs')||~isstruct(manifest.runs)||isempty(manifest.runs)|| ...
                ~isfield(status,'runs')||~isstruct(status.runs)||isempty(status.runs)
            state=blocked(state,sprintf('Missing or malformed run inventory in hardware campaign %s.',folders(k).name));return
        end
        if ~all(isfield(manifest.runs,'run_id'))||~all(isfield(status.runs,{'run_id','code','started_utc','finished_utc'}))
            state=blocked(state,sprintf('Incomplete run status fields in hardware campaign %s.',folders(k).name));return
        end
        expected=sort(string({manifest.runs.run_id}));observed=sort(string({status.runs.run_id}));
        if any(strlength(expected)==0)||any(strlength(observed)==0)|| ...
                numel(unique(expected))~=numel(expected)||numel(unique(observed))~=numel(observed)|| ...
                ~isequal(expected,observed)
            state=blocked(state,sprintf('Run inventory mismatch in hardware campaign %s.',folders(k).name));return
        end
        for j=1:numel(status.runs)
            row=status.runs(j);code=char(string(row.code));
            startedText=strtrim(char(string(row.started_utc)));
            finishedText=strtrim(char(string(row.finished_utc)));
            runId=char(string(row.run_id));
            if isempty(code)
                state=blocked(state,sprintf('Empty status code for %s/%s.',folders(k).name,runId));return
            end
            if strcmp(code,'running')
                state=blocked(state,sprintf('Physical recording %s/%s is still marked running.',folders(k).name,runId));return
            end
            if strcmp(code,'planned')
                if ~isempty(startedText)||~isempty(finishedText)
                    state=blocked(state,sprintf('Planned run %s/%s has start/finish timestamps.',folders(k).name,runId));return
                end
                continue
            end
            if ~any(strcmp(code,{'completed','aborted','fault','interlock','blocked'}))
                state=blocked(state,sprintf('Unknown or nonterminal status %s for %s/%s.', ...
                    code,folders(k).name,runId));return
            end
            if isempty(startedText)||isempty(finishedText)
                state=blocked(state,sprintf('Started physical run %s/%s has no terminal finish timestamp.',folders(k).name,runId));return
            end
            try
                started=pendulumlab.parse_utc(startedText);finished=pendulumlab.parse_utc(finishedText);
                if ~isscalar(started)||~isscalar(finished)||isnat(started)||isnat(finished)||finished<started
                    error('Invalid or reversed start/finish timestamp.');
                end
                if started>nowUtc+seconds(1)||finished>nowUtc+seconds(1)
                    error('Start or finish timestamp is in the future.');
                end
            catch err
                state=blocked(state,sprintf('Bad timestamps for %s/%s: %s',folders(k).name,runId,err.message));return
            end
            if isnat(latest)||finished>latest,latest=finished;end
        end
    end
    if ~isnat(latest)
        state.latest_finished_utc=char(string(latest,'yyyy-MM-dd''T''HH:mm:ss.SSSXXX'));
        state.remaining_s=max(0,recoverySeconds-seconds(nowUtc-latest));
    else
        state.remaining_s=0;
    end
    state.blocked=false;state.ready=state.remaining_s<=0;
    if ~state.ready
        state.reason=sprintf('Cross-campaign physical recovery remains: %.3f s of %.3f s required since %s.', ...
            state.remaining_s,recoverySeconds,state.latest_finished_utc);
    end
catch err
    state=blocked(state,sprintf('Recovery scan failed closed: %s',err.message));
end
end

function state=blocked(state,reason)
state.ready=false;state.blocked=true;state.reason=char(reason);state.remaining_s=Inf;
end
