function dx = plant_dx(x,u,theta)
%PLANT_DX State ordering is [angular velocity; angle], radians and seconds.
dx=[-theta(1)*sin(x(2))-theta(2)*x(1)+theta(3)*u;x(1)];
end
