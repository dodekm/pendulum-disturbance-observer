function y = simulate_output(theta,t,u,x0,substeps)
%SIMULATE_OUTPUT Free-run held-command model; no differentiation of data.
arguments
    theta (1,3) double {mustBeFinite}
    t (:,1) double {mustBeFinite}
    u (:,1) double {mustBeFinite}
    x0 (2,1) double {mustBeFinite}
    substeps (1,1) double {mustBeInteger,mustBePositive} = 4
end
assert(numel(t)==numel(u)&&~isempty(t),'pendulumlab:Lengths','Input and time lengths differ.');
assert(all(diff(t)>0),'pendulumlab:Time','Model time must be strictly increasing.');
y=zeros(size(t));velocity=x0(1);angle=x0(2);y(1)=angle;
alpha=theta(1);beta=theta(2);gamma=theta(3);
for k=1:numel(t)-1
    h=(t(k+1)-t(k))/substeps;forcing=gamma*u(k);
    for j=1:substeps
        % Scalar RK4 keeps output-error optimization inexpensive without
        % changing the held-input differential model or sample alignment.
        v1=velocity;a1=-alpha*sin(angle)-beta*v1+forcing;
        v2=velocity+h*a1/2;a2=-alpha*sin(angle+h*v1/2)-beta*v2+forcing;
        v3=velocity+h*a2/2;a3=-alpha*sin(angle+h*v2/2)-beta*v3+forcing;
        v4=velocity+h*a3;a4=-alpha*sin(angle+h*v3)-beta*v4+forcing;
        angle=angle+h*(v1+2*v2+2*v3+v4)/6;
        velocity=velocity+h*(a1+2*a2+2*a3+a4)/6;
    end
    y(k+1)=angle;
end
end
