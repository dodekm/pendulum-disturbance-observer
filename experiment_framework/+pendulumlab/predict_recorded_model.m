function y=predict_recorded_model(model,t,rawCommand,x0,substeps)
%PREDICT_RECORDED_MODEL Predict recorded rig output with optional force lag.
% This full physical-rig predictor is separate from the nominal DOB model.
% The lag state starts at zero force by explicit model assumption.
if nargin<5 || isempty(substeps), substeps=4; end
if ~isstruct(model) || ~isscalar(model) || ~isfield(model,'theta') || ...
        ~isnumeric(model.theta) || ~isreal(model.theta) || numel(model.theta)~=3 || any(~isfinite(model.theta(:)))
    error('pendulumlab:recorded_prediction:Model','model.theta must contain three finite real parameters.');
end
theta=double(model.theta(:).');
if ~isnumeric(t) || ~isreal(t) || ~isvector(t) || isempty(t) || any(~isfinite(t(:))) || ...
        ~isnumeric(rawCommand) || ~isreal(rawCommand) || ~isvector(rawCommand) || numel(rawCommand)~=numel(t) || any(~isfinite(rawCommand(:)))
    error('pendulumlab:recorded_prediction:Data','t and rawCommand must be equal-length finite real vectors.');
end
t=double(t(:)); rawCommand=double(rawCommand(:));
if numel(t)>1 && any(diff(t)<=0)
    error('pendulumlab:recorded_prediction:Time','t must be strictly increasing.');
end
if ~isnumeric(x0) || ~isreal(x0) || numel(x0)~=2 || any(~isfinite(x0(:)))
    error('pendulumlab:recorded_prediction:InitialState','x0 must contain finite [velocity; angle].');
end
if ~isnumeric(substeps) || ~isreal(substeps) || ~isscalar(substeps) || ~isfinite(substeps) || substeps<1 || substeps~=fix(substeps)
    error('pendulumlab:recorded_prediction:Substeps','substeps must be a positive integer.');
end
hasDescriptor=isfield(model,'plant_characterization') && ~isempty(model.plant_characterization);
hasCalibration=false;
if isfield(model,'actuator_calibration') && ~isempty(model.actuator_calibration)
    hasCalibration=pendulumlab.actuator_coordinates(model,'enabled');
end
if hasCalibration
    command=pendulumlab.actuator_coordinates(model,'forward',rawCommand);
else
    command=rawCommand;
end
if ~hasDescriptor
    y=pendulumlab.simulate_output(theta,t,command,double(x0(:)),double(substeps));
    return
end
d=model.plant_characterization;
if ~isstruct(d) || ~isscalar(d) || ~isfield(d,'version') || ...
        ~(ischar(d.version)||(isstring(d.version)&&isscalar(d.version))) || ~strcmp(char(d.version),'static_map_lag_v1')
    error('pendulumlab:recorded_prediction:Version','Unsupported plant characterization version.');
end
if ~isfield(d,'lag_s') || ~isnumeric(d.lag_s) || ~isreal(d.lag_s) || ~isscalar(d.lag_s) || ~isfinite(d.lag_s) || d.lag_s<=0
    error('pendulumlab:recorded_prediction:Lag','lag_s must be a positive finite scalar.');
end
if ~hasCalibration
    % Descriptor gain is anchored to the model's nominal gamma.
    gammaRef=theta(3);
else
    gammaRef=model.actuator_calibration.gamma_ref;
end
tau=double(d.lag_s); alpha=theta(1); beta=theta(2);
target=gammaRef.*command;
y=zeros(size(t)); velocity=double(x0(1)); angle=double(x0(2)); force=0; y(1)=angle;
for k=1:numel(t)-1
    dt=(t(k+1)-t(k))/substeps; targetK=target(k); intervalForce=force;
    for j=1:substeps
        elapsed=(j-1)*dt;
        f0=targetK+(intervalForce-targetK)*exp(-elapsed/tau);
        fh=targetK+(intervalForce-targetK)*exp(-(elapsed+dt/2)/tau);
        f1=targetK+(intervalForce-targetK)*exp(-(elapsed+dt)/tau);
        [k1v,k1y]=rhs(velocity,angle,f0,alpha,beta);
        [k2v,k2y]=rhs(velocity+dt*k1v/2,angle+dt*k1y/2,fh,alpha,beta);
        [k3v,k3y]=rhs(velocity+dt*k2v/2,angle+dt*k2y/2,fh,alpha,beta);
        [k4v,k4y]=rhs(velocity+dt*k3v,angle+dt*k3y,f1,alpha,beta);
        velocity=velocity+dt*(k1v+2*k2v+2*k3v+k4v)/6;
        angle=angle+dt*(k1y+2*k2y+2*k3y+k4y)/6;
    end
    force=targetK+(intervalForce-targetK)*exp(-(t(k+1)-t(k))/tau);
    y(k+1)=angle;
end
if any(~isfinite(y)), error('pendulumlab:recorded_prediction:Overflow','Prediction produced nonfinite output.'); end
end
function [dv,dy]=rhs(v,y,force,alpha,beta)
dv=-alpha*sin(y)-beta*v+force; dy=v;
end
