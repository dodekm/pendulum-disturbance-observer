function value = actuator_coordinates(cfg,action,value)
%ACTUATOR_COORDINATES Convert raw motor coordinates and normalized model input.
% The static map is a mathematical command-coordinate normalization; it is
% not a torque calibration. cfg.u_limits remains in raw motor coordinates.
if nargin < 2 || ~(ischar(action) || (isstring(action) && isscalar(action)))
    error('pendulumlab:actuator_coordinates:Action','Action must be a scalar string.');
end
action=char(action);
if strcmp(action,'enabled')
    value=calibration_enabled(cfg);
    return
end
if ~any(strcmp(action,{'forward','inverse','limits'}))
    error('pendulumlab:actuator_coordinates:Action','Unsupported action: %s',action);
end
if ~calibration_enabled(cfg)
    if strcmp(action,'limits')
        value=cfg.u_limits;
    end
    return
end
c=cfg.actuator_calibration;
required={'version','id','gamma_ref','coefficients','hardware_id','source_sha256'};
for k=1:numel(required)
    if ~isfield(c,required{k}), error('pendulumlab:actuator_coordinates:Config','Missing calibration field %s.',required{k}); end
end
if ~(ischar(c.version) || (isstring(c.version)&&isscalar(c.version))) || ~strcmp(char(c.version),'static_quadratic_v1')
    error('pendulumlab:actuator_coordinates:Version','Unsupported calibration version.');
end
if ~(ischar(c.id) || (isstring(c.id)&&isscalar(c.id))) || strlength(string(c.id))==0
    error('pendulumlab:actuator_coordinates:Config','Calibration id must be nonempty text.');
end
if ~isnumeric(c.gamma_ref) || ~isreal(c.gamma_ref) || ~isscalar(c.gamma_ref) || ~isfinite(c.gamma_ref) || c.gamma_ref<=0
    error('pendulumlab:actuator_coordinates:Config','gamma_ref must be a positive finite scalar.');
end
g=c.coefficients;
if ~isnumeric(g) || ~isreal(g) || numel(g)~=2 || any(~isfinite(g(:))) || any(g(:)<0) || ~any(g(:)>0)
    error('pendulumlab:actuator_coordinates:Config','coefficients must contain two finite nonnegative values, at least one positive.');
end
if ~isfield(cfg,'hardware_id') || ~isequal(string(c.hardware_id),string(cfg.hardware_id))
    error('pendulumlab:actuator_coordinates:Hardware','Calibration hardware_id does not match cfg.hardware_id.');
end
if ~(ischar(c.source_sha256) || (isstring(c.source_sha256)&&isscalar(c.source_sha256))) || ...
        isempty(regexp(char(c.source_sha256),'^[0-9a-fA-F]{64}$','once'))
    error('pendulumlab:actuator_coordinates:Config','source_sha256 must be 64 hexadecimal characters.');
end
if ~isfield(cfg,'theta') || numel(cfg.theta)<3 || ~isequal(cfg.theta(3),c.gamma_ref)
    error('pendulumlab:actuator_coordinates:Gamma','cfg.theta(3) must equal calibration gamma_ref.');
end
g1=double(g(1)); g2=double(g(2)); gamma=double(c.gamma_ref);
if strcmp(action,'limits')
    value=forward(double(cfg.u_limits),g1,g2,gamma);
    return
end
if nargin<3, error('pendulumlab:actuator_coordinates:Value','A value is required for this action.'); end
if ~isnumeric(value) || ~isreal(value) || any(~isfinite(value(:))) || any(value(:)<0)
    error('pendulumlab:actuator_coordinates:Value','Enabled coordinate maps require finite, real, nonnegative numeric inputs.');
end
if strcmp(action,'forward')
    value=forward(double(value),g1,g2,gamma);
else
    u=double(value);
    if g2==0
        value=gamma*u/g1;
    else
        value=zeros(size(u));
        nz=(u~=0);
        value(nz)=2*gamma.*u(nz) ./ (g1 + sqrt(g1.^2 + 4*(g2/50)*gamma.*u(nz)));
    end
end
if any(~isfinite(value(:)))
    error('pendulumlab:actuator_coordinates:Overflow','Coordinate conversion produced a nonfinite result.');
end
end
function u=forward(q,g1,g2,gamma)
u=(g1.*q+g2.*q.^2/50)./gamma;
if any(~isfinite(u(:)))
    error('pendulumlab:actuator_coordinates:Overflow','Coordinate conversion produced a nonfinite result.');
end
end
function enabled=calibration_enabled(cfg)
enabled=false;
if ~isfield(cfg,'actuator_calibration') || isempty(cfg.actuator_calibration), return; end
if ~isstruct(cfg.actuator_calibration) || ~isscalar(cfg.actuator_calibration)
    error('pendulumlab:actuator_coordinates:Config','actuator_calibration must be a scalar struct.');
end
if ~isfield(cfg.actuator_calibration,'enabled'), return; end
flag=cfg.actuator_calibration.enabled;
validFlag=islogical(flag) && isscalar(flag);
validFlag=validFlag || (isnumeric(flag) && isreal(flag) && isscalar(flag) && isfinite(flag) && any(flag==[0 1]));
if ~validFlag
    error('pendulumlab:actuator_coordinates:Config','Calibration enabled must be a logical scalar or numeric 0/1.');
end
enabled=logical(flag);
end
