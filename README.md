# Pendulum Disturbance Observer

Experimental data and MATLAB code for **Nonlinear Disturbance Observers: An Input–Output Approach** by Martin Dodek and Miroslav Halás. The dataset records reference tracking and software disturbance injection on a propeller-actuated pendulum, together with the development and validation experiments used to characterize the nominal model.

[Download the paper’s dataset and code (v1.0.0)](https://github.com/dodekm/pendulum-disturbance-observer/releases/tag/v1.0.0) · [Campaign inventory](CAMPAIGN_INVENTORY.csv) · [Citation](CITATION.cff)

## Reproduce the results

1. Clone this repository or download and extract the source archive from the release page.
2. Open MATLAB R2025b with Optimization Toolbox and set the current folder to the repository root.
3. Run the following command.

   ```matlab
   result = reproduce_pendulum_revision;
   ```

The entry point runs offline. It checks file hashes, replays the 69 recorded control attempts, checks each run-level metric against the archived CSVs, regenerates the analysis figures, and recomputes excitation coverage and predictions for the frozen development and validation models. The parameter sets remain fixed throughout this reproduction.

For a quicker run that skips the control figure exports, use `reproduce_pendulum_revision(RegenerateCampaignFigures=false)`. Results go to a fresh directory under `analysis_results/`.

## What is in the dataset

| Group | Contents |
| --- | --- |
| Model development and validation | Excitation, calibration, pilot and validation recordings, with archived fit results, model parameters, and frozen assessment criteria. |
| Primary comparisons | Twenty complete runs. Each protocol has five separately initialized Off/On pairs at the primary gain and filter setting. |
| Gain and filter comparison | Forty-seven complete runs and one partial run stopped by the timing interlock in the interleaved design. |
| Later baseline | One separately acquired Off tracking run, reported separately from the interleaved design. |

The [campaign inventory](CAMPAIGN_INVENTORY.csv) indexes all 103 available recordings across 18 campaigns and distinguishes planned slots from recorded outcomes. The [raw data and configurations](experiment_data/campaign_v2/) include the MAT recordings, schedules, campaign manifests, and ledgers. The [archived run-level metrics](analysis_results/revision_20261106/campaigns_20261106_214004_145/) provide the numeric references for the reproduction.

## Reading a recording

Each run MAT file contains a `result` structure. The main fields are `t` and `t_device` for timing, `angle` and `reference` in radians, and `u_command` for the transmitted actuator command. The files also record the known model input, the disturbance estimate, and the requested, effective, and filtered software injection. The injection is expressed in the calibrated input coordinate. It provides a known comparison signal, while natural disturbances and physical thrust were unmeasured.

The validation records retain the two failed peak-error targets. The crossed design and the primary pairs characterize the observed settings during one session. The [reproduction notes](docs/reproduction.md) describe the archived checks and the acquisition source.

## Cite this release

Martin Dodek and Miroslav Halás. *Experimental data and MATLAB code for Nonlinear Disturbance Observers: An Input–Output Approach*. Version 1.0.0. [GitHub release](https://github.com/dodekm/pendulum-disturbance-observer/releases/tag/v1.0.0).
