# Strict-profile design: agency-specific compliance modes for `datamirror`

**Status:** Design document, post-v1.0 follow-up.
**Date:** 2026-04-24
**Companion:** `COMPLIANCE.md` (8-agency primary-source audit), `PRIVACY.md` (gate-level documentation).

---

## TL;DR

`datamirror` v1.0's `standard` defaults are above-baseline for European register-data deployment (SCB, DST, SSB, ONS, Eurostat). They are **not** sufficient for the strictest international agencies (US Census FSRDC, IAB FDZ at small-stratum granularity, StatCan DAD). This document specifies a `DM_PROFILE` system that adds three agency-aligned profiles (`iab`, `fsrdc`, `strict`) without breaking the v1.0 defaults or the central coefficient-fidelity claim.

The architectural enabler is **layer independence**: Layer 4 (coefficient pinning) operates on the synthetic outcome `y` against the synthetic design `X` and does not read the marginals. Coarsening Layers 1–3 (schema / marginals / correlations) under stricter agency rules degrades distributional plausibility on uncheckpointed variables but does not affect coefficient fidelity. This makes the design additive and back-compatible.

---

## Problem statement

`COMPLIANCE.md` documents that `datamirror` v1.0 with current defaults (`DM_MIN_CELL_SIZE = 50`, `DM_QUANTILE_TRIM = 1`) meets or exceeds every reviewed agency's threshold on routine release categories. Two gaps remain:

1. **US Census FSRDC** prohibits true percentiles; it requires pseudo-percentile post-processing with 11-observation non-overlapping windows. v1.0 emits true percentiles, so v1.0 bundles cannot be released under FSRDC rules without external post-processing.
2. **IAB FDZ** requires N ≥ 2000 per stratum for 1% granularity, with a progressive table for coarser quantiles (N ≥ 20 for median, ≥ 40 for quartile, ≥ 80 for decile, ≥ 200 for p5/p95, ≥ 400 for p1/p99). v1.0 emits a fixed 101-point grid for any stratum above `DM_MIN_CELL_SIZE = 50`, so per-stratum granularity is below IAB's bar at small strata.

In addition, three agency-specific behaviors are not implemented in v1.0:

3. **FSRDC's 4-significant-figure coefficient rounding** rule.
4. **FSRDC's implicit-sample rule** (overlapping stratifications across repeated runs create implicit cells).
5. **IAB's 20-observation hard floor for regression output** (we currently warn nowhere if a checkpoint regression has fewer).

A single `DM_PROFILE` switch should toggle between v1.0 defaults and progressively stricter agency-aligned configurations, with `metadata.csv` recording which profile was used so downstream reviewers can verify the policy without re-running extract.

---

## Architectural argument: why this is back-compatible

`datamirror` is a 4-layer architecture:

- **Layer 1** (schema): variable name, type, format, classification.
- **Layer 2** (marginals): per-variable quantile grid (continuous) or frequency table (categorical).
- **Layer 3** (correlations): rank-correlation matrix, optionally per stratum.
- **Layer 4** (checkpoint coefficients): regression coefficient targets, applied via Newton step or DGP sampling at rebuild time.

The coefficient-fidelity contract (the central claim of the SJ paper) is enforced entirely by Layer 4. The Newton step for linear estimators computes `δy = X(β* − β̂)` against the *synthetic* design `X`; the GLM DGP samples `y` from the *target* coefficient vector. **Neither operation reads the Layer 1–3 marginal grids or correlations.**

Implication: any modification to Layers 1–3 — coarsening the quantile grid, replacing true percentiles with pseudo-percentiles, suppressing more strata — degrades the distributional realism of the synthetic data on uncheckpointed variables but does **not** affect the Δβ/SE pass-rate on checkpointed regressions.

The only Layer-4 change that affects coefficient fidelity is rounding the released coefficient targets themselves (FSRDC's 4-sig-fig rule). Rounding to 4 significant figures introduces relative error of order 10⁻⁴ in the target β*; the resulting Δβ/SE deviation is at most 10⁻⁴ × |β*|/SE, well below the Δβ/SE < 3 pass threshold for any non-pathological coefficient.

This layered-independence argument is what makes the strict profiles real rather than aspirational.

---

## `DM_PROFILE` definition

A new global, set at session-init time, that selects a coordinated bundle of gate values:

| Gate                                | `standard` (v1.0) | `iab`                      | `fsrdc`                      | `strict`                                  |
|-------------------------------------|-------------------|----------------------------|------------------------------|-------------------------------------------|
| Quantile grid                       | 101-point (fixed) | adaptive by N (table below)| 11-obs pseudo-percentiles    | adaptive by N + pseudo-percentile windowing|
| Per-stratum cell suppression        | 50                | 20                         | 50 (100 for IRS-commingled)  | 100                                       |
| `q0`/`q100` plateau (DM_QUANTILE_TRIM)| 1               | 1                          | 1                            | 1                                         |
| Coefficient rounding (sig figs)     | none              | none                       | 4                            | 4                                         |
| Implicit-sample logging             | off               | off                        | on                           | on                                        |
| Checkpoint-budget warn              | off               | on (Σk > N/10)             | on (Σk > N/10)               | on (Σk > N/20)                            |
| Regression N floor (warn)           | off               | 20                         | 20                           | 20                                        |

The `iab`-adaptive grid by N (per IAB FDZ progressive table):

| Stratum N range | Grid emitted                          |
|-----------------|---------------------------------------|
| N < 20          | skip stratum entirely                 |
| 20 ≤ N < 40     | median only                           |
| 40 ≤ N < 80     | median + quartiles                    |
| 80 ≤ N < 200    | deciles                               |
| 200 ≤ N < 400   | deciles + p5 / p95                    |
| 400 ≤ N < 2000  | deciles + p1 / p5 / p95 / p99         |
| N ≥ 2000        | full 101-point grid                   |

The `fsrdc` and `strict` modes apply the same adaptive table at the IAB thresholds, AND post-process each emitted percentile as the mean of an 11-observation centered non-overlapping window.

Profile precedence (same pattern as `DM_MIN_CELL_SIZE`): per-session option > persistent config > package default. The package default is `standard` (v1.0 behavior).

`metadata.csv` records the resolved profile as `dm_profile` and all the derived gate values, so a reviewer can verify the applied policy without re-running.

---

## Per-gate implementation notes

### G1. Adaptive quantile grid

**Where:** `_dm_utils.ado`, the continuous-marginals emit block (currently writes a fixed 101-point grid).

**Change:** at write time, look up the active grid policy from `DM_PROFILE`, count the per-stratum N (already known from the strata loop), select the grid from the IAB table above, emit only those quantiles. The `marginals_cont.csv` schema stays identical (`q0` through `q100` columns); unselected positions are written as `.` (Stata missing) and the rebuild interpolation skips them naturally.

**Estimated effort:** 30 lines, plus a dispatcher block at the top of the emit function. Add a unit test confirming the grid-count vs N table.

### G2. FSRDC pseudo-percentiles

**Where:** same file, after the adaptive-grid selection.

**Change:** for each emitted percentile `q_p`, compute the mean of the 11 observations whose ranks are closest to `p`-th percentile rank of the underlying data. Non-overlapping windows: at the 1st percentile, ranks `[N×0.01 − 5, ..., N×0.01 + 5]`; at the 2nd percentile, ranks `[N×0.02 − 5, ..., N×0.02 + 5]`; etc.

**Numerical concern:** for very small strata (N close to the IAB-adaptive threshold), the 11-obs window can overlap with adjacent percentiles. The IAB-adaptive table is set so that this doesn't happen at the binding thresholds (decile@N=80 means 8-obs windows at the IAB rule, which contradicts the 11-obs FSRDC rule — for `strict`, take the stricter of the two, i.e., use 11-obs windows but raise the per-quantile floor accordingly).

**Estimated effort:** 50 lines, one unit test on a known-distribution synthetic input.

### G3. Coefficient rounding

**Where:** `_dm_constraints.ado` checkpoint emit (the place where `b` and `se` get written to `checkpoints_coef.csv`).

**Change:** if `DM_PROFILE` is `fsrdc` or `strict`, round each coefficient and SE to 4 significant figures using a standard `string(x, "%9.0g")` round-trip or equivalent. Record `dm_coef_round = 4` in `metadata.csv`.

**Fidelity impact:** ≤ 10⁻⁴ relative error in target β*; well below Δβ/SE < 3.

**Estimated effort:** 10 lines, no unit test needed beyond visual inspection of `checkpoints_coef.csv`.

### G4. Implicit-sample logging

**Where:** new helper, called from `datamirror init`.

**Change:** write each extract's `(date, dataset_id, strata_var, N_total, N_per_stratum, k_coefs)` to `~/.registream/datamirror_runs.csv`. On `datamirror init` under `fsrdc` or `strict`, scan the log and warn if the new run's stratification overlaps with prior runs in a way that would create implicit cells. Specifically: if there exists a prior run with the same `dataset_id` and a stratification variable that intersects with the current one in ≥ 1 cell, emit a warning naming the prior run's bundle directory.

**Caveat:** the log only sees datamirror-mediated runs. Researchers extracting via other tools alongside datamirror create implicit cells the log can't catch. Document this as researcher responsibility.

**Estimated effort:** 80 lines (log writer + log reader + warning logic), one integration test.

### G5. Checkpoint-budget warning

**Where:** `datamirror extract` (after all checkpoints are tagged).

**Change:** compute `total_k = sum of k_coefs across all checkpoints` and `min_N = min stratum N (or N_total if unstratified)`. Warn if `total_k > min_N / threshold`, where threshold is 10 for `iab`/`fsrdc` and 20 for `strict`.

**Caveat:** the threshold is a heuristic, not handbook-cited. Defensible (Ricciato §3.2 functional-interpolation analogue motivates "k ≪ N") but inventive. Document this honestly in the `dm_profile` field of `metadata.csv`.

**Estimated effort:** 15 lines, no test needed.

### G6. Regression N floor warning

**Where:** at checkpoint time, `_dm_checkpoint` in `_dm_utils.ado`.

**Change:** read `e(N)` of the just-fitted regression; if `e(N) < 20` and `DM_PROFILE` ≠ `standard`, emit a warning naming the IAB FDZ source.

**Estimated effort:** 5 lines.

---

## Validation plan

The strict profiles are not validated until the four-AEA harness passes under each. The expected results, by profile, against the v1.0 headline of 349/353:

| Profile     | Expected pass rate | Reason                                                                                     |
|-------------|---------------------|--------------------------------------------------------------------------------------------|
| `standard`  | 349/353 (current)   | v1.0 baseline                                                                              |
| `iab`       | 348-350/353         | adaptive grid affects bivariate distributional structure on small strata; Layer 4 unaffected; possibly tips Duflo T3 (currently 3.097, 3.206) by ≤ 0.1 either way |
| `fsrdc`     | 347-349/353         | adds 4-sig-fig coefficient rounding (~10⁻⁴ effect); pseudo-percentile smoothing further degrades small-stratum bivariate structure but Layer 4 unaffected |
| `strict`    | 347-349/353         | composition of the above; the binding constraint is FSRDC's coefficient rounding |

A drop of more than 2-3 passes under any strict profile is a red flag that needs investigation (unexpected interaction between rounding and the joint stacked Newton step, perhaps).

**Validation procedure:**

1. Implement the profiles per the per-gate sections above.
2. Add a test harness driver that runs each profile against each of the four AEA packages: `replication/run_all_profiles.do`.
3. Emit a per-profile RESULTS table at `datamirror/replication/RESULTS_BY_PROFILE.md`, using the same per-paper / per-table structure as the existing `RESULTS.md`.
4. If any profile shows a drop > 2 passes from `standard`, write up the offending checkpoints and decide whether to:
    - Tune the profile (e.g., is the rounding precision too tight?),
    - Document the limitation honestly (some studies just don't survive the strictest regime),
    - Or fix the underlying interaction.

---

## Size-regime expected behavior

For prospective users, the expected synthetic-data quality under each profile, by N regime:

| N regime                  | `standard`         | `iab`              | `fsrdc`            | `strict`           |
|---------------------------|--------------------|--------------------|--------------------|--------------------|
| Register data (N millions)| Indistinguishable from real (univariate, bivariate, regressions) | Indistinguishable | Indistinguishable | Indistinguishable |
| Survey scale (N 2k–10k)   | Indistinguishable  | Slight tail smoothing | Visible tail smoothing | Visible tail smoothing |
| Small stratum (N 200–2k)  | Slight tail loss   | Visible coarsening | Visible coarsening | Visible coarsening |
| Very small stratum (N 20–200)| Tail loss + categorical suppression | Coarse grid (decile or below) | Coarse + smoothing | Coarse + smoothing |
| N < 20                    | Stratum skipped    | Skipped            | Skipped            | Skipped            |

In all regimes, the central coefficient-fidelity contract holds. The "indistinguishable" claim is for univariate marginals and bivariate joint structure on uncheckpointed variables; checkpointed regressions reproduce their target β* in every regime (modulo the 10⁻⁴ rounding effect under `fsrdc`/`strict`).

---

## Out of scope for this design

The following are deliberately deferred to subsequent work:

- **Differential privacy mechanism on top of the parametric layer.** A formal ε-DP guarantee composed with the bundle's existing safeguards would be a significant change to the bundle's information content; out of scope for v1.x of the strict profiles.
- **n/k-dominance rule for magnitude tables.** v1.0 emits no magnitude tables (frequencies and aggregates only); if a future profile needs to release magnitude tables under FSRDC's dominance rules, that's a separate design.
- **Custom per-agency profiles beyond `iab`/`fsrdc`/`strict`.** Single-country agencies with idiosyncratic rules (e.g., Statistics Canada DAD's specific cell-suppression negotiations) can be added incrementally; the design above keeps the dispatcher table extensible.
- **Membership-inference instrumentation.** Per `feedback_no_versioned_roadmap_in_paper.md` and Yao 2025 ("DCR is not a privacy argument"), this is not a near-term priority. The agency-baseline compliance argument carries the privacy claim; MI scoring would be belt-and-suspenders.

---

## Documentation surface

Each profile change must update:

1. `_dm_utils.ado` — global `DM_PROFILE` declaration + dispatcher logic at the top, profile reads at each gate site.
2. `datamirror.sthlp` — `profile()` option documentation, gate matrix table.
3. `PRIVACY.md` — extend the `Privacy Parameter` section to cover all four gates.
4. `COMPLIANCE.md` — update the per-output compliance matrix to reflect that `iab`, `fsrdc`, `strict` change the answer in specific cells.
5. `README.md` — usage examples for each profile.
6. `replication/RESULTS_BY_PROFILE.md` — new file for per-profile validation evidence.
7. `CHANGELOG.md` — Unreleased section entry.

---

## What the SJ paper says about this

Per `feedback_no_versioned_roadmap_in_paper.md`: do not name `DM_PROFILE`, `iab`, `fsrdc`, or specific gates in the SJ submission. The paper's §11 Conclusions can include one sentence in the future-work paragraph:

> Agency-specific compliance profiles (US Census FSRDC pseudo-percentile post-processing, IAB FDZ per-stratum adaptive granularity) are a natural extension of the bundle architecture and a direction we are pursuing.

This is the general-future-direction framing the no-versioned-roadmap rule allows. The full design (this document) lives in `datamirror/docs/`, not in the paper.

---

## References

Primary sources for the agency thresholds quoted in the per-profile gates:

- Brandt, M., Franconi, L., et al. (2016 rev.). *Guidelines for the Checking of Output Based on Microdata Research.* ESSnet SDC / DwB. https://cros.ec.europa.eu/system/files/2024-02/Output-checking-guidelines.pdf
- IAB FDZ. *Guidelines for the Design of Evaluation Programmes and Analysis Results* (English edition). https://doku.iab.de/fdz/access/Guidelines_en.pdf
- US Census Bureau. *FSRDC Disclosure Avoidance Methods Handbook*, v.4. https://www.census.gov/content/dam/Census/programs-surveys/sipp/methodology/FSRDC%20Disclosure%20Avoidance%20Methods%20Handbook%20v.4.pdf
- SDAP Working Group (2024). *Handbook on Statistical Disclosure Control for Outputs*, v2.0. UK Data Service. https://ukdataservice.ac.uk/app/uploads/sdc-handbook-v2.0.pdf
- Statistics Canada (2022, March). *DAD Vetting Handbook* v1.1. https://crdcn.ca/app/uploads/2022/07/DAD-Vetting-Handbook_EN.pdf
- Ricciato, F. (2026). "Privacy-Enhancing or Privacy-Elusion Technology?" *Journal of Official Statistics* 42(1), 168–195. DOI: 10.1177/0282423X251412328

Full agency audit at `COMPLIANCE.md`. URLs verified upstream 2026-04-24.

---

## Open questions

For Jeffrey before implementation:

1. **Profile naming.** Are `standard`, `iab`, `fsrdc`, `strict` the right labels? Alternatives: `default`, `eu`, `us`, `max`. Or align with agency proper names.
2. **`strict` as composition vs. one extra notch.** Currently designed as the union of all binding constraints. Alternative: `strict` = `fsrdc` + custom additions. Cleaner but less obviously "strictest possible."
3. **Failure mode on profile-validation drop.** If a profile drops > 2 passes, do we (a) tune to recover, (b) document the limitation, or (c) drop the profile? Default position: document; only tune if the failure is a bug, not a fundamental constraint.
4. **Implicit-sample log retention policy.** Should the log have a default retention (e.g., 12 months) or persist forever? GDPR/data-minimization angle.
5. **Build order.** Recommended sequence: G1 (adaptive grid) → G3 (coefficient rounding) → G6 (regression N warn) → G2 (pseudo-percentiles) → G5 (checkpoint-budget) → G4 (implicit-sample log). G1 and G3 unblock the most validation work; G2 is the heaviest implementation; G4 has the most external state.
