# Causmos: Solution Overview

## What it does

Causmos estimates the impact of a marketing intervention, such as a campaign launch or budget change, on a selected KPI. It compares what actually happened after the event with what a model estimates would have happened without the event. That estimated difference is the **causal impact** (also called the incremental effect).

## How the workflow works

1. Choose a data source: Google Ads, Google Analytics 4, CSV, Google Sheets, or BigQuery.
2. Select the outcome KPI (the target event), any supporting covariates, and the date range around the intervention.
3. Causmos combines the data into a dated time series. The dates before the event are the **pre-period**; dates from the event onward are the **post-period**.
4. The model learns the pre-event relationship between the target KPI, its trend, and the covariates. It uses that relationship to forecast a post-period counterfactual: the expected KPI if the intervention had not occurred.
5. The report compares the forecast with observed results and presents charts, a summary, uncertainty intervals, and optional validation tests. Results can also be exported.

## How impact is measured

For each post-period date, the estimated effect is the observed KPI minus the counterfactual prediction. Causmos reports the accumulated absolute effect and the relative effect, alongside an uncertainty interval and statistical evidence. An effect is treated as statistically significant by the app's main check when its reported interval does not cross zero. A positive effect is an uplift; a negative effect is a downlift.

The selected credibility setting controls the model's uncertainty interval. The report's result is an estimate, not a directly observed measurement: the counterfactual cannot be seen, because only the post-intervention outcome actually occurred.

## Technical stack

- **Backend:** Python 3.11, Flask, and Gunicorn.
- **Analysis:** pandas and NumPy for preparing time-series data; TensorFlow Probability and TFP CausalImpact for Bayesian modeling.
- **Interface:** Server-rendered HTML templates, JavaScript, CSS, and Bulma.
- **Data integrations:** Google Ads API, Google Analytics 4 API, BigQuery, Google Sheets, and CSV uploads.
- **Google Cloud:** App Engine configuration and a Docker-based container build, with Google Cloud services for authentication, secrets, session storage, and report assets.

## Is this machine learning?

Yes, in the broad sense: Causmos fits a Bayesian time-series model using TensorFlow Probability's CausalImpact implementation. It uses historical patterns and covariates to predict a counterfactual and quantify uncertainty. It is not a conventional classifier, a general-purpose AI system, or an advertising-platform attribution report; the model is fitted for each analysis.

## Validation and interpretation

Causmos offers a pre-period check (to look for an apparent effect before the intervention), an unaffectedness check (to assess whether a proposed control covariate appears affected), and an optional correlation matrix. These checks help assess whether the analysis is plausible; they do not guarantee causality. The result is most credible when the pre-period is representative, covariates predict the target but are not themselves changed by the intervention, and no other event at the same time explains the KPI change. Missing or invalid data and unsuitable covariates can weaken or bias the estimate.