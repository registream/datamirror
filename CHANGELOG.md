# DataMirror Changelog

## Unreleased

### Privacy

- **Top/bottom-code `q0` and `q100` in `marginals_cont.csv`.** Extreme quantiles stored the raw min and max of each continuous variable, which are textbook disclosure channels (Hundepool et al. 2012, §5.3; Willenborg & de Waal 2001, ch. 6) because outliers are often sample-unique. New `DM_QUANTILE_TRIM` global (default 1, meaning 1st/99th percentile) controls the trim, with the same three-tier resolution as `DM_MIN_CELL_SIZE` (session option `quantile_trim()`, `registream config, dm_quantile_trim()`, source default). Synthetic support contracts to `[p01, p99]` by default; rebuild is unchanged.
- **Gate stratified continuous marginals by `DM_MIN_CELL_SIZE`.** Previously `marginals_cont_stratified.csv` wrote per-stratum min/max for every stratum regardless of N, effectively disclosing single-observation statistics in small strata. The gate mirrors the one already applied to categorical stratified marginals and stratified correlations; skipped strata are counted as `n_strata_skipped_cont` in `metadata.csv`.
- **Runtime warning when `quantile_trim(0)` is set explicitly.** `datamirror init` now emits a one-line notice reminding the user that the raw max/min are stored unchanged in that mode, so the setting is only appropriate when the data have been top- and bottom-coded upstream. Non-fatal; no behavior change.
- PRIVACY.md rewritten for §Continuous Variables: removes the "quantiles are non-disclosive" blanket claim and documents the two new gates.
- **New COMPLIANCE.md.** Primary-source audit of how `datamirror` maps to the formal disclosure-control rules at SCB, DST, SSB, Eurostat (DwB / Brandt-Franconi), UK ONS (SDAP v2.0), US Census FSRDC, IAB FDZ, and Statistics Canada RDC. Includes a per-output compliance matrix, a gate-to-rule map, and an explicit list of residual items (FSRDC pseudo-percentile post-processing, IAB per-stratum granularity bar, implicit-sample rule under repeated runs, Ricciato 2026 post-handbook risks).
- **New REQUIREMENTS_CHECKLIST.md.** Flat, one-row-per-rule view of the COMPLIANCE.md audit across 36 substantive rules (8 agencies plus Ricciato post-handbook residuals). Each row carries a Met / Met-by-construction / Met-configurable / Gap / Not-applicable verdict, and every configurable row names the specific researcher or custodian action.

### Ecosystem

- **Three-tier writer for `dm_quantile_trim` via `registream config`.** The reader path was already wired across all three tiers (session option, persistent config, source default); the writer through `registream config, dm_quantile_trim(X)` was a documented follow-up. Now wired: validates 0 ≤ value ≤ 50, warns non-fatally when set to 0, persists to `~/.registream/config_stata.csv` through the shared `_rs_config set`. Requires the matching update in `registream`.
- **Fix: `registream config, dm_min_cell_size(X)` now actually sets the value.** The `syntax` spec used `DM_MIN_cell_size(integer -1)`, which Stata's `syntax` command rejects (underscores are not valid inside the required-uppercase-abbreviation portion of an option name). The option was silently rejected with "option not allowed" whenever invoked. Renamed to lowercase `dm_min_cell_size(integer -1)` so the option parses and the writer reaches `_rs_config set`. The read path has always worked; only the writer was affected.

### Documentation

- **Stata 16 minimum** declared explicitly in `README.md` Installation section and in `datamirror.sthlp` Requirements. Matches the `version 16.0` pragma in every shipped `.ado` file.
- README consolidated around the 12-subtest harness (seven single-estimator subtests, multi-checkpoint orchestration, integer-support preservation, unsupported-estimator rejection, `auto` prefix, UKHLS end-to-end). Prior text referenced 9/9 and 10/10 variants from interim states.
- `datamirror.sthlp` Syntax / Options / Privacy sections document the `quantile_trim(real)` option and the Brandt-Franconi Class-3 rationale for the `DM_QUANTILE_TRIM = 1` default. Fidelity section aligned on the 349 of 353 replication figure cited in the accompanying paper.

## v1.0.0 (2026-04-22)

First production release. Layer 4 converges on two principled families, with zero tuning hyperparameters in the linear paths.

### Layer 4 architecture

- **Linear models (OLS, FE, IV)**: closed-form Newton step on the synthetic outcome, derived via Frisch-Waugh-Lovell residualization. For OLS and reghdfe the update is one `matrix score` call on the target coefficient vector; for `ivregress` it is the weighted-FWL Newton step on the residualized design with condition-number diagnostics. One-shot, no learning rate, no iteration beyond absorbing O(1/N) floating-point drift. Full derivations in [docs/IV_CONSTRAINT_DECISION.md](docs/IV_CONSTRAINT_DECISION.md).
- **Joint IV for shared-outcome groups**: when multiple `ivregress` checkpoints share a `depvar`, a single stacked min-norm Newton step pins every coefficient simultaneously instead of cycling. Closes the multi-spec interference pattern (e.g., Autor 2019's `iv_mainshock` and `iv_gendershock` both regressing on `d_<y>`). Full math and literature in [docs/IV_JOINT_CONSTRAINT_DECISION.md](docs/IV_JOINT_CONSTRAINT_DECISION.md).
- **Generalized linear models (logit, probit, poisson, nbreg)**: direct DGP sampling. The linear predictor `xβ*` is built at the target coefficients, and `y` is drawn from the model's canonical data-generating process (Bernoulli for logit/probit, Poisson for poisson, Gamma-Poisson mixture for nbreg). Factor-level coefficients are preserved by construction. Rationale in [docs/NBREG_DGP_DECISION.md](docs/NBREG_DGP_DECISION.md) and [docs/LOGIT_PROBIT_DGP_DECISION.md](docs/LOGIT_PROBIT_DGP_DECISION.md).
- **nbreg α** is fixed at the original value because the negative-binomial score equation is non-orthogonal in (β, α) (Lawless 1987). The legacy `constraint 1 [lnalpha]_cons` trick is removed; α is encoded into the Gamma shape/scale parameters of the mixture.
- **Separation safeguard** on logit/probit: `p*` clipped to `(1e-4, 1 - 1e-4)` before the Bernoulli draw so downstream refits do not hit the Albert-Anderson (1984) MLE non-existence boundary.
- **Old iterative heuristics removed**: the per-coefficient diagonal Newton heuristic `y += λ · (β* − β̂) · (x − x̄)` that powered OLS/FE is replaced by the closed-form step above; the `max_iter` / `tolerance` / `learning_rate` locals that were passed to the DGP adjusters but silently ignored are deleted from both the dispatcher and the adjuster signatures. The adjuster file drops ~600 lines net from the v0.x state while gaining the IV Newton and joint IV paths.

### Fidelity metric

- Inferential **Δβ/SE** metric: synthetic β̂ is compared to target β* in units of the estimator's own standard error rather than on a fixed point-estimate scale. Documented in [docs/FIDELITY_METRIC.md](docs/FIDELITY_METRIC.md).
- Unit-test harness asserts `max(Δβ/SE) < 3` per subtest. The 3-SE threshold reflects Bonferroni-style simultaneous coverage over the 3-5 coefficients each subtest inspects. Corresponds to joint 99% CI across the subtest.

### Replication evidence

- Four AEA replication packages ported into `replication/` (Duflo-Hanna-Ryan 2012, Dupas-Robinson 2013, Banerjee et al. 2015, Autor-Dorn-Hanson 2019). The submission artifact for each paper is the checkpoint directory (no raw data), which reproduces the published regression coefficients on synthetic data.
- 349 of 353 coefficient comparisons across the four packages pass at `Δβ/SE < 3` (98.9%). Autor 2019 hits `Δβ/SE = 0.00` on every 2SLS coefficient after the joint IV step. Two marginal misses (`Δβ/SE = 3.097, 3.206`) in Duflo 2012 Table 3 Simple RDD (no FE) are a shared-y cross-spec interference pattern that the Tier-1 v1.1 joint-OLS work resolves; two Dupas 2013 Table 1 rare-binary balance-check coefficients return degenerate SE = 0 in the compare script (unverifiable, not a Layer 4 failure). Summary in `replication/RESULTS.md`.

### Privacy

- `min_cell_size` three-tier resolution: session option > registream config > package default (50). Persisted per-extract in `metadata.csv` as `dm_min_cell_size`.
- Suppression counters (`n_cat_categories`, `n_cat_suppressed`, stratified variants, `n_strata_skipped_corr`) written to `metadata.csv` at extract time. Reviewers can audit the threshold and suppression volume without re-running extract.
- Full discussion in [docs/PRIVACY.md](docs/PRIVACY.md).

### State to disk

- Checkpoint state fully disk-backed. `datamirror rebuild using "outbox"` and `datamirror check using "outbox"` work from a fresh Stata session with nothing but the outbox files.
- `$dm_cp<N>_alpha` session-global fallback retained for backward compatibility with pre-`3085b19` extracts that lack the `alpha` column in `checkpoints.csv`.

### Code quality

- File split: constraint layer (`stata/src/_dm_constraints.ado`) separated from utils (`stata/src/_dm_utils.ado`).
- Recursive mkdir promoted to registream core as `_rs_utils mkdir_p`. Datamirror uses the core helper.
- Shell commands replaced with native Stata equivalents.
- Debug output gated behind `$DM_DEBUG`. Tests run silent by default.
- Test harness prepends registream source to adopath (`adopath ++ ../registream/stata/src`) so core edits are picked up without `net install`.

### Supported models (9/9 unit tests passing)

- `regress` (OLS, closed-form Newton)
- `reghdfe` (fixed effects, closed-form Newton)
- `ivregress 2sls` (single-checkpoint and joint-shared-outcome Newton)
- `logit`, `probit`, `poisson`, `nbreg` (direct DGP sampling)
- Plus multi-checkpoint shared-predictor orchestration and discrete-numeric integer-support preservation.

### Deferred

- Joint-checkpoint OLS for shared-outcome groups ( ships in v1.1 once POCS / Dykstra-style projection for the range-inconsistent case is in place).
- Rare-binary copula improvement for balance tables with low-prevalence outcomes.
- Auto-checkpoint on estimation commands.
- Cross-model shared-outcome handling (IV and OLS on the same `y`); not empirically pressured in v1.0 replications.
- LIML and `ivregress gmm` with non-default weight matrix.
- Python and R ports.

### Architecture notes

- Peer package to `registream` core. Depends on core at runtime for `_rs_utils`, `_rs_config`, telemetry, and update-check scaffolding.
- Wrapper pattern (`_datamirror_wrapper_start` / `_datamirror_wrapper_end`) matches autolabel's convention.
