classdef ReplayLink < handle
    %REPLAYLINK Offline read-only replay adapter; writes are logged in memory.
    properties (SetAccess=private)
        Open logical = true
        ReadCount double = 0
        WriteCount double = 0
        Commands double = zeros(0,1)
    end
    properties (Access=private)
        AngleDegrees double
        RawTimestamp double
    end
    methods
        function obj=ReplayLink(cfg)
            if isfield(cfg.replay,'angle_deg') && isfield(cfg.replay,'t_device_raw')
                obj.AngleDegrees=double(cfg.replay.angle_deg(:));
                obj.RawTimestamp=double(cfg.replay.t_device_raw(:));
            elseif isfield(cfg.replay,'file') && strlength(string(cfg.replay.file))>0
                data=load(cfg.replay.file);
                if isfield(data,'result')
                    signals=data.result.signals;
                elseif isfield(data,'signals')
                    signals=data.signals;
                else
                    error('pendulumlab:ReplaySchema','Replay MAT must contain result.signals or signals.');
                end
                if ~isfield(signals,'angle')||~isfield(signals,'t_device_raw')
                    error('pendulumlab:ReplaySchema','Replay requires angle in radians and raw device timestamps.');
                end
                obj.AngleDegrees=rad2deg(double(signals.angle(:)));
                obj.RawTimestamp=double(signals.t_device_raw(:));
            else
                error('pendulumlab:ReplayInput','Provide replay.angle_deg/t_device_raw or replay.file.');
            end
            if isempty(obj.AngleDegrees)||numel(obj.AngleDegrees)~=numel(obj.RawTimestamp)
                error('pendulumlab:ReplayLength','Replay angle and timestamp vectors must be nonempty and equal length.');
            end
        end
        function [value,timestamp]=read(obj,~,count)
            obj.assertOpen();
            if count~=1, error('pendulumlab:ReplayReadCount','Replay returns one angle at a time.'); end
            i=obj.ReadCount+1;
            if i>numel(obj.AngleDegrees), error('pendulumlab:ReplayExhausted','Replay source ended; no catch-up samples are fabricated.'); end
            obj.ReadCount=i; value=single(obj.AngleDegrees(i)); timestamp=obj.RawTimestamp(i);
        end
        function write(obj,~,values)
            obj.assertOpen(); obj.WriteCount=obj.WriteCount+1;
            obj.Commands(end+1,1)=double(values(1));
        end
        function tf=isOpen(obj), tf=obj.Open; end
        function close(obj), obj.Open=false; end
        function delete(obj), obj.Open=false; end
    end
    methods (Access=private)
        function assertOpen(obj)
            if ~obj.Open, error('pendulumlab:ReplayClosed','Replay link is closed.'); end
        end
    end
end
