function report=identify_pendulum_campaign(options)
%IDENTIFY_PENDULUM_CAMPAIGN Offline identification after staged commissioning.
% No UART, firmware edits, manuscript edits, model promotion, or hidden exclusions.
arguments
    options.Labels (1,:) string = ["revision_id_03","revision_ringdown_01","revision_static_01", ...
        "revision_static_02","revision_angle_calibration_01","revision_angle90_02"]
    options.Starts (1,1) double {mustBeInteger,mustBePositive} = 8
    options.MaxIterations (1,1) double {mustBeInteger,mustBePositive} = 180
end
s.root=fileparts(mfilename('fullpath'));s.starts=options.Starts;s.seed=181;s.substeps=8;
s.friction_velocity_rad_s=.03;s.max_iterations=options.MaxIterations;
s.labels=cellstr(options.Labels);assert(numel(unique(options.Labels))==numel(options.Labels),'Duplicate campaign labels.');
addpath(fullfile(s.root,'experiment_framework'));addpath(fullfile(s.root,'experiment_framework','analyses'));
output=fullfile(s.root,'experiment_data','campaign_v2','identification_results', ...
    ['identification_' char(datetime('now','Format','yyyyMMdd_HHmmss'))]);
assert(~isfolder(output));mkdir(output);diary(fullfile(output,'analysis.log'));guard=onCleanup(@()diary('off'));
fprintf('OFFLINE IDENTIFICATION: %s\n',output);
D=struct([]);n=0;notUsed=cell(0,1);
for a=1:numel(s.labels)
    pointer=jsondecode(fileread(fullfile(s.root,'experiment_data','campaign_v2','identification_campaigns',[s.labels{a} '.json'])));
    [m,folder]=localPointerManifest(pointer,s.root);
    status=jsondecode(fileread(fullfile(folder,'campaign_status.json')));
    for k=1:numel(m.runs)
        if ~strcmp(status.runs(k).code,'completed')
            notUsed{end+1}=struct('run_id',m.runs(k).run_id,'status',status.runs(k).code,'reason','No complete physical recording.');continue %#ok<AGROW>
        end
        path=fullfile(folder,'runs',[m.runs(k).run_id '.mat']);r=pendulumlab.load_runs(string(path));
        assert(strcmp(r.recording_kind,'physical')&&all(r.signals.read_valid)&&all(r.signals.write_succeeded));
        assert(strcmp(r.metadata.hardware_id,m.hardware_id));
        n=n+1;d=struct;d.label=s.labels{a};d.protocol=r.metadata.experiment_id;
        d.run_id=m.runs(k).run_id;d.raw_file=path;d.raw_sha256=r.provenance.source_sha256;d.hardware_id=r.metadata.hardware_id;
        d.t=double(r.signals.t(:));d.u=double(r.signals.u_command(:));d.raw_y=double(r.signals.angle(:));
        assert(all(isfinite([d.t;d.u;d.raw_y])));
        assert(all(round(double(r.signals.t_device(:))/.05)==(0:numel(d.t)-1)'),'Nonconsecutive device ticks.');
        prefix=d.t<5&d.u==0;assert(sum(prefix)>=30);d.baseline_rad=mean(d.raw_y(prefix));
        d.y=d.raw_y-d.baseline_rad;d.initial_velocity=0;
        last=find(d.u>0,1,'last');d.last_positive_s=d.t(last);
        d.fit_mask=d.t>=5&d.t<=min(d.t(end),d.last_positive_s+20);
        d.train=~strcmp(d.protocol,'identification_prbs');
        if n==1,D=d;else,D(n)=d;end
    end
end
assert(n>=7&&numel(unique(string({D.hardware_id})))==1&&numel(unique(string({D.run_id})))==n);
train=find([D.train]);stress=find(~[D.train]);assert(numel(stress)==1);
report=struct('status','exploratory_identification_not_validated_not_promoted','settings',s, ...
    'output_folder',output,'script_sha256',pendulumlab.file_hash([mfilename('fullpath') '.m']), ...
    'simulator_sha256',pendulumlab.file_hash(which('simulate_identification_model')), ...
    'data',rmfield(D,{'t','u','y','raw_y','fit_mask'}),'not_used',{notUsed}, ...
    'method',struct('angle_reference','Per-record offset fixed from first five zero-command seconds; no test-output-based offset fit.', ...
    'initial_velocity','Zero after the passed rest gate for complete-record fits; return-window velocity is a nuisance fit.', ...
    'training_objective','Equal run weighting; residual / sqrt(number of scored samples in run). Score t>=5 to last positive command +20 s or recording end. Boundaries use commands only.', ...
    'stress_case','Original PRBS is a retrospective stress case, already inspected during model development, not independent validation.', ...
    'constraints','Nonnegative damping, gains, lag and friction; positive alpha. No finite physical upper bounds invented.', ...
    'integration','RK4 with exact held-input force lag at stages; adaptive substeps for friction stiffness and convergence check.', ...
    'scope','Diagnostic model extensions do not change the manuscript controller/DOB or calibrated input definition.'));

% Separate large zero-command return fits constrain mechanics without fitting
% the command map or actuator time constant. First second after shutdown omitted.
returns=find(ismember({D.label},{'revision_angle_calibration_01','revision_angle90_02', ...
    'revision_dynamic45_01','revision_dynamic60_01','revision_dynamic60_02'}));B=struct([]);assert(numel(returns)>=2);
for j=1:numel(returns)
    k=returns(j);d=D(k);ix=find(d.t>=d.last_positive_s+1.05&d.t<=d.last_positive_s+21.05);
    b=d;b.t=d.t(ix)-d.t(ix(1));b.y=d.y(ix);b.u=zeros(size(ix));b.fit_mask=true(size(ix));
    if j==1,B=b;else,B(j)=b;end
end
fprintf('Fitting effective mechanics on %d command-zero returns...\n',numel(returns));
mechVis=fitMechanics(B,false,s);mechFric=fitMechanics(B,true,s);
report.mechanics=struct('viscous',mechVis,'viscous_and_smooth_coulomb',mechFric, ...
    'scope','Effective command-zero dynamics only. Unknown zero-floor thrust/reference and fixed smoothing confound a physical friction interpretation.');
save(fullfile(output,'progress.mat'),'report','D','B');
fprintf('MECHANICS viscous [%g %g]; with friction [%g %g %g]\n',mechVis.parameters,mechFric.parameters);

% Seed forcing from fixed plateau-window means; these are initializers, not
% independently verified static equilibria or physical thrust calibration.
us=[];ys=[];
for label={'revision_static_01','revision_static_02','revision_angle_calibration_01'}
    q=jsondecode(fileread(fullfile(s.root,'experiment_data','campaign_v2','identification_campaigns',[label{1} '.json'])));
    [m,folder]=localPointerManifest(q,s.root);k=find(strcmp({D.label},label{1}),1);
    z=load(fullfile(folder,m.runs(1).schedule_file),'schedule');
    ranges=z.schedule.excitation.plateau_ranges_s;levels=z.schedule.excitation.plateau_commands;
    for j=1:numel(levels)
        ix=D(k).t>=ranges(j,2)-min(10,diff(ranges(j,:)))&D(k).t<ranges(j,2);
        if ~all(D(k).u(ix)==levels(j)),continue,end
        us(end+1,1)=levels(j);ys(end+1,1)=mean(sin(D(k).y(ix))); %#ok<AGROW>
    end
end

g=lsqnonneg([us us.^2/50],ys)*mechFric.parameters(1);
report.static_seed=struct('gamma1_gamma2',g','commands',us','mean_sin_relative_angle',ys', ...
    'note','Only an initializer; drift and oscillations prevent treating all points as exact equilibria.');
models=struct('name',{'nominal_linear','nonlinear_map','nonlinear_map_lag','map_lag_friction'}, ...
    'indices',{[1 2 3],[1 2 3 4],[1 2 3 4 5],[1 2 3 4 5 6]});
fits=cell(1,4);predictions=cell(1,4);
seed=[mechFric.parameters(1:2),g',.15,mechFric.parameters(3)];
for j=1:4
    fprintf('\nFULL MODEL %s\n',models(j).name);
    candidates=[seed;49.3401 .4569 .5586 0 0 0;52.9427 .23637 0 .69486 .167 0];
    previous=fullfile(s.root,'experiment_data','campaign_v2','identification_results','identification_20261106_155235','identification.mat');
    if isfile(previous)
        old=load(previous,'report');candidates=[candidates;old.report.models{j}.parameters_full];
        report.initializer_source=struct('path',previous,'sha256',pendulumlab.file_hash(previous));
    end
    if j>1,candidates=[candidates;fits{j-1}.parameters_full];end
    fits{j}=fitFull(D(train),models(j),candidates,s);
    predictions{j}=cell(1,n);scores=struct([]);
    for k=1:n
        [yh,~,inf1]=simulate_identification_model(fits{j}.parameters_full,D(k).t,D(k).u,[0;D(k).y(1)],s.substeps,s.friction_velocity_rad_s);
        yh2=simulate_identification_model(fits{j}.parameters_full,D(k).t,D(k).u,[0;D(k).y(1)],2*s.substeps,s.friction_velocity_rad_s);
        predictions{j}{k}=yh+D(k).baseline_rad;e=yh-D(k).y;ix=D(k).fit_mask;
        sc=metrics(e(ix),D(k).y(ix));sc.run_id=D(k).run_id;sc.train=D(k).train;
        sc.full_record_rmse_deg=rad2deg(sqrt(mean(e.^2)));
        sc.substep_doubling_max_abs_deg=rad2deg(max(abs(yh-yh2)));sc.substeps_used=inf1.substeps_used;
        if k==1,scores=sc;else,scores(k)=sc;end
    end
    fits{j}.per_run=scores;
    fprintf('RESULT %s p=%s; train run-mean RMSE %.3f deg; PRBS %.3f deg\n',models(j).name, ...
        mat2str(fits{j}.parameters_full,6),mean([scores(train).rmse_deg]),scores(stress).rmse_deg);
    report.models=fits;save(fullfile(output,'progress.mat'),'report','D','B','predictions');
end
report.models=fits;report.nominal_theta=fits{1}.parameters_full(1:3);
report.nominal_model_status='candidate_only_not_validated_for_control';
report.limitations={'All records have been inspected: no prospectively untouched validation exists.', ...
    'One recording per condition is not repeatability; covariance from correlated residuals is not a physical confidence interval.', ...
    'Constant-command oscillation growth and drift can remain unexplained by these deterministic positive-damping models.', ...
    'Fitted command map/lag/friction describe effective motion; thrust, RPM and actuator application time are unmeasured.', ...
    'The three-parameter nominal fit remains distinct from diagnostic model extensions; no registry promotion or controller change.'};
for k=1:n,assert(strcmp(pendulumlab.file_hash(D(k).raw_file),D(k).raw_sha256));end
report.raw_hashes_verified_after_fit=true;
archive=fullfile(output,'analysis_source_used.zip');
zip(archive,{'identify_pendulum_campaign.m','experiment_framework/analyses/simulate_identification_model.m'},s.root);
report.analysis_source_archive_sha256=pendulumlab.file_hash(archive);
save(fullfile(output,'identification.mat'),'report','D','B','predictions','-v7.3');
fid=fopen(fullfile(output,'identification.json'),'wt');fprintf(fid,'%s',jsonencode(report,PrettyPrint=true));fclose(fid);
delete(fullfile(output,'progress.mat'));
show=[find(strcmp({D.label},'revision_static_02')),returns,stress];show=unique(show,'stable');
f=figure('Visible','off','Color','w','Position',[60 60 1300 300*ceil(numel(show)/2)]);
tiledlayout(f,ceil(numel(show)/2),2,'TileSpacing','compact');
for a=1:numel(show)
    k=show(a);nexttile;plot(D(k).t,rad2deg(D(k).raw_y),'k','LineWidth',1);hold on;
    for j=[1 3 4],plot(D(k).t,rad2deg(predictions{j}{k}),'LineWidth',.9);end
    grid on;xlabel('t [s]');ylabel('y [deg]');title(strrep(D(k).label,'_',' '));
    if a==1,legend('Measured','Nominal linear','Nonlinear map + lag','Map + lag + friction','Location','best');end
end
savefig(f,fullfile(output,'model_responses.fig'));print(f,fullfile(output,'model_responses.eps'),'-depsc','-painters');
exportgraphics(f,fullfile(tempdir,'pendulum_campaign_identification.png'),'Resolution',150);close(f);
fprintf('\nNOMINAL theta %s\nOUTPUT %s\n',mat2str(report.nominal_theta,8),output);
end

function [manifest,folder]=localPointerManifest(pointer,root)
% The pointer's absolute path is retained as provenance; read the local copy.
normalized=regexprep(strrep(char(pointer.manifest_path),'\','/'),'/+','/');
token=regexp(normalized,'/campaigns/(cmp_[A-Za-z0-9]+)/campaign_manifest\.json$','tokens','once');
assert(numel(token)==1,'Invalid archived campaign-manifest path.');
folder=fullfile(root,'experiment_data','campaign_v2','campaigns',token{1});
path=fullfile(folder,'campaign_manifest.json');assert(isfile(path));
assert(isfield(pointer,'manifest_sha256')&&strcmpi(pendulumlab.file_hash(path),pointer.manifest_sha256), ...
    'Local identification campaign differs from its frozen pointer.');
manifest=jsondecode(fileread(path));assert(strcmp(manifest.campaign_id,token{1}));
end

function fit=fitMechanics(B,friction,s)
np=2+friction;scale=[60;.3];if friction,scale=[scale;.2];end
starts=[65 .2;66 .5;55 .2;75 .4];if friction,starts=[starts,.15*ones(4,1)];end
best=Inf;op=optimoptions('lsqnonlin','Display','off','FiniteDifferenceType','central','MaxIterations',s.max_iterations,'MaxFunctionEvaluations',3000);
for j=1:size(starts,1)
    q0=[starts(j,:)'./scale;zeros(numel(B),1)];lo=[1e-8;zeros(np-1,1);-inf(numel(B),1)];
    [q,cost,~,flag]=lsqnonlin(@(q)bodyResidual(q,scale,B,s),q0,lo,inf(size(q0)),op);
    fprintf(' mechanics %d SSE=%g p=%s exit=%d\n',j,cost,mat2str((q(1:np).*scale)',6),flag);
    if flag>0&&cost<best,best=cost;pick=q;bestFlag=flag;end
end
assert(isfinite(best));fit=struct('parameters',(pick(1:np).*scale)','initial_velocity_rad_s',pick(np+1:end)'*3, ...
    'equal_run_objective_rad2',best,'exitflag',bestFlag,'friction_velocity_rad_s',s.friction_velocity_rad_s);
end
function e=bodyResidual(q,scale,B,s)
np=numel(scale);p=zeros(1,6);p(1:2)=(q(1:2).*scale(1:2))';if np==3,p(6)=q(3)*scale(3);end
ee=cell(numel(B),1);
for k=1:numel(B)
    yy=simulate_identification_model(p,B(k).t,B(k).u,[q(np+k)*3;B(k).y(1)],s.substeps,s.friction_velocity_rad_s);
    e=yy-B(k).y;if any(~isfinite(e)),e=1e5*ones(size(e));end;ee{k}=e/sqrt(numel(e));
end
e=vertcat(ee{:});
end
function fit=fitFull(D,model,seeds,s)
ix=model.indices;scale=[60 .3 .6 .6 .15 .2];np=numel(ix);sc=scale(ix)';
qSeeds=seeds(:,ix);qSeeds=max(qSeeds,1e-5);stream=RandStream('mt19937ar','Seed',s.seed);
while size(qSeeds,1)<s.starts,qSeeds(end+1,:)=qSeeds(1,:).*10.^(-.15+.3*rand(stream,1,np));end %#ok<AGROW>
op=optimoptions('lsqnonlin','Display','off','FiniteDifferenceType','central','MaxIterations',s.max_iterations, ...
    'MaxFunctionEvaluations',3500,'FunctionTolerance',1e-9,'StepTolerance',1e-8);
best=Inf;attempts=cell(size(qSeeds,1),1);
for j=1:size(qSeeds,1)
    lo=zeros(np,1);lo(1)=1e-9;
    [q,cost,r,flag,info,~,J]=lsqnonlin(@(q)fullResidual(q,sc,ix,D,s),qSeeds(j,:)'./sc,lo,inf(np,1),op);
    pp=zeros(1,6);pp(ix)=(q.*sc)';attempts{j}=struct('parameters_full',pp,'objective_rad2',cost,'exitflag',flag,'iterations',info.iterations);
    fprintf(' start %d/%d obj=%g p=%s exit=%d\n',j,size(qSeeds,1),cost,mat2str(pp,6),flag);
    if flag>0&&cost<best,best=cost;pick=pp;bestFlag=flag;bestJ=full(J);bestR=r;end
end
assert(isfinite(best));sv=svd(bestJ.*(pick(ix)./scale(ix)),0);
fit=struct('name',model.name,'parameters_full',pick,'parameter_order',{{'alpha','beta','gamma1','gamma2','tau','coulomb'}}, ...
    'equal_run_objective_rad2',best,'exitflag',bestFlag,'starts',{attempts}, ...
    'relative_parameter_singular_values',sv','relative_parameter_condition',sv(1)/max(sv(end),realmin), ...
    'training_residual_norm',norm(bestR),'local_sensitivity_note','Conditioning only; no white-noise confidence interpretation.');
end
function e=fullResidual(q,scale,ix,D,s)
p=zeros(1,6);p(ix)=(q.*scale)';ee=cell(numel(D),1);
for k=1:numel(D)
    stop=find(D(k).fit_mask,1,'last');t=D(k).t(1:stop);u=D(k).u(1:stop);mask=D(k).fit_mask(1:stop);
    yh=simulate_identification_model(p,t,u,[0;D(k).y(1)],s.substeps,s.friction_velocity_rad_s);
    v=yh(mask)-D(k).y(find(mask));if any(~isfinite(v)),v=1e5*ones(size(v));end %#ok<FNDSB>
    ee{k}=v/sqrt(sum(mask));
end
e=vertcat(ee{:});
end
function m=metrics(e,y)
ac=NaN;if numel(e)>2,a=e(1:end-1)-mean(e(1:end-1));b=e(2:end)-mean(e(2:end));if norm(a)*norm(b)>0,ac=(a'*b)/(norm(a)*norm(b));end,end
m=struct('rmse_deg',rad2deg(sqrt(mean(e.^2))),'bias_deg',rad2deg(mean(e)), ...
    'peak_abs_error_deg',rad2deg(max(abs(e))),'mae_deg',rad2deg(mean(abs(e))), ...
    'fit_percent',100*(1-norm(e)/max(norm(y-mean(y)),eps)),'residual_acf1',ac,'scored_samples',numel(e));
end
