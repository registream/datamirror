# DataMirror Usage Guide

Complete guide with practical examples for generating checkpoint-constrained synthetic data.

## Table of Contents

1. [Basic Workflow](#basic-workflow)
2. [Example 1: Cross-Sectional Data](#example-1-cross-sectional-data)
3. [Example 2: Panel Data with Stratification](#example-2-panel-data-with-stratification)
4. [Example 3: Multiple Checkpoints](#example-3-multiple-checkpoints)
5. [Interpreting Validation Results](#interpreting-validation-results)
6. [Best Practices](#best-practices)
7. [Troubleshooting](#troubleshooting)

## Basic Workflow

The DataMirror workflow has three phases:

```
EXTRACT → REBUILD → VALIDATE
```

### Phase 1: Extract (on original data)

```stata
* Load your confidential data
use "my_data.dta", clear

* Initialize
datamirror init, checkpoint_dir("output") replace

* Run analyses and checkpoint them
reg outcome predictor1 predictor2
datamirror checkpoint, tag("main_model")

* Or, one-liner equivalent via the 'auto' prefix (tag auto-generated):
datamirror auto reg outcome predictor1 predictor2

* Extract all metadata
datamirror extract, replace
```

The `tag()` option is optional — when omitted the checkpoint is auto-tagged as `<cmd>_<counter>` (for example `regress_1`, `regress_2`, `logit_1`). If the same regression is already captured (same command, cmdline, and N), `datamirror checkpoint` no-ops with a message — safe to mix `datamirror auto` and explicit `datamirror checkpoint` without creating duplicates.

### Phase 2: Rebuild (generate synthetic)

```stata
* Clear workspace
clear

* Generate synthetic data
datamirror rebuild using "output", clear seed(12345)

* Save for distribution
save "synthetic_data.dta", replace
```

### Phase 3: Validate (check fidelity)

```stata
* Load synthetic data
use "synthetic_data.dta", clear

* Validate against original
datamirror check using "output"
```

## Example 1: Cross-Sectional Data

Simple cross-sectional analysis with employment outcomes.

### Data Preparation

```stata
* Load data
use "employee_survey.dta", clear

* Keep relevant variables
keep employed age female education income region

* Basic summary
summarize
```

### Extract Phase

```stata
* Initialize DataMirror
datamirror init, checkpoint_dir("output_employment") replace

* Model 1: Employment status
logit employed age female i.education
datamirror checkpoint, tag("employment_logit") notes("Main employment model")

* Model 2: Income regression (employed only)
reg income age female i.education if employed == 1
datamirror checkpoint, tag("income_model") notes("Income conditional on employment")

* Extract metadata
datamirror extract, replace
```

**Output files created:**
- `output_employment/metadata.csv`
- `output_employment/schema.csv`
- `output_employment/marginals_cont.csv`
- `output_employment/marginals_cat.csv`
- `output_employment/correlations.csv`
- `output_employment/checkpoints.csv`
- `output_employment/checkpoints_coef.csv`
- `output_employment/manifest.csv`

### Rebuild Phase

```stata
* Generate synthetic data
clear
datamirror rebuild using "output_employment", clear seed(99999)

* Quick check
count
summarize employed age female income

* Save synthetic data
save "synthetic_employment.dta", replace
```

### Validation

```stata
* Validate fidelity
datamirror check using "output_employment"
```

**Expected output:**
```
──────────────────────────────────────────────────────────
Checkpoint 1: employment_logit
──────────────────────────────────────────────────────────
  [Note: Logit not yet supported for Layer 4 adjustment]
  Validation shows correlation-based fidelity only

──────────────────────────────────────────────────────────
Checkpoint 2: income_model
──────────────────────────────────────────────────────────
  Variable        Original    Synthetic      Δ
  ───────────────────────────────────────────────────────
  age              0.0234      0.0241        0.0007
  2.education      0.1234      0.1456        0.0222
  3.education      0.2456      0.2389        0.0067
  female          -0.0876     -0.0892        0.0016
  _cons            2.3456      2.3521        0.0065
  ───────────────────────────────────────────────────────
  Max |Δβ| = 0.0222
  Max |Δβ/SE| = 0.49 (well inside the 3-SE tolerance)
```

See [FIDELITY_METRIC.md](FIDELITY_METRIC.md) for the Δβ/SE check datamirror uses in place of fixed point-estimate thresholds.

## Example 2: Panel Data with Stratification

Longitudinal data with multiple waves.

### Data Structure

```stata
* Panel structure: individuals observed over 3 waves
use "panel_data.dta", clear

* Structure
*   pid: Person ID
*   wave: 1, 2, 3
*   employed: Employment status
*   wellbeing: Wellbeing score
*   age, female, education: Demographics
```

### Extract with Stratification

```stata
* Initialize with wave stratification
datamirror init, checkpoint_dir("output_panel") strata(wave) replace

* Within-wave model
reg wellbeing employed age female
datamirror checkpoint, tag("wellbeing_within") ///
    notes("Wellbeing model estimated within waves")

* Panel-specific analysis (if using xtreg, still checkpoint with reg)
xtreg wellbeing employed age, fe i(pid)
* Note: Layer 4 doesn't support xtreg yet, so run equivalent:
reg wellbeing employed age i.pid
datamirror checkpoint, tag("wellbeing_fe") ///
    notes("Fixed effects approximation")

* Extract
datamirror extract, replace
```

**Key files for stratified data:**
- `output_panel/marginals_cont_stratified.csv` - Marginals by wave
- `output_panel/marginals_cat_stratified.csv` - Categories by wave
- `output_panel/correlations_stratified.csv` - Correlations by wave

### Rebuild Stratified Data

```stata
* Rebuild (automatically handles stratification)
clear
datamirror rebuild using "output_panel", clear seed(54321)

* Verify stratification preserved
tab wave
* Should match original wave distribution

* Check within-wave properties
bysort wave: summarize wellbeing employed age
```

### Validate Stratified Results

```stata
datamirror check using "output_panel"
```

The validation will report fidelity:
- Overall marginals
- Within-stratum marginals
- Checkpoint coefficients

## Example 3: Multiple Checkpoints

Research paper with several key results.

### Setup

```stata
use "research_data.dta", clear

* Paper has 3 main results + 2 robustness checks
datamirror init, checkpoint_dir("output_paper") replace
```

### Main Results

```stata
* Table 1: Baseline model
reg outcome treatment age female i.education
datamirror checkpoint, tag("table1_baseline") ///
    notes("Table 1: Main treatment effect")

* Table 2: With controls
reg outcome treatment age female i.education income i.region
datamirror checkpoint, tag("table2_controls") ///
    notes("Table 2: Full controls")

* Table 3: Heterogeneous effects
reg outcome treatment##female age i.education
datamirror checkpoint, tag("table3_heterog") ///
    notes("Table 3: Treatment by gender interaction")
```

### Robustness Checks

```stata
* Robustness 1: Different age specification
reg outcome treatment c.age##c.age female i.education
datamirror checkpoint, tag("robust1_age_sq") ///
    notes("Appendix A: Quadratic age")

* Robustness 2: Subsample
reg outcome treatment age female i.education if income > 30000
datamirror checkpoint, tag("robust2_highinc") ///
    notes("Appendix B: High income only")

* Extract all
datamirror extract, replace
```

**Result:** 5 checkpoint files created, each with target coefficients.

### Rebuild and Share

```stata
* Generate synthetic data
clear
datamirror rebuild using "output_paper", clear seed(11111)

* Verify all checkpoints
datamirror check using "output_paper"

* Save for journal submission
compress
save "replication_data.dta", replace

* Create README for replication package
file open readme using "REPLICATION_README.txt", write replace
file write readme "Synthetic Replication Data" _n
file write readme "Generated with DataMirror" _n
file write readme "Preserves key results from original analysis" _n
file write readme "See checkpoints_validation.log for fidelity metrics" _n
file close readme
```

## Interpreting Validation Results

### Marginal Validation

```
  Continuous Variables:
    ✓ age: KS = 0.023 (p = 0.845)
    ✓ income: KS = 0.034 (p = 0.456)
    ✗ wellbeing: KS = 0.089 (p = 0.012)
```

**Interpretation:**
- KS statistic measures max difference in CDFs
- p > 0.05: Distributions match well ✓
- p < 0.05: Some deviation ✗
- KS < 0.10 is generally acceptable even if p < 0.05

### Correlation Validation

```
  Correlation Matrix:
    Overall: r = 0.96 (excellent)
    age-income: 0.23 → 0.21 (Δ = 0.02) ✓
    age-wellbeing: 0.05 → 0.12 (Δ = 0.07) ⚠️
```

**Interpretation:**
- r > 0.95: Excellent overall preservation
- Δ < 0.05: Individual correlations match well
- Δ > 0.10: Correlation may have shifted

### Checkpoint Validation

```
──────────────────────────────────────────────────────────
Checkpoint 1: main_model
──────────────────────────────────────────────────────────
  Max |Δβ| = 0.0089
  Max |Δβ/SE| = 0.42
```

**Thresholds (Δβ/SE metric).** Datamirror judges synthetic coefficients in units of the estimator's own standard error, not by a fixed point-estimate cutoff. The test suite asserts `max(Δβ/SE) < 3` per subtest; see [FIDELITY_METRIC.md](FIDELITY_METRIC.md) for the multi-comparison rationale. Interpretation for a user inspecting a rebuild:

- Δβ/SE < 1: indistinguishable from target at any typical inference level.
- Δβ/SE < 2: within the standard 95% CI.
- Δβ/SE < 3: within the standard 99.7% CI (the test-suite bar).
- Δβ/SE > 3: investigate. Possible causes: N too small, data pathology, algorithm bug.

## Best Practices

### 1. Choose Checkpoints Carefully

✅ **Do:**
- Checkpoint main results from your paper/report
- Checkpoint models that inform key decisions
- Checkpoint models with largest sample sizes (better constraint)

❌ **Don't:**
- Checkpoint every exploratory model
- Checkpoint highly collinear models
- Checkpoint models with < 100 observations

### 2. Stratification Strategy

**Use stratification when:**
- Panel/longitudinal data (stratify by time)
- Multi-site studies (stratify by site)
- Properties differ systematically across groups

**Example:**
```stata
* Panel data: stratify by wave
datamirror init, checkpoint_dir("output") strata(wave) replace

* Multi-country: stratify by country
datamirror init, checkpoint_dir("output") strata(country) replace
```

**Warning:** More strata = smaller within-stratum samples = harder to match checkpoints

### 3. Seed Reproducibility

Always document your seed for reproducibility:

```stata
* In your replication script:
datamirror rebuild using "output", clear seed(12345)

* In your README:
* "Synthetic data generated with seed 12345"
* "Different seeds produce different datasets"
* "but all should land within max(Δβ/SE) < 3 at the checkpoints"
```

### 4. Variable Selection

**DataMirror automatically captures ALL variables in your dataset.** The four-layer system replicates:
- **Layers 1-3**: ALL variables (schema, marginals, correlations)
- **Layer 4**: Specific checkpoint relationships (fine-tuning)

You do NOT need to manually select variables. Just ensure your dataset contains what you need before extraction:

```stata
* OPTIONAL: Filter dataset before extraction if needed
* (but DataMirror will capture all remaining variables)
keep pid wave employed wellbeing age female education income region

* Consider excluding before extraction:
* - Unique identifiers (except for stratification)
* - Free text fields
* - Variables with all missing values
* - Constant variables (automatically skipped in correlations)

* DataMirror will automatically:
* - Capture all variables in schema/marginals
* - Skip constant variables from correlations
* - Impute missing correlations with 0 (independence assumption)
```

### 5. Missing Data

DataMirror preserves missingness patterns:

```stata
* Original:
* employed has 5% missing

* Synthetic:
* employed has ~5% missing (sampled from original pattern)
```

**If using `if` conditions in checkpoints:**
```stata
* Explicitly handle missing
reg employed age female if !missing(employed, age, female)
datamirror checkpoint, tag("complete_case")
```

## Troubleshooting

### FAQ: interpreting fidelity numbers and picking the right regime

**"My `Δβ/SE` is 2.8 on one coefficient. Should I worry?"**

Short answer: not for the v1.0 fidelity claim, but understand what the number means before you rely on inference. The 3-SE bar is a simultaneous-coverage threshold over several coefficients (Bonferroni-style). A single coefficient at 2.8 SE means the published point estimate and the synthetic point estimate disagree by 2.8 of the synthetic fit's SE. For reporting a point estimate on synthetic data, this is generally fine. For hypothesis testing (e.g., you rely on a p-value flipping above or below 0.05), the synthetic test may not match the original. If you need exact inference parity, target `Δβ/SE < 0.3` for the coefficients you care about, not just `< 3`. The tighter threshold holds for most checkpoints in practice; see `replication/RESULTS.md` for per-paper distributions.

**"My rare-binary coefficient (prevalence < 0.10) has `Δβ/SE = 1.5`."**

Expected at the current release. The rare-binary warning at extract time flagged this. The root cause is Layer 2 (Gaussian copula), not Layer 4: the copula does not preserve correlations between a rare binary and other variables well when the binary has fewer than ~10% positive values. The coefficient comes back at the correct sign and order of magnitude, but the exact SE-scaled fit is loose. A conditional-sampling fix for rare binaries is a direction we are pursuing; in the meantime the honest response is to document the limitation in any write-up that relies on the rare-binary regression. For balance-table regressions where rare binaries appear as outcomes, treat Δβ/SE ~ 1-2 as acceptable imprecision rather than a fidelity failure.

**"My regression isn't in the supported list. What now?"**

`datamirror checkpoint` exits with `rc=199` and points you at `docs/SUPPORTED_MODELS.md`. You can usually re-run with a supported estimator if the substantive conclusion doesn't hinge on the exact specification; otherwise open an issue with the use case (directions under consideration include `xtreg fe/re` and `ivreghdfe`). The supported set covers OLS, fixed effects, 2SLS in single and shared-outcome form, and the four GLM families (logit, probit, poisson, nbreg). Not yet supported: `ologit`, `oprobit`, `mlogit`, `stcox`, `tobit`, `ivpoisson`, `ivregress liml`, and `ivregress gmm` with a non-default weight matrix.

**"My checkpoint has N < 100. Is that a problem?"**

Below ~100 observations the usual warnings about small-sample inference apply to the synthetic fit just as they do to the original. Layer 4's Newton step converges fine, but the standard errors the synthetic dataset reports are themselves noisy at small N. If you checkpoint a subsample regression (e.g., `regress y x if category == 3` where only 40 observations satisfy the condition), expect the synthetic fit's SE to differ from the original by `O(1/√N) ≈ 15%`. The point estimate will still be pinned; the inference will be approximate. Document in any submission that uses small-sample subgroup checkpoints.

**"Should I commit the checkpoint directory to git?"**

Yes, deliberately. The directory is a small set of CSVs (marginals, correlations, coefficients) with no individual-level data. It is the disclosure-safe artifact your collaborators or replication reviewers need. Commit it alongside your do-files. See the `replication/` subdirectory in this repo for the pattern.

**"How do I cite datamirror and the method my regression uses?"**

Run `datamirror cite` inside Stata for the tool citation. For the method, cite the decision doc corresponding to your regression family: `docs/IV_CONSTRAINT_DECISION.md`, `docs/NBREG_DGP_DECISION.md`, `docs/LOGIT_PROBIT_DGP_DECISION.md`. Each decision doc lists the underlying econometric references (FWL 1933, Hansen 1982, Lawless 1987, Albert-Anderson 1984, etc.).

---

### Issue 1: Checkpoint Doesn't Converge

**Symptom:**
```
Did not converge after 100 iterations (Max Δβ = 0.1523)
```

**Causes:**
- Small sample size (< 200 obs)
- High multicollinearity
- Factor variables with many levels

**Solutions:**
```stata
* 1. Check sample size
count if !missing(depvar, var1, var2)  // Should be > 200

* 2. Check multicollinearity
reg outcome var1 var2 var3
vif  // VIF > 10 indicates problems

* 3. Simplify model
* Instead of: i.detailed_occupation (50 levels)
* Use: i.occupation_group (5 levels)
```

### Issue 2: Factor Coefficients Don't Match

**Symptom:**
```
2.education: Δβ/SE = 0.41
3.education: Δβ/SE = 0.53
```

In v1.0, factor-level coefficients are preserved by construction for all nonlinear models (logit, probit, poisson, nbreg) via direct DGP sampling; factor Δβ/SE lands in the same range as continuous predictors. For continuous-outcome models (OLS, reghdfe, IV) factor levels are handled by level-specific outcome shifts (`y += λ · Δβ_k` on observations with `factor == k`) and also converge to well below the 3-SE test threshold.

If you observe unusually large Δβ/SE on a factor level, the likely cause is sparse cells (few observations at that level) rather than a method limitation. Consider collapsing rare levels or increasing N.

### Issue 3: "Variable Not Found" Error

**Symptom:**
```
variable employed not found
r(111)
```

**Cause:** Variable in checkpoint model not in current data.

**Solution:**
```stata
* Check what's in metadata
import delimited "output/schema.csv", clear
list variable_name

* Ensure data includes all checkpoint variables
```

### Issue 4: Very Large Datasets

**Symptom:** Rebuild takes > 10 minutes, runs out of memory.

**Solutions:**
```stata
* 1. Use stratification to process in chunks
datamirror init, strata(region) replace  // If you have regions

* 2. Sample for development
preserve
sample 10  // 10% sample for testing
* ... test workflow ...
restore

* 3. Increase Stata memory
set memory 4g
set max_memory 8g
```

### Issue 5: Correlations Don't Match

**Symptom:**
```
Overall correlation: r = 0.82 (expected > 0.95)
```

**Causes:**
- Variables constant within strata
- Too many missing values
- Categorical variables coded as numeric

**Check:**
```stata
* Variables constant within strata?
bysort strata_var: summarize suspicious_var
* SD should be > 0 within each stratum

* Missing values?
misstable summarize
* Should be < 50% missing

* Categorical as numeric?
tab education  // If < 10 unique values, should be categorical
```

## Advanced: Sharing Metadata Only

For maximum privacy, share metadata instead of synthetic data:

```stata
* After extract:
* Share these files:
*   - output/metadata.csv
*   - output/schema.csv
*   - output/marginals_*.csv
*   - output/correlations*.csv
*   - output/checkpoints.csv
*   - output/checkpoints_coef.csv
*   - output/manifest.csv

* Recipients can generate their own synthetic data:
datamirror rebuild using "output", clear seed(99999)
* Their seed (99999) gives different data
* But same checkpoint fidelity!
```

**Advantage:** No actual data shared, even synthetic.

**Limitation:** Recipients need DataMirror installed.

## Summary

DataMirror workflow:
1. ✅ **Extract:** Checkpoint key models → save metadata
2. ✅ **Rebuild:** Generate synthetic → matches distributions + checkpoints
3. ✅ **Validate:** Verify fidelity → `max(Δβ/SE) < 3` per checkpoint (see [FIDELITY_METRIC.md](FIDELITY_METRIC.md))

**Key commands:**
- `datamirror init` - Start session
- `datamirror checkpoint` - Save model
- `datamirror extract` - Export metadata
- `datamirror rebuild` - Generate synthetic
- `datamirror check` - Validate fidelity

For complete technical details, see [LAYER4.md](LAYER4.md).
For Layer 4 algorithm details, see [LAYER4.md](LAYER4.md).
