function dz = observer_dx(z,y,uKnown,theta,T)
%OBSERVER_DX Known applied component excludes deliberate test injection.
alpha=theta(1);beta=theta(2);gamma=theta(3);
dz=[z(2)+y/(gamma*T^2)-alpha*sin(y)/gamma+uKnown; ...
    -z(1)/T^2-2*z(2)/T+(beta/gamma-2/(gamma*T))*y/T^2];
end
