classdef Connection < handle
    %CONNECTION Own a validated UARTLink serial client session.
    %   LINK = uartlink.Connection(PORT, BAUD) opens COMPORT using 8-N-1 and
    %   the default 1000 ms read and write timeouts.
    %
    %   LINK = uartlink.Connection(PORT, BAUD, ReadTimeoutMs=R,
    %   WriteTimeoutMs=W) selects nonnegative per-transport-call timeouts.
    %
    %   Connection is a handle class. Copies of a MATLAB variable refer to the
    %   same session. DELETE and CLOSE remove the native registry entry and close
    %   its COM handle. The public Token is an opaque registry key for Simulink;
    %   it is never a native address and is invalid after the connection closes.
    %
    %   Transactions are synchronous. Stream IDs range from 0 through 15 and a
    %   frame carries at most 63 single-precision values. See also READ, WRITE,
    %   ISOPEN, and CLOSE.

    properties (SetAccess = private)
        %TOKEN Opaque uint64 key for the native MEX session registry.
        %   The token is read-only, process-local, and intended for Simulink
        %   block parameters. It must not be persisted or treated as a pointer.
        Token (1, 1) uint64 = uint64(0)
    end

    methods
        function obj = Connection(portNumber, baudRate, options)
            %CONNECTION Open an exclusively owned Windows COM-port session.
            %   Construction either succeeds completely or throws a uartlink
            %   error; native partial construction is released automatically.
            arguments
                portNumber (1, 1) double {mustBeInteger, mustBePositive}
                baudRate (1, 1) double {mustBeInteger, mustBePositive}
                options.ReadTimeoutMs (1, 1) double {mustBeInteger, mustBeNonnegative} = 1000
                options.WriteTimeoutMs (1, 1) double {mustBeInteger, mustBeNonnegative} = 1000
            end

            obj.Token = uart_link_mex( ...
                'open', portNumber, baudRate, ...
                options.ReadTimeoutMs, options.WriteTimeoutMs);
        end

        function delete(obj)
            %DELETE Best-effort destructor for the native UARTLink session.
            %   Cleanup errors are suppressed so destruction cannot mask an
            %   already active MATLAB exception.
            if obj.Token ~= 0
                try
                    uart_link_mex('close', obj.Token);
                catch
                    % Destructors must not mask an active MATLAB exception.
                end
                obj.Token = uint64(0);
            end
        end

        function close(obj)
            %CLOSE Close the session and invalidate Token.
            %   An error leaves Token unchanged so the caller can inspect or
            %   retry cleanup. Calling CLOSE on a closed session is an error.
            obj.assertOpen();
            token = obj.Token;
            obj.Token = uint64(0);
            try
                uart_link_mex('close', token);
            catch error
                obj.Token = token;
                rethrow(error);
            end
        end

        function tf = isOpen(obj)
            %ISOPEN Test whether Token is present in the native registry.
            %   This does not communicate with the remote device and does not
            %   guarantee that a subsequent transfer will succeed.
            tf = obj.Token ~= 0 && uart_link_mex('isvalid', obj.Token);
        end

        function write(obj, streamId, values)
            %WRITE Send real numeric values to one logical stream.
            %   WRITE(OBJ, STREAMID, VALUES) converts VALUES to single and sends
            %   its linear column-major storage. Dimensions are not encoded.
            arguments
                obj (1, 1) uartlink.Connection
                streamId (1, 1) double {mustBeInteger, mustBeInRange(streamId, 0, 15)}
                values {mustBeNumeric, mustBeReal}
            end
            obj.assertOpen();
            uart_link_mex('write', obj.Token, streamId, single(values));
        end

        function [values, timestamp] = read(obj, streamId, elementCount)
            %READ Receive a fixed number of single-precision values.
            %   [VALUES, TIMESTAMP] = READ(OBJ, STREAMID, COUNT) returns a
            %   COUNT-by-1 single vector and a double timestamp converted from
            %   the protocol's IEEE-754 binary32 value.
            arguments
                obj (1, 1) uartlink.Connection
                streamId (1, 1) double {mustBeInteger, mustBeInRange(streamId, 0, 15)}
                elementCount (1, 1) double {mustBeInteger, mustBeInRange(elementCount, 0, 63)}
            end
            obj.assertOpen();
            [values, timestamp] = uart_link_mex('read', obj.Token, streamId, elementCount);
        end
    end

    methods (Access = private)
        function assertOpen(obj)
            %ASSERTOPEN Reject closed, stale, or unloaded registry sessions.
            if obj.Token == 0 || ~uart_link_mex('isvalid', obj.Token)
                error('uartlink:ClosedConnection', 'The UARTLink connection is closed.');
            end
        end
    end
end
