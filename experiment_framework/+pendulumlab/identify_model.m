function [candidate,report] = identify_model(runs,opts)
%IDENTIFY_MODEL Scaled constrained multi-start free-run output-error fitting.
% Uses complete recorded u_command with the shared sample/hold convention.
% Caller supplies sign-preserving theta_bounds; upper bounds may be Inf when
% explicit finite theta_scale values are supplied for numerical conditioning.
% Scales and starting-point spread are not physical parameter bounds.
if nargin<2, opts=struct(); end
opts=localMerge(struct('theta_bounds',[],'theta_scale',[],'theta0',[49.3401 0.4569 0.5586],'multi_start',8,'substeps',4,'seed',173,'fit_initial_velocity',true,'velocity_scale',0.2,'velocity_bounds',[-Inf Inf],'fit_initial_angle_offset',false,'initial_angle_bounds',[-Inf Inf],'max_iterations',250,'max_function_evaluations',12000,'compute_per_run_fits',true,'bootstrap_replicates',0,'bootstrap_block_samples',20,'bootstrap_method','whole_run','force_fallback',false,'integration_tolerance_rad',1e-4,'max_dimensionless_rk4_step',.5),opts);
assert(~isempty(runs),'pendulumlab:NoTrainingRuns','At least one complete informative training run is required.');
assert(isequal(size(opts.theta_bounds),[3 2]) && all(isfinite(opts.theta_bounds(:,1))) && ...
    all(~isnan(opts.theta_bounds(:,2))) && all(opts.theta_bounds(:,2)>opts.theta_bounds(:,1)), ...
    'pendulumlab:ThetaBounds','Supply finite lower and increasing finite or positive-infinite upper bounds.');
scale=localThetaScale(opts);
assert(isscalar(opts.integration_tolerance_rad)&&isfinite(opts.integration_tolerance_rad)&&opts.integration_tolerance_rad>0&& ...
    isscalar(opts.max_dimensionless_rk4_step)&&isfinite(opts.max_dimensionless_rk4_step)&& ...
    opts.max_dimensionless_rk4_step>0&&opts.max_dimensionless_rk4_step<=1,'pendulumlab:NumericalCriteria', ...
    'Specify a positive integration tolerance and numerical step indicator in (0,1].');
assert(opts.theta_bounds(1,1)>0&&opts.theta_bounds(2,1)>=0&&opts.theta_bounds(3,1)>0, ...
    'pendulumlab:PhysicalSigns','Bounds must preserve alpha>0, beta>=0 and gamma>0.');
assert(isscalar(opts.velocity_scale)&&isfinite(opts.velocity_scale)&&opts.velocity_scale>0, ...
    'pendulumlab:VelocityScale','Initial-velocity scale must be positive and finite.');
assert(any(strcmp(opts.bootstrap_method,{'whole_run','moving_block'})), ...
    'pendulumlab:BootstrapMethod','bootstrap_method must be whole_run or moving_block.');
assert(isequal(size(opts.theta0),[1 3])&&all(isfinite(opts.theta0))&& ...
    all(opts.theta0>=opts.theta_bounds(:,1).' & opts.theta0<=opts.theta_bounds(:,2).'), ...
    'pendulumlab:ThetaInitial','theta0 must lie inside caller-supplied bounds.');
if opts.fit_initial_angle_offset
    assert(all(isfinite(opts.initial_angle_bounds)) && opts.initial_angle_bounds(2)>opts.initial_angle_bounds(1), ...
        'pendulumlab:AngleBounds','Angle-offset fitting requires finite increasing caller-supplied bounds.');
end
D=localPrepare(runs);
if numel(unique(string({D.hardware_id})))>1
    error('pendulumlab:MixedHardware','Do not pool runs from different hardware identities.');
end
stream=RandStream('mt19937ar','Seed',opts.seed); n=numel(D); p=3+opts.fit_initial_velocity*n+opts.fit_initial_angle_offset*n;
[lo,hi]=localBounds(D,opts);
if any(lo>=hi), error('pendulumlab:Bounds','Nuisance bounds must have positive width.'); end
base=zeros(p,1); base(1:3)=((opts.theta0(:)-opts.theta_bounds(:,1))./scale);
starts=repmat(base,1,opts.multi_start); starts(:,1)=base;
if opts.multi_start>1
    rr=rand(stream,3,opts.multi_start-1);finiteUpper=isfinite(hi(1:3));
    for j=1:3
        if finiteUpper(j),starts(j,2:end)=hi(j)*rr(j,:);
        else,starts(j,2:end)=max(base(j),1e-3)*exp(log(3)*(2*rr(j,:)-1));end
    end
end
for j=2:opts.multi_start
    if opts.fit_initial_velocity
        starts(4:3+n,j)=0.1*randn(stream,n,1);
    end
end
starts=min(max(starts,lo),hi);
obj=@(qv)localResidual(qv,D,opts,lo,hi);
useLSQ=exist('lsqnonlin','file')==2 && ~opts.force_fallback;
best=Inf; bestQ=[]; bestExit=NaN; allStarts=repmat(struct('cost',NaN,'exitflag',NaN,'q',[], ...
    'substep_doubling_max_abs_rad',Inf,'numerically_admissible',false),opts.multi_start,1);
for j=1:opts.multi_start
    [qfit,cost,exitflag]=localOptimize(obj,starts(:,j),lo,hi,opts);
    th=opts.theta_bounds(:,1).'+qfit(1:3).'.*scale.';
    numericalError=localConvergence(D,th,opts,qfit);
    admissible=isfinite(numericalError)&&numericalError<=opts.integration_tolerance_rad;
    allStarts(j)=struct('cost',cost,'exitflag',exitflag,'q',qfit, ...
        'substep_doubling_max_abs_rad',numericalError,'numerically_admissible',admissible);
    if admissible&&isfinite(cost)&&((exitflag>0&&bestExit<=0)||cost<best&&(~(bestExit>0)||exitflag>0))
        best=cost;bestQ=qfit;bestExit=exitflag;
    end
end
if isempty(bestQ), error('pendulumlab:FitFailed','No finite multi-start fit satisfied the declared numerical integration criterion.'); end
[residual,trace]=localResidual(bestQ,D,opts,lo,hi);
assert(all(arrayfun(@(a)all(isfinite(a.yhat)),trace)),'pendulumlab:FitNonfinite', ...
    'The selected fit has nonfinite model predictions; it is not a candidate.');
theta=opts.theta_bounds(:,1).' + bestQ(1:3).'.*scale.';
S=localSensitivity(bestQ,D,opts,lo,hi,theta);
perRun=struct([]);
if opts.compute_per_run_fits
    perRun=repmat(struct('run_id','','theta',[],'initial_velocity_fit_rad_s',NaN,'initial_angle_offset_rad',NaN,'rmse_rad',NaN,'exitflag',NaN),n,1);
    for k=1:n
        sub=D(k); op=opts; op.compute_per_run_fits=false; op.bootstrap_replicates=0;
        [perRun(k).theta,perRun(k).initial_velocity_fit_rad_s,perRun(k).initial_angle_offset_rad,perRun(k).rmse_rad,perRun(k).exitflag]=localFitSingle(sub,theta,opts);
        perRun(k).run_id=D(k).run_id;
    end
end
boot=struct('method','disabled','replicates',0,'theta',[],'note','');
if opts.bootstrap_replicates>0
    boot=localBootstrap(D,theta,opts,bestQ);
end
boundsText=struct('lower',{cellstr(compose('%.17g',opts.theta_bounds(:,1)))}, ...
    'upper',{cellstr(compose('%.17g',opts.theta_bounds(:,2)))});
candidate=struct('schema_version','pendulumlab.model_candidate/1','model_id',['candidate_' char(datetime('now','Format','yyyyMMdd_HHmmss')) '_' char(java.util.UUID.randomUUID)], ...
    'status','candidate','theta',theta,'hardware_id',D(1).hardware_id, ...
    'fit',struct('objective','complete-run free-run output-error RMSE in radians','cost_sse_rad2',best, ...
        'rmse_rad',sqrt(mean(residual.^2)),'exitflag',bestExit,'converged',bestExit>0,'solver',localSolverName(useLSQ), ...
        'starts',{allStarts},'theta_bounds',opts.theta_bounds,'theta_bounds_text',boundsText, ...
        'theta_coordinate_scale',scale.','substeps',opts.substeps, ...
        'options',opts,'options_reproducible_json',localExactJson(opts), ...
        'matlab_version',version,'implementation_sha256',pendulumlab.file_hash([mfilename('fullpath') '.m']), ...
        'simulate_output_sha256',pendulumlab.file_hash(which('pendulumlab.simulate_output')), ...
        'substep_doubling_max_abs_rad',localConvergence(D,theta,opts,bestQ),'initial_states',localInitialStates(bestQ,D,opts)), ...
    'training',struct('run_ids',{string({D.run_id})},'raw_hashes',{string({D.raw_hash})},'source_files',{string({D.source_file})},'source_files_verified',{[D.source_file_verified]},'signal_sha256',{string({D.signal_sha256})}, ...
        'recording_kinds',{string({D.recording_kind})},'hardware_ids',{string({D.hardware_id})},'status_codes',{string({D.status_code})},'raw_hash_sha256',{[D.raw_hash_sha256]}, ...
        'run_count',n,'per_run',perRun), ...
    'diagnostics',struct('sensitivity',S,'residuals',localResidualDiagnostics(D,trace), ...
        'bootstrap',boot,'initial_state_note','Initial velocity is a per-run nuisance fit when enabled; initial angle is fixed to first sample unless explicitly fitted.', ...
        'numerical_scope','Open parameter bounds are subject to a declared computational RK4 step indicator and doubled-substep check, not physical upper priors. No model-adequacy or stability claim follows.'), ...
    'created_utc',char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z''')));
reportStatus='candidate_only';if bestExit<=0,reportStatus='candidate_fit_not_converged';end
report=struct('candidate_id',candidate.model_id,'status',reportStatus,'fit_converged',bestExit>0,'theta',theta, ...
    'hardware_id',D(1).hardware_id,'run_count',n,'rmse_rad',candidate.fit.rmse_rad, ...
    'solver',candidate.fit.solver,'identifiability',S,'physical_validation_performed',false, ...
    'control_approval_granted',false);
end

function D=localPrepare(runs)
proto=struct('run_id','','hardware_id','','recording_kind','','raw_hash','','source_file','','source_file_verified',false,'signal_sha256','','status_code','','raw_hash_sha256',false,'t',[],'y',[],'u',[]);
D=repmat(proto,numel(runs),1); ids=strings(numel(runs),1);
for k=1:numel(runs)
    r=runs(k); assert(isfield(r,'signals')&&isfield(r,'metadata'),'pendulumlab:RunSchema','Run lacks metadata/signals.');
    s=r.signals; m=r.metadata;
    assert(all(isfield(s,{'t','angle','u_command'})),'pendulumlab:RunSignals','Identification requires t, angle, and full transmitted u_command.');
    t=double(s.t(:));y=double(s.angle(:));u=double(s.u_command(:));
    assert(numel(t)==numel(y)&&numel(t)==numel(u)&&numel(t)>=10,'pendulumlab:RunLengths','Invalid run lengths.');
    assert(all(isfinite(t))&&all(diff(t)>0)&&all(isfinite(y))&&all(isfinite(u)),'pendulumlab:RunFinite','Run contains invalid/nonfinite input or output.');
    rid=localText(localGet(m,'run_id',localGet(m,'trial_id',sprintf('run_%03d',k))));
    hid=localText(localGet(m,'hardware_id','unknown_hardware')); kind=localText(localGet(r,'recording_kind','unknown'));
    prov=localGet(r,'provenance',struct()); hash=localText(localGet(prov,'source_sha256',localGet(m,'source_sha256','')));
    sourceFile=localText(localGet(prov,'source_file',''));
    if isempty(hash), hash=['unhashed_' rid]; end
    status=localText(localGet(localGet(r,'status',struct()),'code','unknown'));
    if isfield(s,'read_valid'), assert(all(logical(s.read_valid(:))),'pendulumlab:InvalidReadMask','Do not identify with invalid read samples.'); end
    if isfield(s,'write_succeeded'), assert(all(logical(s.write_succeeded(:))),'pendulumlab:InvalidWriteMask','Do not identify with failed command writes.'); end
    fileok=~isempty(sourceFile)&&isfile(sourceFile)&&~isempty(regexp(hash,'^[0-9a-fA-F]{64}$','once'));
    if fileok, fileok=strcmpi(pendulumlab.file_hash(sourceFile),hash); end
    if strcmp(kind,'physical'), assert(strcmp(status,'completed')&&fileok,'pendulumlab:PhysicalProvenance','Physical identification requires completed status and verified raw-file provenance.'); assert(localRawMatches(sourceFile,rid,hid,kind,status,t,y,u),'pendulumlab:RawRecordMismatch','In-memory physical signals/identity differ from the SHA-verified MAT record.'); end
    hashok=~isempty(regexp(hash,'^[0-9a-fA-F]{64}$','once'));
    sigHash=localHash(struct('t',t,'angle',y,'u_command',u));
    D(k)=struct('run_id',rid,'hardware_id',hid,'recording_kind',kind,'raw_hash',hash,'source_file',sourceFile,'source_file_verified',fileok,'signal_sha256',sigHash,'status_code',status,'raw_hash_sha256',hashok,'t',t,'y',y,'u',u); ids(k)=rid;
end
assert(numel(unique(ids))==numel(ids),'pendulumlab:DuplicateRun','Training run IDs must be unique.');
assert(numel(unique(string({D.raw_hash})))==numel(D),'pendulumlab:DuplicateHash','Training source hashes must be unique.');
assert(numel(unique(string({D.signal_sha256})))==numel(D),'pendulumlab:DuplicateSignal','Training run signal content must be unique.');
end
function [r,trace]=localResidual(q,D,o,lo,hi)
q=min(max(q,lo),hi); theta=o.theta_bounds(:,1).' + q(1:3).'.*localThetaScale(o).';
r=[]; trace=repmat(struct('yhat',[],'residual',[]),numel(D),1);
for k=1:numel(D)
    v0=0; if o.fit_initial_velocity, v0=q(3+k)*o.velocity_scale; end
    off=0; if o.fit_initial_angle_offset, off=q(3+double(o.fit_initial_velocity)*numel(D)+k); end
    yh=localPredict(theta,D(k).t,D(k).u,[v0;D(k).y(1)+off],o.substeps,o);
    e=yh-D(k).y;
    if any(~isfinite(e)),e=1e6*ones(size(e));end
    r=[r;e]; trace(k)=struct('yhat',yh,'residual',e); %#ok<AGROW>
end
end
function [qfit,cost,exitflag]=localOptimize(obj,q0,lo,hi,o)
if exist('lsqnonlin','file')==2 && ~o.force_fallback
 op=optimoptions('lsqnonlin','Display','off','MaxIterations',o.max_iterations, ...
  'MaxFunctionEvaluations',o.max_function_evaluations,'FiniteDifferenceType','central');
 [qfit,cost,~,exitflag]=lsqnonlin(obj,q0,lo,hi,op);
else
 z0=localToZ(q0,lo,hi);op=optimset('Display','off','MaxIter',o.max_iterations,'MaxFunEvals',o.max_function_evaluations,'TolX',1e-7,'TolFun',1e-10);
 [z,cost,exitflag]=fminsearch(@(zz)sum(obj(localFromZ(zz,lo,hi)).^2),z0,op);qfit=localFromZ(z,lo,hi);
end
end
function z=localToZ(q,lo,hi)
z=q;both=isfinite(lo)&isfinite(hi);lower=isfinite(lo)&~isfinite(hi);upper=~isfinite(lo)&isfinite(hi);
r=min(max((q(both)-lo(both))./(hi(both)-lo(both)),1e-10),1-1e-10);z(both)=log(r./(1-r));
z(lower)=log(max(q(lower)-lo(lower),1e-10));z(upper)=log(max(hi(upper)-q(upper),1e-10));
end
function q=localFromZ(z,lo,hi)
q=z;both=isfinite(lo)&isfinite(hi);lower=isfinite(lo)&~isfinite(hi);upper=~isfinite(lo)&isfinite(hi);
s=1./(1+exp(-max(min(z(both),35),-35)));q(both)=lo(both)+(hi(both)-lo(both)).*s;
q(lower)=lo(lower)+exp(z(lower));q(upper)=hi(upper)-exp(z(upper));
end
function S=localSensitivity(q,D,o,lo,hi,theta)
r=localResidual(q,D,o,lo,hi);J=zeros(numel(r),numel(q));
for j=1:numel(q)
 h=1e-5*max(1,abs(q(j)));qp=q;qm=q;qp(j)=min(q(j)+h,hi(j));qm(j)=max(q(j)-h,lo(j));
 if qp(j)==qm(j),continue,end;J(:,j)=(localResidual(qp,D,o,lo,hi)-localResidual(qm,D,o,lo,hi))/(qp(j)-qm(j));
end
ranges=localThetaScale(o);Jp=J;Jp(:,1:3)=J(:,1:3)./ranges.';
if o.fit_initial_velocity,Jp(:,4:3+numel(D))=J(:,4:3+numel(D))/o.velocity_scale;end
Jtheta=Jp(:,1:3);Jn=Jp(:,4:end);scale=max(abs(theta(:)),1e-6*ranges);Jdimensionless=Jtheta.*scale.';
if isempty(Jn),Jprofile=Jdimensionless;rankN=0;else,Jprofile=Jdimensionless-Jn*pinv(Jn)*Jdimensionless;rankN=rank(Jn);end
sv=svd(Jprofile,0);tol=max(size(Jprofile))*eps(max(sv));rankt=sum(sv>tol);if isempty(sv)||sv(end)==0,condv=Inf;else,condv=sv(1)/sv(end);end
C=corrcoef(Jprofile);if any(~isfinite(C(:))),C(:)=NaN;end
fullS=svd(Jp,0);fulltol=max(size(Jp))*eps(max(fullS));fullrank=sum(fullS>fulltol);
nearLower=(q(1:3)<=1e-4*max(1,abs(q(1:3)))).';
nearUpper=(isfinite(hi(1:3))&q(1:3)>=hi(1:3)-1e-4*max(1,abs(hi(1:3)))).';
S=struct('profiled_dimensionless_theta_singular_values',sv(:).','profiled_theta_rank',rankt, ...
 'profiled_theta_condition_number',condv,'profiled_theta_column_correlation',C, ...
 'theta_relative_scales_used',scale(:).','nuisance_jacobian_rank',rankN, ...
 'full_jacobian_singular_values',fullS(:).','full_jacobian_rank_including_nuisance',fullrank,'full_jacobian_columns',size(Jp,2), ...
 'theta_near_lower_bound',nearLower,'theta_near_upper_bound',nearUpper, ...
 'theta_identifiability_warning',rankt<3||condv>1e8||fullrank<size(Jp,2), ...
 'local_covariance_white_uncorrelated_residual_assumption_only',localCov(Jp,r), ...
 'uncertainty_limit','Covariance is a local linear white-residual diagnostic; autocorrelation/model discrepancy invalidate naive confidence interpretation.');
end
function c=localCov(J,r)
N=size(J,1);p=size(J,2);dof=max(N-p,1);s2=sum(r.^2)/dof;c=s2*pinv(J.'*J);
end
function d=localResidualDiagnostics(D,trace)
d=repmat(struct('run_id','','rmse_rad',NaN,'bias_rad',NaN,'acf1',NaN,'acf5',NaN,'command_corr_lags',[],'angle_bin_rmse_rad',[]),numel(D),1);
for k=1:numel(D)
 e=trace(k).residual(:); u=D(k).u(:); n=numel(e); maxlag=min(10,floor(n/5)); ac=zeros(1,maxlag);
 for lag=1:maxlag, ac(lag)=localCorr(e(1:end-lag),e(1+lag:end)); end
 lags=-3:3; cc=nan(size(lags)); for j=1:numel(lags), cc(j)=localLagCorr(e,u,lags(j));end
 edges=linspace(min(D(k).y),max(D(k).y)+eps,6); br=zeros(1,5); for b=1:5, ix=D(k).y>=edges(b)&D(k).y<edges(b+1); if any(ix), br(b)=sqrt(mean(e(ix).^2));else,br(b)=NaN;end,end
 d(k)=struct('run_id',D(k).run_id,'rmse_rad',sqrt(mean(e.^2)),'bias_rad',mean(e), ...
  'acf1',atOrNaN(ac,1),'acf5',atOrNaN(ac,5),'command_corr_lags',cc,'angle_bin_rmse_rad',br);
end
end
function c=localLagCorr(e,u,l)
if l>=0, a=e(1+l:end);b=u(1:end-l);else,a=e(1:end+l);b=u(1-l:end);end;c=localCorr(a,b);
end
function c=localCorr(a,b)
a=a(:)-mean(a);b=b(:)-mean(b);z=sqrt(sum(a.^2)*sum(b.^2));if z==0,c=NaN;else,c=sum(a.*b)/z;end
end
function v=atOrNaN(x,k),if numel(x)>=k,v=x(k);else,v=NaN;end,end
function [theta,v0,offset,rmse,exitflag]=localFitSingle(D,theta0,o)
p=3+double(o.fit_initial_velocity)+double(o.fit_initial_angle_offset);[lo,hi]=localBounds(D,o);
q0=zeros(p,1);q0(1:3)=(theta0(:)-o.theta_bounds(:,1))./localThetaScale(o);
localOpts=o;localOpts.fit_initial_velocity=o.fit_initial_velocity;localOpts.fit_initial_angle_offset=o.fit_initial_angle_offset;
fun=@(q)localResidual(q,D,localOpts,lo,hi);[q,cost,exitflag]=localOptimize(fun,q0,lo,hi,o);
theta=(o.theta_bounds(:,1)+q(1:3).*localThetaScale(o)).';v0=0;offset=0;
if o.fit_initial_velocity,v0=q(4)*o.velocity_scale;end
if o.fit_initial_angle_offset,offset=q(3+double(o.fit_initial_velocity)+1);end
rmse=sqrt(cost/numel(fun(q)));
end
function e=localConvergence(D,theta,o,q)
st=localInitialStates(q,D,o);e=0;
for k=1:numel(D)
 x0=[st(k).initial_velocity_fit_rad_s;D(k).y(1)+st(k).initial_angle_offset_rad];
 a=localPredict(theta,D(k).t,D(k).u,x0,o.substeps,o);b=localPredict(theta,D(k).t,D(k).u,x0,2*o.substeps,o);
 if any(~isfinite([a;b])),e=Inf;return,end
 e=max(e,max(abs(a-b)));
end
end
function y=localPredict(theta,t,u,x0,substeps,o)
% Computational screening, not a physical parameter bound or accuracy proof.
indicator=max(diff(t))*(abs(theta(2))+sqrt(abs(theta(1))))/substeps;
if any(~isfinite([theta(:);x0(:)]))||~isfinite(indicator)||indicator>o.max_dimensionless_rk4_step
    y=nan(size(t));return
end
y=pendulumlab.simulate_output(theta,t,u,x0,substeps);
end
function B=localBootstrap(D,theta,o,bestQ)
B=struct('method',o.bootstrap_method,'replicates',o.bootstrap_replicates,'theta',[], ...
 'successful_replicates',0,'failed_replicates',0,'exitflags',[],'failure_errors',{{}},'percentile_2_5',[],'percentile_97_5',[],'note','Resampling is diagnostic; not a physical repeatability claim.');
if o.bootstrap_replicates==0,return,end
stream=RandStream('mt19937ar','Seed',o.seed+1);out=nan(o.bootstrap_replicates,3);errors=cell(o.bootstrap_replicates,1);exitflags=nan(o.bootstrap_replicates,1);
if strcmp(o.bootstrap_method,'whole_run')&&numel(D)<2,B.note='Not computed: need at least two runs for whole-run resampling.';return,end
[lo,hi]=localBounds(D,o);[~,baseTrace]=localResidual(bestQ,D,o,lo,hi);
for b=1:o.bootstrap_replicates
 try
  if strcmp(o.bootstrap_method,'whole_run')
   ix=randi(stream,numel(D),numel(D),1);Db=D(ix); % duplicates are essential in a run-level bootstrap
  elseif strcmp(o.bootstrap_method,'moving_block')
   Db=D;
   for k=1:numel(Db)
    e=-baseTrace(k).residual;e=e-mean(e);n=numel(e);bl=min(o.bootstrap_block_samples,n);res=zeros(n,1);pos=1;
    while pos<=n,st=randi(stream,max(1,n-bl+1));take=min(bl,n-pos+1);res(pos:pos+take-1)=e(st:st+take-1);pos=pos+take;end
    Db(k).y=baseTrace(k).yhat+res;
   end
  else,error('pendulumlab:BootstrapMethod','bootstrap_method must be whole_run or moving_block.');end
  [thetaBoot,~,exitflags(b)]=localFitMany(Db,theta,o);
  if exitflags(b)>0&&all(isfinite(thetaBoot)),out(b,:)=thetaBoot;else,errors{b}=struct('identifier','pendulumlab:BootstrapNotConverged','message',sprintf('Optimizer exitflag %d.',exitflags(b)));end
 catch err
  errors{b}=struct('identifier',err.identifier,'message',err.message);
 end
end
ok=out(all(isfinite(out),2),:);B.theta=out;B.exitflags=exitflags;B.successful_replicates=size(ok,1);B.failed_replicates=o.bootstrap_replicates-size(ok,1);B.failure_errors=errors;
if ~isempty(ok),B.percentile_2_5=prctile(ok,2.5);B.percentile_97_5=prctile(ok,97.5);end
if size(ok,1)<max(2,ceil(.8*o.bootstrap_replicates)),B.note='Many resamples failed; intervals may be unstable.';end
end
function [th,rmse,exit]=localFitMany(D,theta0,o)
n=numel(D);p=3+double(o.fit_initial_velocity)*n+double(o.fit_initial_angle_offset)*n;[lo,hi]=localBounds(D,o);
q0=zeros(p,1);q0(1:3)=(theta0(:)-o.theta_bounds(:,1))./localThetaScale(o);fun=@(q)localResidual(q,D,o,lo,hi);
[q,cost,exit]=localOptimize(fun,q0,lo,hi,o);th=(o.theta_bounds(:,1)+q(1:3).*localThetaScale(o)).';rmse=sqrt(cost/numel(fun(q)));
end
function states=localInitialStates(q,D,o)
states=repmat(struct('run_id','','initial_velocity_fit_rad_s',0,'initial_angle_offset_rad',0),numel(D),1);
for k=1:numel(D),v=0;off=0;if o.fit_initial_velocity,v=q(3+k)*o.velocity_scale;end;if o.fit_initial_angle_offset,off=q(3+double(o.fit_initial_velocity)*numel(D)+k);end
 states(k)=struct('run_id',D(k).run_id,'initial_velocity_fit_rad_s',v,'initial_angle_offset_rad',off);end
end
function [lo,hi]=localBounds(D,o)
n=numel(D);p=3+double(o.fit_initial_velocity)*n+double(o.fit_initial_angle_offset)*n;lo=zeros(p,1);hi=ones(p,1);
hi(1:3)=(o.theta_bounds(:,2)-o.theta_bounds(:,1))./localThetaScale(o);
for k=1:n,if o.fit_initial_velocity,lo(3+k)=o.velocity_bounds(1)/o.velocity_scale;hi(3+k)=o.velocity_bounds(2)/o.velocity_scale;end
 if o.fit_initial_angle_offset,lo(3+double(o.fit_initial_velocity)*n+k)=o.initial_angle_bounds(1);hi(3+double(o.fit_initial_velocity)*n+k)=o.initial_angle_bounds(2);end,end
end
function scale=localThetaScale(o)
if isempty(o.theta_scale),scale=o.theta_bounds(:,2)-o.theta_bounds(:,1);else,scale=o.theta_scale(:);end
assert(numel(scale)==3&&all(isfinite(scale))&&all(scale>0),'pendulumlab:ThetaScale', ...
    'Supply three finite positive numerical theta_scale values when upper bounds are open.');
end
function s=localSolverName(tf),if tf,s='lsqnonlin';else,s='bounded transformed fminsearch';end,end
function h=localHash(s),h=pendulumlab.json_integrity_sha256(s);end
function txt=localExactJson(s)
% Preserve nonfinite option values explicitly instead of JSON null conversion.
f=fieldnames(s);copy=s;
for k=1:numel(f)
 v=s.(f{k});
 if isnumeric(v)&&any(~isfinite(v(:)))
  z=cell(size(v));
  for j=1:numel(v)
   if isinf(v(j)),if v(j)>0,z{j}='Inf';else,z{j}='-Inf';end
   elseif isnan(v(j)),z{j}='NaN';else,z{j}=v(j);end
  end
  copy.(f{k})=z;
 end
end
txt=jsonencode(copy);
end
function tf=localRawMatches(path,rid,hardware,kind,status,t,y,u)
tf=false;try,z=load(path,'result');if ~isfield(z,'result'),return,end;r=z.result;m=r.metadata;s=r.signals;
 rawId=localText(localGet(m,'run_id',localGet(m,'trial_id','')));rawHardware=localText(localGet(m,'hardware_id',''));rawStatus=localText(localGet(r.status,'code',''));
 tf=strcmp(localText(r.recording_kind),kind)&&strcmp(rawId,rid)&&strcmp(rawHardware,hardware)&&strcmp(rawStatus,status)&& ...
  strcmp(localText(localGet(m,'phase','')),'identification')&&startsWith(localText(localGet(m,'experiment_id','')),'identification_')&& ...
  isequal(double(s.t(:)),t)&&isequal(double(s.angle(:)),y)&&isequal(double(s.u_command(:)),u);
catch,tf=false;end
end
function v=localGet(s,f,d),if isstruct(s)&&isfield(s,f),v=s.(f);else,v=d;end,end
function s=localText(v),if isstring(v),s=char(v);elseif ischar(v),s=v;elseif isnumeric(v),s=num2str(v);else,s='';end,end


function out=localMerge(def,in),out=def;f=fieldnames(in);for ii=1:numel(f),assert(isfield(def,f{ii}),'pendulumlab:Option','Unknown option %s',f{ii});out.(f{ii})=in.(f{ii});end,end






















