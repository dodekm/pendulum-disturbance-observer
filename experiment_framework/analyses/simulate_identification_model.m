function [y,velocity,info]=simulate_identification_model(p,t,u,x0,substeps,frictionVelocity)
%SIMULATE_IDENTIFICATION_MODEL Offline diagnostic model; never opens UART.
% p=[alpha,beta,gamma1,gamma2,tau,coulomb]; F_static=g1*u+g2*u^2/50.
% RK4 mechanics with exact held-input first-order force at RK stages.
arguments
    p (1,6) double {mustBeFinite,mustBeNonnegative}
    t (:,1) double {mustBeFinite}
    u (:,1) double {mustBeFinite}
    x0 (2,1) double {mustBeFinite}
    substeps (1,1) double {mustBePositive,mustBeInteger} = 8
    frictionVelocity (1,1) double {mustBePositive} = .03
end
assert(numel(t)==numel(u)&&all(diff(t)>0));
y=zeros(size(t));velocity=y;y(1)=x0(2);velocity(1)=x0(1);
alpha=p(1);beta=p(2);tau=p(5);c=p(6);epsV=frictionVelocity;
dt=median(diff(t));assert(max(abs(diff(t)-dt))<1e-9,'Use the verified uniform firmware grid.');
% This cap is a numerical admissibility guard, not a physical parameter bound.
steps=max([substeps,ceil(dt*(beta+c/epsV)),ceil(dt*sqrt(alpha)/.2)]);
info=struct('substeps_used',steps,'numerical_limit_hit',steps>128);
if steps>128,y(:)=NaN;velocity(:)=NaN;return,end
h=dt/steps;if tau>1e-12,ee=exp(-h/(2*tau));else,ee=0;end
targets=p(3)*u+p(4)*u.^2/50;force=targets(1);angle=x0(2);v=x0(1);
for k=1:numel(t)-1
    target=targets(k);
    for j=1:steps
        if tau<=1e-12,force=target;end
        fh=target+(force-target)*ee;fe=target+(force-target)*ee^2;
        v1=v;a1=-alpha*sin(angle)-beta*v1+force;
        if c>0,a1=a1-c*tanh(v1/epsV);end
        v2=v+h*a1/2;a2=-alpha*sin(angle+h*v1/2)-beta*v2+fh;
        if c>0,a2=a2-c*tanh(v2/epsV);end
        v3=v+h*a2/2;a3=-alpha*sin(angle+h*v2/2)-beta*v3+fh;
        if c>0,a3=a3-c*tanh(v3/epsV);end
        v4=v+h*a3;a4=-alpha*sin(angle+h*v3)-beta*v4+fe;
        if c>0,a4=a4-c*tanh(v4/epsV);end
        angle=angle+h*(v1+2*v2+2*v3+v4)/6;v=v+h*(a1+2*a2+2*a3+a4)/6;force=fe;
    end
    y(k+1)=angle;velocity(k+1)=v;
end
end
