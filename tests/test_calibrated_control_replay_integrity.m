function tests = test_calibrated_control_replay_integrity
tests = functiontests(localfunctions);
end

function setupOnce(testCase)
root = fileparts(fileparts(mfilename('fullpath')));
testCase.applyFixture(matlab.unittest.fixtures.PathFixture(root));
testCase.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(root,'experiment_framework')));
end

function testIndependentRK4FixturePassesCompletely(testCase)
[report,cleanup] = replayFixture(testCase,'baseline'); %#ok<ASGLU>
trial = report.trials(1);
verifyEqual(testCase,trial.recording_kind,'synthetic');
verifyEqual(testCase,trial.verification_class,'full');
verifyTrue(testCase,trial.observer_output_pass);
verifyTrue(testCase,trial.observer_state_pass);
verifyTrue(testCase,trial.controller_u_C_pass);
verifyTrue(testCase,trial.known_injection_filter_pass);
end

function testOneTruncatedRequiredSignalIsNotCertified(testCase)
[report,cleanup] = replayFixture(testCase,'one_field_truncated'); %#ok<ASGLU>
verifyNotEqual(testCase,report.trials(1).verification_class,'full');
verifyFalse(testCase,report.trials(1).signal_lengths_aligned);
end

function testAllSignalPrefixIsNotCertified(testCase)
[report,cleanup] = replayFixture(testCase,'all_fields_prefix'); %#ok<ASGLU>
trial = report.trials(1);
verifyNotEqual(testCase,trial.verification_class,'full');
verifyTrue(testCase,trial.signal_lengths_aligned);
verifyFalse(testCase,trial.recording_structure_complete);
end

function testNonfinitePreStateIsNotCertified(testCase)
[report,cleanup] = replayFixture(testCase,'nan_prestate'); %#ok<ASGLU>
verifyNotEqual(testCase,report.trials(1).verification_class,'full');
end

function testNonfiniteControllerSampleIsNotCertified(testCase)
[report,cleanup] = replayFixture(testCase,'nan_u_C'); %#ok<ASGLU>
verifyNotEqual(testCase,report.trials(1).verification_class,'full');
end

function testShiftedTimeGridIsNotCertified(testCase)
[report,cleanup] = replayFixture(testCase,'shifted_grid'); %#ok<ASGLU>
verifyNotEqual(testCase,report.trials(1).verification_class,'full');
verifyFalse(testCase,report.trials(1).nominal_grid_pass);
end

function testWrongObserverOutputIsClassifiedFailed(testCase)
[report,cleanup] = replayFixture(testCase,'wrong_w_hat'); %#ok<ASGLU>
trial = report.trials(1);
verifyEqual(testCase,trial.verification_class,'failed');
verifyFalse(testCase,trial.observer_output_pass);
end

function testFailedLastWriteIsNotCertified(testCase)
[report,cleanup] = replayFixture(testCase,'failed_last_write'); %#ok<ASGLU>
verifyNotEqual(testCase,report.trials(1).verification_class,'full');
end

function [report,cleanup] = replayFixture(testCase,mutation) %#ok<INUSD>
root = makeTempRoot();
cleanup = onCleanup(@()safeCleanupTempRoot(root));
result = syntheticResult();
switch mutation
    case 'one_field_truncated'
        result.signals.angle(end)=[];
    case 'all_fields_prefix'
        names = {'t','angle','reference','u_nominal','w_hat','u_C','read_valid', ...
            'write_succeeded','observer_z1_pre','observer_z2_pre', ...
            'w_injected_filtered','w_injected_effective'};
        for k=1:numel(names)
            value=result.signals.(names{k});
            value(end)=[];
            result.signals.(names{k})=value;
        end
    case 'nan_prestate'
        result.signals.observer_z1_pre(3)=NaN;
    case 'nan_u_C'
        result.signals.u_C(3)=NaN;
    case 'shifted_grid'
        result.signals.t(3)=result.signals.t(3)+result.metadata.config.Ts/10;
    case 'wrong_w_hat'
        result.signals.w_hat(3)=result.signals.w_hat(3)+1;
    case 'failed_last_write'
        result.signals.write_succeeded(end)=false;
    case 'baseline'
        % Keep the independently generated record intact.
    otherwise
        error('test_calibrated_control_replay_integrity:Mutation','Unknown fixture mutation.');
end
path = fullfile(root,[mutation '.mat']);
save(path,'result','-v7');
report = verify_pendulum_control_replay(path);
end

function result = syntheticResult()
% Construct logs with the package's RK4 observer, independently of the
% polynomial observer replay under test.
theta = [1.4;0.32;0.85]; h = 0.05; T = 0.42; a = 2.3; n = 8;
t = (0:n-1)'*h;
y = [0.12;0.125;0.13;0.128;0.121;0.116;0.118;0.124];
reference = [0.15;0.15;0.16;0.16;0.14;0.14;0.13;0.13];
u = [0.22;0.24;0.21;0.20;0.19;0.23;0.25;0.22];
qInput = [0;0.04;-0.02;0.03;0;0.01;-0.03;0.02];
rest = [0.10;0.101;0.099;0.102;0.098;0.10];
y0 = mean(rest(max(1,end-4):end));
z = [theta(2)*y0/theta(3);-y0/(theta(3)*T^2)];
filterState = zeros(2,1);
z1 = zeros(n,1); z2 = zeros(n,1); wHat = zeros(n,1);
uC = zeros(n,1); qFiltered = zeros(n,1);
for i=1:n
    z1(i)=z(1); z2(i)=z(2);
    wHat(i)=pendulumlab.observer_output(z,y(i),theta,T);
    uC(i)=(theta(1)*sin(y(i))-a*y(i)+a*reference(i))/theta(3);
    qFiltered(i)=filterState(1);
    z=pendulumlab.rk4(@(zz)pendulumlab.observer_dx(zz,y(i),u(i),theta,T),h,z);
    filterState=pendulumlab.rk4(@(xx)[xx(2); ...
        (qInput(i)-xx(1)-2*T*xx(2))/T^2],h,filterState);
end
cfg=struct('theta',theta,'Ts',h,'T',T,'a',a, ...
    'mode','mock','protocol',struct('duration_s',n*h), ...
    'initialization',struct('rest_angle_rad',rest));
signals=struct('t',t,'angle',y,'reference',reference,'u_nominal',u, ...
    'w_hat',wHat,'u_C',uC,'read_valid',true(n,1),'write_succeeded',true(n,1), ...
    'observer_z1_pre',z1,'observer_z2_pre',z2, ...
    'w_injected_filtered',qFiltered,'w_injected_effective',qInput);
metadata=struct('run_id','synthetic_replay_fixture','mode','mock', ...
    'hardware_id','synthetic_fixture','model_id','test_model','config',cfg, ...
    'initialization',struct('rest_angle_rad',rest),'planned_sample_count',n);
result=struct('schema_version','pendulumlab.run/1','recording_kind','synthetic','metadata',metadata,'signals',signals, ...
    'status',struct('code','completed','reason','deterministic synthetic fixture'));
end

function root = makeTempRoot()
tempBase = char(java.io.File(tempdir).getCanonicalPath());
requested = tempname(tempBase);
[ok,msg] = mkdir(requested); assert(ok,'Could not create test temp folder: %s',msg);
root = char(java.io.File(requested).getCanonicalPath());
assert(startsWith([root filesep],[tempBase filesep], 'IgnoreCase',ispc), ...
    'Test temp folder escaped the system temporary directory.');
end

function safeCleanupTempRoot(expectedRoot)
root = char(java.io.File(expectedRoot).getCanonicalPath());
assert(strcmpi(root,expectedRoot),'Test temp folder canonical path changed.');
tempBase = char(java.io.File(tempdir).getCanonicalPath());
assert(startsWith([root filesep],[tempBase filesep], 'IgnoreCase',ispc), ...
    'Refusing cleanup outside the system temporary directory.');
entries = dir(root); entries = entries(~ismember({entries.name},{'.','..'}));
for k=1:numel(entries)
    child = char(java.io.File(fullfile(root,entries(k).name)).getCanonicalPath());
    assert(strcmpi(fileparts(child),root),'Refusing to delete a path outside the test temp folder.');
    if isfile(child) && endsWith(child,'.mat','IgnoreCase',ispc)
        delete(child);
    else
        error('test_calibrated_control_replay_integrity:UnexpectedTempContent', ...
            'Refusing to clean unexpected test temp content: %s',child);
    end
end
rmdir(root);
end
