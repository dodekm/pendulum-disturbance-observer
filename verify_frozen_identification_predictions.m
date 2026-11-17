function result=verify_frozen_identification_predictions(outputDir)
%VERIFY_FROZEN_IDENTIFICATION_PREDICTIONS Replay frozen development predictors.
% Recomputes the recorded fit's predictions, objectives and command-defined
% phase diagnostics. It neither refits parameters nor modifies model status.
root=fileparts(mfilename('fullpath'));
addpath(fullfile(root,'experiment_framework'),fullfile(root,'experiment_framework','analyses'));
if nargin<1,outputDir="";end
source=fullfile(root,'experiment_data','campaign_v2','identification_results','identification_20261106_163437','identification.mat');
reg=jsondecode(fileread(fullfile(root,'experiment_framework','model_registry','calibrated_rig_20261106_173755.json')));
assert(strcmpi(pendulumlab.file_hash(source),reg.fit.source_report_sha256));
z=load(source,'report','D','predictions');frozen=z.report;D=z.D;
assert(numel(D)==10&&sum([D.train])==9&&numel(frozen.models)==4);
rowCells=cell(numel(D)*4*8,1);runCheckCells=cell(numel(D)*4,1);used=strings(numel(D),1);row=0;rc=0;
objectives=zeros(1,4);
for k=1:numel(D)
    relative=relativeDataPath(D(k).raw_file);p=fullfile(root,strrep(relative,'/',filesep));
    assert(isfile(p)&&strcmpi(pendulumlab.file_hash(p),D(k).raw_sha256));
    r=pendulumlab.load_runs(string(p));assert(strcmp(r.recording_kind,'physical')&&strcmp(r.status.code,'completed'));
    t=double(r.signals.t(:));u=double(r.signals.u_command(:));raw=double(r.signals.angle(:));
    assert(isequal(t,D(k).t(:))&&isequal(u,D(k).u(:))&&isequal(raw,D(k).raw_y(:)));
    prefix=t<5&u==0;assert(sum(prefix)>=30);
    offset=mean(raw(prefix));assert(abs(offset-D(k).baseline_rad)<1e-12);
    y=raw-offset;assert(max(abs(y-D(k).y(:)))<1e-12);
    last=find(u>0,1,'last');assert(~isempty(last));
    mask=t>=5&t<=min(t(end),t(last)+20);assert(isequal(mask,D(k).fit_mask(:)));
    used(k)=p;Ts=double(r.metadata.config.Ts);
    phases=commandPhases(r,t,u,raw,mask,last);
    for j=1:4
        f=frozen.models{j};parameters=double(f.parameters_full(:).');
        [yp,~,info]=simulate_identification_model(parameters,t,u,[0;y(1)],frozen.settings.substeps,frozen.settings.friction_velocity_rad_s);
        y2=simulate_identification_model(parameters,t,u,[0;y(1)],2*frozen.settings.substeps,frozen.settings.friction_velocity_rad_s);
        % The frozen plot arrays include the recorded angle offset; its
        % residuals and least-squares objective use offset-corrected angles.
        old=z.predictions{j}{k}(:);difference=max(abs((yp+offset)-old));assert(difference<=1e-8);
        e=yp-y;metrics=score(e,mask);original=f.per_run(k);
        assert(strcmp(original.run_id,D(k).run_id));
        fields={'rmse_deg','mae_deg','bias_deg','peak_abs_error_deg'};
        for q=1:numel(fields),name=fields{q};assert(abs(metrics.(name)-original.(name))<1e-6);end
        doubled=rad2deg(max(abs(yp-y2)));assert(abs(doubled-original.substep_doubling_max_abs_deg)<1e-6);
        if D(k).train,objectives(j)=objectives(j)+mean(e(mask).^2);end
        rc=rc+1;check=struct('run_id',D(k).run_id,'model',f.name,'raw_file',p, ...
            'raw_sha256',D(k).raw_sha256,'train',D(k).train,'prediction_max_difference_rad',difference, ...
            'scored_samples',sum(mask),'rmse_deg',metrics.rmse_deg,'full_rmse_deg',rad2deg(sqrt(mean(e.^2))), ...
            'substep_doubling_max_abs_deg',doubled,'substeps_used',info.substeps_used); %#ok<AGROW>
        assert(isscalar(check));runCheckCells{rc}=check;
        assert(abs(check.full_rmse_deg-original.full_record_rmse_deg)<1e-6);
        names=fieldnames(phases);
        for q=1:numel(names)
            name=names{q};m=phases.(name);s=score(e,m);row=row+1;
            rowCells{row}=struct('run_id',D(k).run_id,'model',f.name,'train',D(k).train, ...
                'phase',name,'samples',sum(m),'duration_s',sum(m)*Ts,'rmse_deg',s.rmse_deg, ...
                'bias_deg',s.bias_deg,'mae_deg',s.mae_deg,'peak_abs_error_deg',s.peak_abs_error_deg); %#ok<AGROW>
        end
    end
end
assert(row==numel(rowCells)&&rc==numel(runCheckCells));
runChecks=vertcat(runCheckCells{:});rows=vertcat(rowCells{:});
for j=1:4,assert(abs(objectives(j)-frozen.models{j}.equal_run_objective_rad2)<1e-9);end
result=struct('schema_version','pendulumlab.frozen_development_replay/1','state','passed', ...
    'scope','Parameter-frozen prediction and objective replay, not a new identification, validation or approval.', ...
    'fit_report_sha256',pendulumlab.file_hash(source),'run_checks',runChecks,'recomputed_equal_run_objectives',objectives, ...
    'raw_files',used,'phase_metrics',rows,'phase_definitions', ...
    ['Post-prefix fit interval is t>=5 to last positive command+20 s or end. Command-zero return is all samples after the final positive command; ', ...
     'its scored subset is also shown. Powered multisine uses the frozen active interval and actual u_command>0. ', ...
     'Constant-command samples use unchanged adjacent raw commands within 1e-5 numerical units and exclude the multisine window; ', ...
     'remaining powered samples are changing-command samples. High-angle powered samples use measured raw angle>=75deg as an overlapping descriptive subset. ', ...
     'No phase is assumed to be a mechanical equilibrium; zero command does not establish zero thrust. ', ...
     'Empty phases have zero duration and NaN metrics (JSON null), not zero error. No phase metric is a new acceptance criterion.'], ...
    'script_sha256',pendulumlab.file_hash([mfilename('fullpath') '.m']));
if strlength(string(outputDir))>0
    [allowed,why]=pendulumlab.output_location_allowed(outputDir,'offline');assert(allowed,'%s',why);
    assert(~isfolder(outputDir),'Refusing to overwrite prior output.');mkdir(outputDir);
    save(fullfile(outputDir,'frozen_identification_replay.mat'),'result','-v7');
    writetable(struct2table(rows),fullfile(outputDir,'development_phase_metrics.csv'));
    fid=fopen(fullfile(outputDir,'frozen_identification_replay.json'),'w','n','UTF-8');assert(fid>=0);
    c=onCleanup(@()fclose(fid));fprintf(fid,'%s',jsonencode(result,PrettyPrint=true));clear c
end
end

function p=relativeDataPath(recorded)
p=regexprep(strrep(char(recorded),'\','/'),'/+','/');marker='/experiment_data/campaign_v2/';
k=strfind(p,marker);assert(numel(k)==1);p=p(k+1:end);assert(~contains(p,'..'));
end

function phases=commandPhases(r,t,u,angle,mask,last)
dynamic=false(size(t));protocol=r.metadata.config.protocol;
if isfield(protocol,'multisine_design')&&isfield(protocol.multisine_design,'active_interval_s')
    w=protocol.multisine_design.active_interval_s;dynamic=t>=w(1)&t<w(2)&u>0;
end
constant=false(size(t));constant(2:end-1)=abs(diff(u(1:end-1)))<1e-5&abs(diff(u(2:end)))<1e-5;
constant=constant&u>0&~dynamic;
changing=u>0&~constant&~dynamic;
phases=struct('fit_interval',mask,'positive_command',mask&u>0, ...
    'powered_constant_command',mask&constant,'powered_changing_command',mask&changing, ...
    'powered_multisine',mask&dynamic,'powered_angle_ge75deg',mask&u>0&angle>=deg2rad(75), ...
    'command_zero_return',t>t(last),'command_zero_scored_tail',mask&t>t(last));
end

function m=score(e,mask)
e=rad2deg(e(mask));m=struct('rmse_deg',NaN,'mae_deg',NaN,'bias_deg',NaN,'peak_abs_error_deg',NaN);
if isempty(e),return,end
m.rmse_deg=sqrt(mean(e.^2));m.mae_deg=mean(abs(e));m.bias_deg=mean(e);m.peak_abs_error_deg=max(abs(e));
end
