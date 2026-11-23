function report=evaluate_pendulum_validation(manifestPath)
%EVALUATE_PENDULUM_VALIDATION Assess the frozen plan, including missing outcomes.
% No refitting of model parameters, model promotion, UART or manuscript edits.
root=fileparts(mfilename('fullpath'));addpath(fullfile(root,'experiment_framework'),fullfile(root,'experiment_framework','analyses'));
manifestPath=char(manifestPath);base=fileparts(manifestPath);
m=jsondecode(fileread(manifestPath));s=jsondecode(fileread(fullfile(base,'campaign_status.json')));
z=load(fullfile(base,'derived','validation_plan.mat'),'plan');plan=z.plan;
assert(strcmp(plan.manifest_sha256,pendulumlab.file_hash(manifestPath)),'Frozen validation manifest changed.');
assert(strcmp(s.campaign_id,m.campaign_id)&&numel(s.runs)==numel(m.runs),'Status ledger differs from the frozen campaign.');
jsonPlan=jsondecode(fileread(fullfile(base,'derived','validation_plan.json')));
assert(strcmp(pendulumlab.json_integrity_sha256(jsonPlan),pendulumlab.json_integrity_sha256(plan)), ...
    'Frozen MAT and JSON validation plans disagree.');
assert(strcmp(pendulumlab.file_hash(plan.diagnostic_source),plan.diagnostic_source_sha256),'Frozen diagnostic source changed.');
source=load(plan.diagnostic_source,'report');
assert(isequal(source.report.models{3}.parameters_full(:),plan.diagnostic_parameters(:)),'Diagnostic coefficients differ from the frozen source.');
folder=fullfile(base,'derived',['assessment_' char(datetime('now','Format','yyyyMMdd_HHmmss'))]);
assert(~isfolder(folder));mkdir(folder);runs=struct([]);rows=struct([]);details=cell(0,1);
for k=1:numel(m.runs)
    assert(strcmp(s.runs(k).run_id,m.runs(k).run_id));
    if ~strcmp(s.runs(k).code,'completed'),continue,end
    raw=fullfile(base,'runs',[m.runs(k).run_id '.mat']);r=pendulumlab.load_runs(string(raw));
    assert(strcmp(r.recording_kind,'physical')&&strcmp(r.metadata.phase,'validation'));
    assert(strcmp(r.status.code,'completed')&&strcmp(r.metadata.run_id,m.runs(k).run_id),'Raw result and ledger status/identity disagree.');
    fp=r.metadata.frozen_provenance;row=m.runs(k);
    assert(strcmp(r.metadata.config_sha256,row.config_sha256)&&strcmp(fp.config_sha256,row.config_sha256)&& ...
        strcmp(fp.manifest_sha256,plan.manifest_sha256)&&strcmp(fp.schedule_sha256,row.schedule_sha256)&& ...
        strcmp(fp.schedule_identity_sha256,row.schedule_identity_sha256)&& ...
        strcmp(r.metadata.schedule_identity_sha256,row.schedule_identity_sha256), ...
        'Raw recording does not bind the exact frozen configuration/schedule.');
    assert(strcmp(r.metadata.model_id,plan.candidate.model_id)&&strcmp(r.metadata.hardware_id,plan.candidate.hardware_id));
    if isempty(runs),runs=r;else,runs(end+1)=r;end %#ok<AGROW>
end
report=struct('status','prospective_assessment_no_control_approval','manifest_path',manifestPath, ...
    'manifest_sha256',plan.manifest_sha256,'outcomes',s.runs,'planned_count',numel(m.runs), ...
    'completed_count',numel(runs),'output_folder',folder,'script_sha256',pendulumlab.file_hash([mfilename('fullpath') '.m']), ...
    'scope','Complete frozen-plan accounting; valid adverse results retained. Historical theta is a reference benchmark, not a validated model for this hardware. No human approval is inferred.');
if ~isempty(runs)
    options=struct('initial_state_fit_window_s',plan.state_prefix_s,'substeps',plan.substeps,'criteria',plan.criteria);
    candidate=plan.candidate;candidate.theta=double(candidate.theta(:).');
    validation=pendulumlab.validate_model(candidate,runs,options);
    completeIds=string(arrayfun(@(r)r.metadata.run_id,runs,'UniformOutput',false));
    full=numel(runs)==numel(m.runs)&&all(strcmp({s.runs.code},'completed'))&& ...
        isequal(sort(completeIds(:)),sort(string({m.runs.run_id})'));
    validation.criteria_evaluation.complete_frozen_plan=full;
    if ~full
        validation.include.passed=false;validation.physical_promotion_eligible=false;
        validation.reason=[validation.reason ' Frozen plan is incomplete; this partial assessment cannot support promotion.'];
    end
    validation.include.report_hash='';validation.include.report_hash=pendulumlab.json_integrity_sha256(validation);
    report.validation=validation;
    for j=1:numel(runs)
        r=runs(j);t=double(r.signals.t(:));u=double(r.signals.u_command(:));y=double(r.signals.angle(:));
        pre=find(t<=plan.state_prefix_s);p=plan.diagnostic_parameters;
        calibrated=isfield(plan.candidate,'actuator_calibration');
        if calibrated
            comparison=rmfield(plan.candidate,'plant_characterization');
            obj=@(v)sum((pendulumlab.predict_recorded_model(comparison,t(pre),u(pre),[v;y(1)],plan.substeps)-y(pre)).^2);
            v0=fminsearch(obj,0,optimset('Display','off','TolX',1e-8));
            rich=pendulumlab.predict_recorded_model(comparison,t,u,[v0;y(1)],plan.substeps);
        else
            obj=@(v)sum((simulate_identification_model(p,t(pre),u(pre),[v;y(1)],plan.substeps,.03)-y(pre)).^2);
            v0=fminsearch(obj,0,optimset('Display','off','TolX',1e-8));
            rich=simulate_identification_model(p,t,u,[v0;y(1)],plan.substeps,.03);
        end
        nominal=validation.per_run(j).candidate_prediction;
        masks={t>plan.state_prefix_s,t>plan.state_prefix_s&u>0};names={'post_prefix','positive_command'};
        protocol=r.metadata.config.protocol;
        if isfield(protocol,'multisine_design')
            d=protocol.multisine_design;ix=t>=d.active_interval_s(1)&t<d.active_interval_s(2)&u>0;
            masks{end+1}=ix;names{end+1}='multisine_active';
            masks{end+1}=t>=d.full_amplitude_interval_s(1)&t<d.full_amplitude_interval_s(2)&u>0;
            names{end+1}='multisine_full_envelope';
        else
            w=protocol.static_waypoints;flat=find(diff(w(:,2))==0&w(1:end-1,2)>0);
            for a=flat'
                masks{end+1}=t>=w(a+1,1)-6&t<w(a+1,1)&u==w(a,2); %#ok<AGROW>
                names{end+1}=sprintf('plateau_%g_t%g',w(a,2),w(a+1,1)); %#ok<AGROW>
            end
        end
        for a=1:numel(masks)
            ix=masks{a};if ~any(ix),continue,end
            e=nominal(ix)-y(ix);ee=rich(ix)-y(ix);
            row=struct('run_id',r.metadata.run_id,'phase',names{a},'duration_s',sum(ix)*.05, ...
                'candidate_rmse_deg',rad2deg(sqrt(mean(e.^2))),'candidate_bias_deg',rad2deg(mean(e)), ...
                'candidate_peak_error_deg',rad2deg(max(abs(e))),'comparison_rmse_deg',rad2deg(sqrt(mean(ee.^2))), ...
                'comparison_bias_deg',rad2deg(mean(ee)));
            if isempty(rows),rows=row;else,rows(end+1)=row;end %#ok<AGROW>
        end
        details{end+1}=struct('run_id',r.metadata.run_id,'t',t,'y',y,'u',u,'nominal',nominal,'diagnostic',rich, ...
            'diagnostic_prefix_velocity',v0,'return_policy',r.metadata.excitation_return,'raw_sha256',r.provenance.source_sha256); %#ok<AGROW>
        assert(strcmp(pendulumlab.file_hash(r.provenance.source_file),r.provenance.source_sha256));
    end
    report.phase_metrics=rows;
    f=figure('Visible','off','Color','w','Position',[20 20 1100 310*numel(details)]);tiledlayout(f,numel(details),2,'TileSpacing','compact');
    for j=1:numel(details)
        d=details{j};nexttile;plot(d.t,rad2deg(d.y),'k','LineWidth',1);hold on;
        plot(d.t,rad2deg([d.nominal d.diagnostic]));grid on;xlabel('t [s]');ylabel('y [deg]');
        if calibrated,legend('Measured','Identified rig (map + lag)','Second-order nominal approximation','Location','best');
        else,legend('Measured','Frozen nominal','Frozen map + lag diagnostic','Location','best');end
        nexttile;stairs(d.t,d.u,'k');grid on;xlabel('t [s]');ylabel('u_{cmd} [command units]');
    end
    savefig(f,fullfile(folder,'validation_responses.fig'));print(f,fullfile(folder,'validation_responses.eps'),'-depsc','-painters');
    exportgraphics(f,fullfile(tempdir,'pendulum_validation_responses.png'),'Resolution',140);close(f);
    writetable(struct2table(rows),fullfile(folder,'phase_metrics.csv'));
    fprintf('VALIDATION %d/%d complete; all frozen accuracy criteria passed=%d\n',numel(runs),numel(m.runs),validation.include.passed);
    disp(validation.criteria_evaluation);
end
zip(fullfile(folder,'analysis_source_used.zip'),{'evaluate_pendulum_validation.m','experiment_framework/+pendulumlab/validate_model.m'},root);
save(fullfile(folder,'validation_assessment.mat'),'report','details','-v7');
fid=fopen(fullfile(folder,'validation_assessment.json'),'wt');assert(fid>=0);g=onCleanup(@()fclose(fid));fprintf(fid,'%s',jsonencode(report,PrettyPrint=true));clear g
fprintf('ASSESSMENT %s\n',folder);
end
