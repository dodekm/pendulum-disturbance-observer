function report=verify_pendulum_control_replay(resultFiles,OutputDir)
%VERIFY_PENDULUM_CONTROL_REPLAY Independently replay logged observer/controller math.
% Reads run/1 MAT files only. It does not open links or call observer package routines.
if nargin<2,OutputDir="";end
if ischar(resultFiles)|| (isstring(resultFiles)&&isscalar(resultFiles))
    resultFiles=string(resultFiles);
else
    resultFiles=string(resultFiles(:));
end
resultFiles=resultFiles(:);
assert(~isempty(resultFiles),'pendulumlab:ReplayFiles','Provide one or more result MAT paths.');
if strlength(string(OutputDir))>0
    root=fileparts(mfilename('fullpath'));addpath(fullfile(root,'experiment_framework'));
    [allowed,why]=pendulumlab.output_location_allowed(string(OutputDir),'offline');
    assert(allowed,'pendulumlab:ReplayOutput','%s',why);
    if isfolder(OutputDir)
        entries=dir(OutputDir);entries=entries(~ismember({entries.name},{'.','..'}));
        assert(isempty(entries),'pendulumlab:ReplayOutput','Refusing to overwrite a nonempty output folder.');
    else
        mkdir(OutputDir);
    end
end
tolerance=struct('observer_output_max_abs',1e-8,'observer_state_max_abs',1e-8, ...
    'controller_u_C_max_abs',1e-10,'known_injection_filter_max_abs',1e-8);
trials=repmat(emptyTrial(),numel(resultFiles),1);
for k=1:numel(resultFiles)
    path=string(java.io.File(char(resultFiles(k))).getCanonicalPath());
    assert(isfile(path),'pendulumlab:ReplayFile','Result file not found: %s',path);
    z=load(path,'result');
    assert(isfield(z,'result')&&isstruct(z.result)&& ...
        all(isfield(z.result,{'schema_version','metadata','signals','status'}))&& ...
        strcmp(z.result.schema_version,'pendulumlab.run/1'), ...
        'pendulumlab:ReplaySchema','MAT file does not contain a supported run/1 result.');
    r=z.result;s=r.signals;m=r.metadata;cfg=fieldOr(m,'config',struct());
    trials(k)=replayOne(r,s,m,cfg,char(path),tolerance);
end
report=struct('schema_version','pendulumlab.control_replay/1', ...
    'created_utc',char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd''T''HH:mm:ss''Z''')), ...
    'execution_mode','offline file replay; no UART or hardware link opened', ...
    'tolerances',tolerance,'replay_equations', ...
    'observer: A=[0 1;-1/T^2 -2/T], R=I+hA+(hA)^2/2+(hA)^3/6+(hA)^4/24, B=h*(I+hA/2+(hA)^2/6+(hA)^3/24); b=[y/(gamma*T^2)-alpha*sin(y)/gamma+u_nominal; (beta/gamma-2/(gamma*T))*y/T^2]. Q input uses bQ=[0;w_injected_effective/T^2].', ...
    'state_alignment','Compare logged w_hat, observer z pre-state, u_C, and w_injected_filtered before updating each sample; advance only after a successful write.', ...
    'trials',trials,'script_sha256',sha256File([mfilename('fullpath') '.m']));
report.summary=struct('full_pass',sum(strcmp({trials.verification_class},'full')), ...
    'failed',sum(strcmp({trials.verification_class},'failed')), ...
    'partial',sum(strcmp({trials.verification_class},'partial')), ...
    'incomplete',sum(strcmp({trials.verification_class},'incomplete')));
if strlength(string(OutputDir))>0
    save(fullfile(OutputDir,'control_replay.mat'),'report','-v7');
    fid=fopen(fullfile(OutputDir,'control_replay.json'),'w','n','UTF-8');
    assert(fid>=0,'pendulumlab:ReplayOutput','Cannot create JSON report.');
    c=onCleanup(@()fclose(fid));fprintf(fid,'%s',jsonencode(report,PrettyPrint=true));clear c
end
end
function x=emptyTrial()
x=struct('run_id','','source_file','','source_sha256','','recording_kind','','status_code','', ...
    'hardware_id','','model_id','','n_samples',0,'expected_sample_count',0, ...
    'signal_lengths_aligned',false,'nominal_grid_pass',false,'recording_structure_complete',false, ...
    'n_replayed_observer',0,'n_replayed_filter',0, ...
    'observer_complete',false,'filter_complete',false,'controller_complete',false,'run_status_complete',false,'verification_class','incomplete', ...
    'initialization_y0_rad',NaN,'observer_output_max_abs',NaN,'observer_state_max_abs',NaN, ...
    'controller_u_C_max_abs',NaN,'known_injection_filter_max_abs',NaN, ...
    'observer_output_pass',false,'observer_state_pass',false,'controller_u_C_pass',false, ...
    'known_injection_filter_pass',false,'stop_sample',NaN,'stop_reason','', ...
    'tolerances',struct(),'residual_by_sample',struct());
end
function out=replayOne(r,s,m,cfg,path,tol)
out=emptyTrial();out.run_id=char(string(fieldOr(m,'run_id','unknown')));out.source_file=path;
out.source_sha256=sha256File(path);out.recording_kind=char(string(fieldOr(r,'recording_kind','')));
out.status_code=char(string(fieldOr(fieldOr(r,'status',struct()),'code','unknown')));
out.hardware_id=char(string(fieldOr(m,'hardware_id','')));out.model_id=char(string(fieldOr(m,'model_id','')));
req={'theta','Ts','T','a'};
if ~all(isfield(cfg,req)),out.stop_reason='configuration missing theta/Ts/T/a/initialization';return,end
theta=double(cfg.theta(:));if numel(theta)~=3||any(~isfinite(theta))||theta(3)==0||any(~isfinite([cfg.Ts cfg.T cfg.a]))||cfg.Ts<=0||cfg.T<=0
    out.stop_reason='invalid finite model/control configuration';return
end
alpha=theta(1);beta=theta(2);gamma=theta(3);h=double(cfg.Ts);T=double(cfg.T);a=double(cfg.a);
init=fieldOr(m,'initialization',struct());
cfgInit=fieldOr(cfg,'initialization',struct());
rest=double(fieldOr(cfgInit,'rest_angle_rad',fieldOr(init,'rest_angle_rad',[])));
if isempty(rest)||any(~isfinite(rest))
    out.stop_reason='initialization rest-angle samples missing/nonfinite';return
end
y0=mean(rest(max(1,end-4):end));out.initialization_y0_rad=y0;
sigs={'t','angle','reference','u_nominal','w_hat','u_C','read_valid','write_succeeded', ...
    'observer_z1_pre','observer_z2_pre','w_injected_filtered','w_injected_effective'};
if ~all(isfield(s,sigs)),out.stop_reason='required observer/controller signals missing';return,end
lengths=cellfun(@(name)numel(s.(name)),sigs);
if any(lengths~=lengths(1)),out.stop_reason='required signal lengths are not aligned; no truncated-prefix certification';return,end
out.signal_lengths_aligned=true;
t=double(s.t(:));n=numel(t);out.n_samples=n;
protocol=fieldOr(cfg,'protocol',struct());duration=double(fieldOr(protocol,'duration_s',NaN));
expected=double(fieldOr(m,'planned_sample_count',NaN));
if ~isscalar(duration)||~isfinite(duration)||duration<=0|| ...
        ~isscalar(expected)||~isfinite(expected)||expected~=round(duration/h)
    out.stop_reason='planned sample count or protocol duration is missing/inconsistent';return
end
out.expected_sample_count=expected;
if n==0,out.stop_reason='no aligned samples';return,end
out.nominal_grid_pass=all(isfinite(t))&&n<=expected&& ...
    max(abs(t-(0:n-1)'*h))<=1e-10*max(1,duration);
if ~out.nominal_grid_pass,out.stop_reason='logged nominal sample grid is invalid';return,end
out.recording_structure_complete=n==expected;
y=double(s.angle(:));v=double(s.reference(:));u=double(s.u_nominal(:));w=double(s.w_hat(:));
read=double(s.read_valid(:));write=double(s.write_succeeded(:));
z1log=double(s.observer_z1_pre(:));z2log=double(s.observer_z2_pre(:));
uC=double(s.u_C(:));qInput=double(s.w_injected_effective(:));qLog=double(s.w_injected_filtered(:));
R=eye(2)+h*A(T)+(h*A(T))^2/2+(h*A(T))^3/6+(h*A(T))^4/24;
B=h*(eye(2)+h*A(T)/2+(h*A(T))^2/6+(h*A(T))^3/24);
z=[beta*y0/gamma;-y0/(gamma*T^2)];
filterState=zeros(2,1);
wResidual=nan(n,1);zResidual=nan(n,1);uResidual=nan(n,1);filterResidual=nan(n,1);
observerCount=0;filterCount=0;controllerCount=0;stop=NaN;reason='';
for i=1:n
    if ~isfinite(write(i))||~ismember(write(i),[0 1])
        stop=i;reason='write acknowledgement is missing or invalid';break
    end
    if ~isfinite(read(i))||read(i)~=1
        stop=i;reason='measurement is not marked valid';break
    end
    if ~all(isfinite([y(i),u(i),w(i),z1log(i),z2log(i),v(i),uC(i),qLog(i)]))
        stop=i;reason='nonfinite required observer/controller/filter sample';break
    end
    predW=z(2)+y(i)/(gamma*T^2);wResidual(i)=predW-w(i);
    zResidual(i)=max(abs(z-[z1log(i);z2log(i)]));observerCount=observerCount+1;
    % u_C is reconstructed independently from the measured angle/reference.
    uPred=(alpha*sin(y(i))-a*y(i)+a*v(i))/gamma;
    uResidual(i)=uPred-uC(i);controllerCount=controllerCount+1;
    filterResidual(i)=filterState(1)-qLog(i);filterCount=filterCount+1;
    if ~write(i)
        stop=i;reason='write not acknowledged; state is not advanced past this sample';break
    end
    if ~isfinite(qInput(i))
        stop=i;reason='effective injection missing; filter replay cannot advance';break
    end
    b=[y(i)/(gamma*T^2)-alpha*sin(y(i))/gamma+u(i);(beta/gamma-2/(gamma*T))*y(i)/T^2];
    z=R*z+B*b;
    bq=[0;qInput(i)/T^2];filterState=R*filterState+B*bq;
end
out.n_replayed_observer=observerCount;out.n_replayed_filter=filterCount;
out.observer_complete=observerCount==n&&all(isfinite(wResidual))&&all(isfinite(zResidual));
out.filter_complete=filterCount==n&&all(isfinite(filterResidual));
out.controller_complete=controllerCount==n&&all(isfinite(uResidual));
out.stop_sample=stop;out.stop_reason=reason;
out.observer_output_max_abs=maxFinite(abs(wResidual));out.observer_state_max_abs=maxFinite(zResidual);
out.controller_u_C_max_abs=maxFinite(abs(uResidual));out.known_injection_filter_max_abs=maxFinite(abs(filterResidual));
out.observer_output_pass=out.observer_complete&&out.observer_output_max_abs<=tol.observer_output_max_abs;
out.observer_state_pass=out.observer_complete&&out.observer_state_max_abs<=tol.observer_state_max_abs;
out.controller_u_C_pass=out.controller_complete&&out.controller_u_C_max_abs<=tol.controller_u_C_max_abs;
out.known_injection_filter_pass=out.filter_complete&&out.known_injection_filter_max_abs<=tol.known_injection_filter_max_abs;
statusLower=lower(string(out.status_code));
out.run_status_complete=any(statusLower==["complete","completed","success","succeeded"]);
if out.recording_structure_complete&&out.run_status_complete&&isnan(stop)&& ...
        out.observer_output_pass&&out.observer_state_pass&&out.controller_u_C_pass&&out.known_injection_filter_pass
    out.verification_class='full';
elseif out.observer_output_max_abs>tol.observer_output_max_abs|| ...
        out.observer_state_max_abs>tol.observer_state_max_abs|| ...
        out.controller_u_C_max_abs>tol.controller_u_C_max_abs|| ...
        out.known_injection_filter_max_abs>tol.known_injection_filter_max_abs
    out.verification_class='failed';
elseif observerCount>0||controllerCount>0||filterCount>0
    out.verification_class='partial';
end
out.tolerances=tol;
out.residual_by_sample=struct('w_hat',wResidual,'observer_state_max_abs',zResidual, ...
    'u_C',uResidual,'w_injected_filtered',filterResidual);
end
function M=A(T),M=[0 1;-1/T^2 -2/T];end
function v=maxFinite(x),x=x(isfinite(x));if isempty(x),v=NaN;else,v=max(x);end,end
function h=sha256File(path)
fid=fopen(path,'r');assert(fid>=0);c=onCleanup(@()fclose(fid));b=fread(fid,Inf,'*uint8');md=java.security.MessageDigest.getInstance('SHA-256');md.update(b);h=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
end
function v=fieldOr(s,n,d)
if isstruct(s)&&isfield(s,n),v=s.(n);else,v=d;end
end
