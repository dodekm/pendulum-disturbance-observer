classdef MockLink < handle
    %MOCKLINK Deterministic offline pendulum/transport adapter; never opens UART.
    properties (SetAccess=private)
        Open logical = true
        ReadCount double = 0
        WriteCount double = 0
        LastCommand double = 0
        State double
        Tick double = 0
        LastRawTimestamp double = NaN
        Commands double = zeros(0,1)
    end
    properties (Access=private)
        Config struct
        Schedule struct
        Stream
        FrozenTimestamp double = NaN
        ActuatorForce double = 0
    end
    methods
        function obj=MockLink(cfg,schedule)
            obj.Config=cfg; obj.Schedule=schedule;
            obj.State=double(cfg.mock.x0(:));
        if isfield(cfg.mock,'initial_tick'), obj.Tick=double(cfg.mock.initial_tick); end
            obj.Stream=RandStream('mt19937ar','Seed',double(cfg.mock.seed));
        end
        function [value,timestamp]=read(obj,~,count)
            obj.assertOpen();
            if count~=1, error('pendulumlab:MockReadCount','MockLink returns one angle at a time.'); end
            i=obj.ReadCount+1; obj.ReadCount=i;
            fault=lower(string(obj.Config.mock.fault)); at=obj.Config.mock.fault_at;
            if i==at && fault=="late_host_cycle"
                delay=0.2;
                if isfield(obj.Config.mock,'fault_delay_s'), delay=obj.Config.mock.fault_delay_s; end
                pause(max(0,double(delay)));
            end
            if i==at && any(fault==["timeout","dropped"])
                error('pendulumlab:MockReadTimeout','Deterministic mock %s at sample %d.',fault,i);
            elseif i==at && fault=="abort"
                error('pendulumlab:OperatorAbort','Deterministic mock operator abort at sample %d.',i);
            end
            angle=obj.State(2);
            if fault=="constant_angle", angle=obj.Config.mock.x0(2); end
            if i==at && fault=="nan", angle=NaN; end
            if i==at && fault=="angle"
                if isfinite(obj.Config.safety.max_abs_angle_rad)
                    angle=sign(angle+eps)*1.1*obj.Config.safety.max_abs_angle_rad;
                    if angle==0, angle=1.1*obj.Config.safety.max_abs_angle_rad; end
                else
                    angle=1.5;
                end
            end
            noise=obj.Config.mock.noise_std_rad*randn(obj.Stream,1,1);
            angle=angle+noise;
            q=obj.Config.mock.quantization_rad;
            if q>0 && isfinite(angle), angle=q*round(angle/q); end
            value=single(rad2deg(angle));
            raw=single(single(obj.Tick)*single(obj.Config.Ts));
            if fault=="duplicate" && i==at && isfinite(obj.LastRawTimestamp)
                raw=single(obj.LastRawTimestamp);
            elseif fault=="stale_time" && i>=at
                if ~isfinite(obj.FrozenTimestamp), obj.FrozenTimestamp=double(raw); end
                raw=single(obj.FrozenTimestamp);
            end
            timestamp=double(raw);
            obj.LastRawTimestamp=timestamp;
        end
        function write(obj,~,values)
            obj.assertOpen();
            if numel(values)~=1||~isreal(values)||~isfinite(double(values))
                error('pendulumlab:MockWriteValue','MockLink requires one finite real command.');
            end
            i=obj.WriteCount+1; fault=lower(string(obj.Config.mock.fault)); at=obj.Config.mock.fault_at;
            if i==at && fault=="late_write"
                delay=0.2;
                if isfield(obj.Config.mock,'fault_delay_s'), delay=obj.Config.mock.fault_delay_s; end
                pause(max(0,double(delay)));
            end
            if i==at && fault=="write_fault"
                obj.WriteCount=i;
                error('pendulumlab:MockWriteFault','Deterministic mock write failure at command %d.',i);
            end
            if fault=="slew" && i==at
                threshold=1;
                if isfield(obj.Config.mock,'slew_threshold_units')
                    threshold=obj.Config.mock.slew_threshold_units;
                end
                if abs(double(values)-obj.LastCommand)<=threshold
                    error('pendulumlab:MockSlewNotTriggered','Mock slew fault requires a command jump greater than its threshold.');
                end
                error('pendulumlab:MockSlew','Deterministic mock slew fault at command %d.',i);
            end
            command=double(values(1)); obj.WriteCount=i;
            obj.LastCommand=command; obj.Commands(end+1,1)=command;
            theta=double(obj.Config.mock.theta(:)); disturbance=double(obj.Config.mock.disturbance);
            if pendulumlab.actuator_coordinates(obj.Config,'enabled')
                modelCommand=pendulumlab.actuator_coordinates(obj.Config,'forward',command);
            else
                modelCommand=command;
            end
            if isfield(obj.Config.mock,'disturbance_start_read')&&obj.ReadCount<obj.Config.mock.disturbance_start_read
                disturbance=0;
            end
            substeps=max(1,round(double(obj.Config.integration_substeps)));
            h=double(obj.Config.Ts)/substeps;
            tau=0;if isfield(obj.Config.mock,'actuator_lag_s'),tau=obj.Config.mock.actuator_lag_s;end
            for j=1:substeps
                if tau>0
                    state=pendulumlab.rk4(@(x)[-theta(1)*sin(x(2))-theta(2)*x(1)+x(3);x(1); ...
                        (theta(3)*(modelCommand+disturbance)-x(3))/tau],h,[obj.State;obj.ActuatorForce]);
                    obj.State=state(1:2);obj.ActuatorForce=state(3);
                else
                    obj.State=pendulumlab.rk4(@(x)pendulumlab.plant_dx(x,modelCommand+disturbance,theta),h,obj.State);
                end
            end
            obj.Tick=obj.Tick+1;
        end
        function tf=isOpen(obj), tf=obj.Open; end
        function close(obj), obj.Open=false; end
        function delete(obj), obj.Open=false; end
    end
    methods (Access=private)
        function assertOpen(obj)
            if ~obj.Open, error('pendulumlab:MockClosed','Mock link is closed.'); end
        end
    end
end
