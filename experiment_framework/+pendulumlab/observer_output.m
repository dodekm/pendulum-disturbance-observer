function what = observer_output(z,y,theta,T)
%OBSERVER_OUTPUT Sample before advancing the observer state.
what=z(2)+y/(theta(3)*T^2);
end
