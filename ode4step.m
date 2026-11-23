function X = ode4step(f,h,X0,u,theta)

k1 = f(X0,u,theta);
k2 = f(X0+0.5*h*k1,u,theta);
k3 = f(X0+0.5*h*k2,u,theta);
k4 = f(X0+h*k3,u,theta);
X = X0 + (h/6)*(k1 + 2*k2 + 2*k3 + k4);

end

