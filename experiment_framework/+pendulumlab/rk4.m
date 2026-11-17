function next = rk4(fun,h,x)
%RK4 One held-input fourth-order Runge-Kutta update.
k1=fun(x);k2=fun(x+h*k1/2);k3=fun(x+h*k2/2);k4=fun(x+h*k3);
next=x+h*(k1+2*k2+2*k3+k4)/6;
end
