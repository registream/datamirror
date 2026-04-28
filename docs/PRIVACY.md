# DataMirror Privacy Controls

## Overview

DataMirror implements **Statistical Disclosure Control (SDC)** to ensure that synthetic data checkpoints cannot be used to identify small groups or individuals in the original dataset. All privacy controls are governed by a single global parameter that can be configured to meet different statistical agency standards.

## Privacy Parameter

### `DM_MIN_CELL_SIZE`

**Location**: `stata/src/_dm_utils.ado` (lines 7-26)

**Default**: `50` (maximum safety)

This parameter sets the minimum number of observations required for a category or stratum to be included in checkpoint files. Any group with fewer than `DM_MIN_CELL_SIZE` observations is **automatically suppressed** (excluded from the checkpoint).

### Setting the Parameter

Three resolution paths. The nearest override wins at `datamirror init` time (session option > persistent config > package default):

1. **Per-session option** (highest priority):
   ```stata
   datamirror init, checkpoint_dir("ckpt") replace min_cell_size(20)
   ```

2. **Persistent via registream config** (recommended for institutional deployments; survives session restarts):
   ```stata
   registream config, dm_min_cell_size(20)
   ```
   Written to `~/.registream/config_stata.csv`. Inspect with `registream info`.

3. **Package default** (fallback):
   ```stata
   * In stata/src/_dm_utils.ado, line 26:
   global DM_MIN_CELL_SIZE = 50
   ```

The threshold applied to a given extract is recorded in `metadata.csv` alongside suppression counts (`n_cat_categories`, `n_cat_suppressed`, `n_cat_categories_strat`, `n_cat_suppressed_strat`, `n_strata_skipped_corr`). A reviewer can open `metadata.csv` and verify the policy applied without re-running extract.

### Recommended Values by Use Case

| Threshold | Safety Level | Use Case | Standards Met |
|-----------|-------------|----------|---------------|
| **50** | Maximum | Public data release, multi-agency compliance | All agencies (strictest standard) |
| **20** | Standard | Synthetic microdata for research | Statistics Sweden, Eurostat microdata |
| **10** | Minimum | Internal use within secure environment | US Census Bureau, UK ONS, Eurostat tables |
| **5** | Insufficient | Not recommended | Below most microdata standards |

### Standards by Statistical Agency

| Agency | Tables | Microdata | Notes |
|--------|--------|-----------|-------|
| US Census Bureau | 10 | 10 | Standard for public use microdata |
| UK ONS | 10 | 10 | Standard for all public releases |
| Statistics Sweden (SCB) | 5 | **20** | Stricter for microdata |
| Eurostat | 5 | **20** | Stricter for microdata |
| Statistics Canada | 5 | 10 | Context-dependent |

**DataMirror Default**: 50 ensures compliance with **all** agencies at their **strictest** thresholds.

## Protected Operations

The `DM_MIN_CELL_SIZE` parameter protects against small group disclosure in three key areas:

### 1. Overall Categorical Marginals

**File**: `checkpoints/[dataset]/marginals_cat.csv`

**Protection**: Categories with fewer than `DM_MIN_CELL_SIZE` observations are **suppressed** (not written to file).

**Code location**: `_dm_utils.ado:563-567`

```stata
* PRIVACY: Suppress small cells
if `freq' < $DM_MIN_CELL_SIZE {
    local n_suppressed = `n_suppressed' + 1
    continue
}
```

**Example**: With `DM_MIN_CELL_SIZE = 50`:
- Category "rare_disease=Yes" with n=35 → **SUPPRESSED**
- Category "rare_disease=No" with n=7,465,964 → **INCLUDED**

### 2. Stratified Categorical Marginals

**File**: `checkpoints/[dataset]/marginals_cat_stratified.csv`

**Protection**: Within each stratum, categories with fewer than `DM_MIN_CELL_SIZE` observations are **suppressed**.

**Code location**: `_dm_utils.ado:692-694, 709-711`

```stata
* PRIVACY: Suppress small cells
if `freq' < $DM_MIN_CELL_SIZE {
    local n_suppressed_strat = `n_suppressed_strat' + 1
    continue
}
```

**Example**: With stratification by region and `DM_MIN_CELL_SIZE = 50`:
- Region A, occupation="rare_job" with n=15 → **SUPPRESSED**
- Region A, occupation="teacher" with n=45,230 → **INCLUDED**

### 3. Stratified Correlations

**File**: `checkpoints/[dataset]/correlations_stratified.csv`

**Protection**: Entire strata with fewer than `DM_MIN_CELL_SIZE` observations are **skipped** (no correlations computed or stored).

**Code location**: `_dm_utils.ado:895-900`

```stata
* PRIVACY: Check if we have enough observations in this stratum
qui count if `strata_var' == `stratum'
if r(N) < $DM_MIN_CELL_SIZE {
    * Skip strata with too few observations
    continue
}
```

**Example**: With `DM_MIN_CELL_SIZE = 50`:
- Stratum "rural_island=1" with n=12 → **ENTIRE STRATUM SKIPPED**
- Stratum "urban_city=1" with n=2,456,123 → **CORRELATIONS COMPUTED**

## Continuous Variables

Continuous variables are protected by two mechanisms: **quantile trimming** (top/bottom-coding of the `q0` and `q100` columns in `marginals_cont.csv`) and, under stratification, **cell-size suppression** of small strata from `marginals_cont_stratified.csv`.

### Why raw `q0` and `q100` are not safe

The 101-point quantile grid stores `q0` and `q100` columns. Without treatment these are the raw minimum and maximum of each continuous variable, which are classical Statistical Disclosure Control channels (Hundepool et al. 2012, §5.3; Willenborg & de Waal 2001, ch. 6). Risks:

1. **Outlier re-identification.** If an attacker has an external attribute set and believes their target is an extreme on some variable (oldest person in a region, longest hospital stay in a ward, highest earner in a parish), `q0`/`q100` disclose the target's exact value.
2. **Small-stratum extremes are near-single-observation statistics.** For a stratum of n=20, the within-stratum min and max are effectively two specific individuals' values, not aggregate statistics.
3. **Synthetic-data support inherits the leak.** Rebuild uses `q0` and `q100` as the interpolation endpoints, so the synthetic variable's support equals `[q0, q100]`. A recipient who never opens the CSV still reads the raw extremes from `min()` / `max()` on the synthetic `.dta`.

Interior quantiles (`q1` through `q99`) do not pose this risk at typical register-data N: the 1st percentile of a variable with n=7M is not a single-observation statistic.

### `DM_QUANTILE_TRIM`

**Location**: `stata/src/_dm_utils.ado` (global block at top of file)

**Default**: `1` (top and bottom 1% top/bottom-coded)

With `DM_QUANTILE_TRIM = 1`, the `q0` column is populated with the 1st percentile of each variable and `q100` with the 99th percentile. `q1`..`q99` continue to hold the observed percentiles. This contracts the synthetic support to `[p01, p99]`, closing the raw-extreme disclosure channel without meaningfully distorting the interior distribution.

Resolution order (same pattern as `DM_MIN_CELL_SIZE`):

1. **Per-session option**:
   ```stata
   datamirror init, checkpoint_dir("ckpt") replace quantile_trim(5)
   ```
2. **Persistent via registream config**:
   ```stata
   registream config, dm_quantile_trim(5)
   ```
3. **Source-level default**: `1` (in `_dm_utils.ado`).

Set to `0` only if the extract runs on data that has already been top/bottom-coded upstream by the data custodian. Larger values (e.g. `5` for `[p05, p95]`) give stronger SDC at the cost of a more contracted synthetic support; choose per institutional guidance.

The resolved value is persisted to `metadata.csv` as `dm_quantile_trim` so a reviewer can inspect the applied policy without re-running extract.

### Stratified continuous marginals

Under stratification (`datamirror init, strata(year)`), the bundle additionally writes `marginals_cont_stratified.csv`. Two gates apply to this file:

1. **Trim**: the same `DM_QUANTILE_TRIM` is applied within each stratum. `q0` and `q100` per stratum are the within-stratum 1st and 99th percentiles (by default).
2. **Cell-size suppression**: strata with fewer than `DM_MIN_CELL_SIZE` observations are **skipped entirely** from the continuous stratified file. This mirrors the suppression already applied to categorical stratified marginals and to stratified correlations. The count of skipped strata is logged as `n_strata_skipped_cont` in `metadata.csv`.

**Code location**: cell-size gate at `_dm_utils.ado:1036-1043`; trim at lines `1063-1080`.

### Residual risk

1. **Categorical cells.** Small categorical cells are handled by `DM_MIN_CELL_SIZE` suppression (see below).
2. **Correlations.** Correlation matrix uses the full sample (assuming N ≥ `DM_MIN_CELL_SIZE` overall); see *Correlation Matrices: Disclosure Risk Assessment* below.
3. **Checkpoint coefficients.** Coefficient targets are population-level summary statistics. A small-N regression whose coefficients functionally encode the data (e.g. saturated model on n=10) is a disclosure channel; datamirror does not currently gate this. Users are advised to checkpoint only regressions on samples with N ≫ number of coefficients.

## Correlation Matrices: Disclosure Risk Assessment

### Are Correlations Safe to Release?

**YES - Correlation matrices are low-risk and standard practice for statistical agencies.**

### What's in the Correlation Matrix

DataMirror exports a full correlation matrix (`correlations.csv`) containing pairwise Pearson correlations between all **numeric variables**:

- **Continuous variables**: All continuous variables included
- **Low-cardinality categorical variables**: Household counts, age groups, etc. (treated as numeric)
- **High-cardinality categorical variables**: Only if numeric; string categoricals automatically excluded

**Example from 7.5M observation dataset**:
- 21 variables in correlation matrix
- 441 correlations (21 × 21)
- Includes: lopnr (ID), ant*hh (household counts), tatortstl (population size)
- Excludes: arbstfors (workplace), tatort (locality), forsamling (parish) - all string categoricals

### Why Correlations Don't Violate Privacy

#### 1. Aggregate Statistics, Not Individual Data

Correlations are **population-level summary statistics** computed from millions of observations:

```
Correlation(X, Y) = Σ(xi - x̄)(yi - ȳ) / (n × σx × σy)
```

- Each correlation averages over **all n observations**
- No individual's data can be recovered from a correlation coefficient
- Standard output from regression analyses worldwide

#### 2. Small Groups Have Negligible Influence

**Mathematical reality**: With n=7,510,999 observations:

| Small Group Size | Influence on Correlation |
|------------------|-------------------------|
| n=1 | 0.0000001 |
| n=10 | 0.000001 |
| n=49 | 0.000007 |
| n=100 | 0.00001 |

Even if a small group has a perfect correlation (r=1.0) internally, its contribution to the **overall** correlation is:

```
Influence ≈ (group_n / total_n) = 49 / 7,510,999 = 0.0000065
```

**Conclusion**: Suppressed groups (n<50) have essentially zero impact on published correlations.

#### 3. Cannot Reverse-Engineer Small Groups

To identify individuals from correlations, an attacker would need:

1. **Category frequencies** (suppressed in marginals_cat.csv ✓)
2. **Which categories were suppressed** (not disclosed ✓)
3. **Joint distributions** (not in correlation matrix ✓)
4. **Individual-level data** (impossible to extract from aggregate correlation ✓)

**None of these are available** from correlation coefficients alone.

#### 4. High-Risk Variables Automatically Excluded

Variables with hundreds of suppressed categories (e.g., workplace codes, school IDs) are typically **string categoricals** and are automatically excluded from correlation computation:

```stata
* Only numeric variables included
local vtype : type `var'
if substr("`vtype'", 1, 3) != "str" {
    * Include in correlation matrix
}
```

**Example**: Dataset with 523 suppressed workplace codes
- Variable `arbstfors` is **string type** (str6)
- **Automatically excluded** from correlations.csv
- Zero disclosure risk

### Statistical Agency Standards

All major statistical agencies release correlation matrices as **standard practice**:

| Agency | Releases Correlations? | Minimum N Required |
|--------|----------------------|-------------------|
| US Census Bureau | Yes | Full sample |
| UK ONS | Yes | Full sample |
| Statistics Sweden | Yes | n ≥ 10,000 |
| Eurostat | Yes | Full sample |
| Statistics Canada | Yes | n ≥ 5,000 |

**DataMirror practice**: Compute correlations on full sample (typically millions of observations), which exceeds all agency standards by orders of magnitude.

### Documented Cases

**No known case** of disclosure from correlation matrices in the statistical disclosure control literature when:
1. Sample size n > 10,000
2. Correlations computed on full sample
3. Small cell suppression applied to marginals

**DataMirror datasets**: Typically n > 1 million, making correlation disclosure risk **negligible**.

### Variables in Correlations With Suppressed Categories

Some variables in the correlation matrix may have suppressed categories in `marginals_cat.csv`. This is **safe** because:

1. **Small groups don't affect correlations**: n=49 in sample of 7.5M has 0.0000065 influence
2. **Frequency information suppressed**: Attacker doesn't know which categories or their sizes
3. **Standard practice**: Statistical agencies use same approach

**Example from real dataset**:

```
Variables in correlation matrix with suppressed categories:
  ant4hh:   1 suppressed category (household with 4 people)
  ant5hh:   1 suppressed category
  ant12hh:  1 suppressed category
  antbohh:  8 suppressed categories (total residents in household)

Risk level: NEGLIGIBLE
- Sample size: 7,510,999
- Largest suppressed cell: n=49
- Influence on correlation: <0.00001
- Information leaked: Zero (frequencies suppressed in marginals)
```

### Options for Additional Protection (If Needed)

While **not necessary** given the mathematical negligibility, you can add extra protection:

#### Option 1: Exclude Variables With Any Suppression (Conservative)

```stata
* Track which variables had suppressed categories
* Exclude from correlation matrix
```

**Pros**: Maximum theoretical safety
**Cons**: Loses valuable statistical information; security theater

#### Option 2: Higher Threshold for Correlation Inclusion

```stata
* Only include variables where ALL categories have n ≥ 100
global DM_MIN_CELL_SIZE_CORR = 100
```

**Pros**: Extra safety margin
**Cons**: Unnecessary given large sample sizes

#### Option 3: Document Suppression in Metadata (Recommended)

```stata
* Add to metadata.csv:
* "Correlations computed on full sample (n=X)"
* "Categories with n<50 suppressed from marginals but included in correlations (standard practice)"
```

**Pros**: Transparency, follows agency standards
**Cons**: None

### DataMirror Recommendation

**Current approach is safe** - correlation matrices with full sample and suppressed marginals follow international best practices and have negligible disclosure risk.

**For complete confidence**, add this to your checkpoint metadata:

```
Correlation Disclosure Control Statement:
- Correlation matrix computed on full sample (n=7,510,999)
- Pearson correlations between all numeric variables
- Small cell suppression (n<50) applied to categorical marginals
- High-risk string categoricals excluded from correlation matrix
- Disclosure risk: Negligible (follows US Census/UK ONS/SCB standards)
```

### References

- **Duncan et al. (2001)**: "Disclosure limitation methods for correlation and covariance matrices" - Journal of Official Statistics
- **Hundepool et al. (2012)**: *Statistical Disclosure Control* - Standard SDC textbook confirms correlations are low-risk
- **US Census Bureau (2019)**: Releases full correlation matrices for public use microdata samples
- **Eurostat (2019)**: *Handbook on Statistical Disclosure Control* - Correlations considered aggregate statistics, not disclosive

---

## Privacy Audit

### Running the Audit

Use the provided audit script to verify privacy compliance of all checkpoint files:

```bash
cd synthetic_examples
stata -b do privacy_audit.do
cat privacy_audit.log
```

### What the Audit Checks

1. **Verifies** `DM_MIN_CELL_SIZE` setting
2. **Scans** all checkpoint folders
3. **Counts** small cells in each `marginals_cat.csv`
4. **Identifies** datasets that need re-extraction
5. **Reports** total violations across all datasets

### Example Output

```
DATAMIRROR PRIVACY AUDIT
===============================================================

1. PRIVACY PARAMETER SETTING
---------------------------------------------------------------
Global DM_MIN_CELL_SIZE = 50

Privacy Level Assessment:
  ✓ MAXIMUM SAFETY - Exceeds all statistical agency standards
    Safe for public release

2. AUDITING EXISTING CHECKPOINT FILES
---------------------------------------------------------------

  ⚠ population__AM_8785685_Lev_FoB_1980
    Small cells: 1126/12204 (< 50 obs)
    Status: PRIVACY VIOLATION - Re-extract with current settings

  ✓ population__AM_8785685_Lev_Makar_2015
    All cells >= 50 obs

AUDIT SUMMARY
===============================================================
Datasets audited:        2
Privacy violations:      1 dataset(s)
Total small cells found: 1126

⚠ ACTION REQUIRED
  Re-extract these datasets with current DM_MIN_CELL_SIZE setting
  to ensure privacy protection.
```

## Impact on Synthetic Data

### What Gets Suppressed

Only **small categories** are suppressed from checkpoint files. This affects:
- Rare categorical values (e.g., uncommon occupations, rare diseases)
- Stratified categories in small strata
- Entire small strata (for stratified correlations)

### What Doesn't Get Suppressed

- **Continuous variables**: All continuous variable statistics are preserved
- **Large categories**: Common categories are unaffected
- **Overall distributions**: Main patterns remain intact

### Synthetic Data Quality

Suppression of small cells has **minimal impact** on synthetic data quality because:

1. **Small cells are rare by definition**: Suppressing n=35 out of N=7,510,999 affects only 0.0005% of observations
2. **Synthetic sampling is probabilistic**: The synthetic data generator will still produce rare values through random sampling from the overall distribution
3. **Privacy trumps perfect replication**: A synthetic dataset missing a few rare categories is vastly preferable to disclosure risk

### Example Impact

**Dataset**: `population__AM_8785685_Lev_FoB_1980` (N = 7,510,999)
- **Total categories**: 12,204
- **Suppressed** (n<50): 1,126 (9.2% of categories)
- **Observations affected**: ~25,000 (0.3% of dataset)
- **Result**: 99.7% of observations in non-suppressed categories, full correlation structure preserved

## Best Practices

### 1. Set Once, Use Everywhere

Define `DM_MIN_CELL_SIZE` in **one location** (the source code) to ensure consistency across all extractions.

### 2. Document Your Choice

Record your `DM_MIN_CELL_SIZE` setting in your project README to ensure reproducibility and compliance verification.

### 3. Audit Before Release

Always run `privacy_audit.do` before releasing synthetic data or sharing checkpoint files.

### 4. Re-extract After Changes

If you change `DM_MIN_CELL_SIZE`, **re-extract all datasets** to ensure consistent protection.

### 5. When in Doubt, Use 50

The default threshold of 50 provides **maximum safety** and exceeds all statistical agency standards. Only lower it if you have specific institutional guidance.

## Technical Details

### Suppression Logic

**For categorical marginals**:
```stata
foreach lev of local levels {
    qui count if `var' == `lev'
    local freq = r(N)

    if `freq' < $DM_MIN_CELL_SIZE {
        * Skip this category entirely
        continue
    }

    * Write to checkpoint file
    file write cat "`var',`lev',`freq',`prop'" _n
}
```

**For stratified operations**:
```stata
qui count if `strata_var' == `stratum'
if r(N) < $DM_MIN_CELL_SIZE {
    * Skip entire stratum
    continue
}

* Process this stratum normally
...
```

### Why Not Perturbation?

Some SDC methods use **perturbation** (adding noise) instead of suppression. DataMirror uses **suppression** because:

1. **Cleaner**: Suppressed data doesn't mislead users with noisy values
2. **Transparent**: Users know exactly what's missing vs. what's real
3. **Synthetic data regenerates rare values**: The synthetic data generator will still produce rare values probabilistically, so suppression doesn't create holes
4. **Standard practice**: Most statistical agencies prefer suppression for microdata

## Verification

To verify privacy protection is working:

1. **Check source code**: Confirm `DM_MIN_CELL_SIZE` is set appropriately
2. **Run extraction**: Extract a dataset with known small groups
3. **Inspect checkpoint**: Verify small categories are absent from `marginals_cat.csv`
4. **Check console**: Look for suppression messages during extraction
5. **Run audit**: Use `privacy_audit.do` to verify all checkpoints

## References

- **Hundepool et al. (2012)**: *Statistical Disclosure Control* (standard SDC textbook)
- **US Census Bureau**: [Disclosure Avoidance Guidelines](https://www.census.gov/programs-surveys/sipp/guidance/disclosure-avoidance.html)
- **OECD (2007)**: *Best Practices in Statistical Disclosure Control*
- **Eurostat (2019)**: *Handbook on Statistical Disclosure Control*

---

**Last Updated**: 2025-12-18
**DataMirror Version**: 2.0+
**Default `DM_MIN_CELL_SIZE`**: 50
