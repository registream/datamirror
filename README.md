# datamirror

**Checkpoint-constrained synthetic data for the applied researcher**

datamirror is a Stata command for the individual researcher working with confidential microdata. You run your analysis, tag the regressions that matter, and export a small disclosure-safe bundle (marginals, correlations, coefficient targets). Running `datamirror rebuild` on that bundle reconstructs a synthetic dataset on which your regressions produce the same coefficient estimates within sampling noise. You keep the original data on your secure machine; the bundle is what you share with collaborators, send to a replication archive, or open on your laptop for code development.

The primary use cases are:

- **Local development**: write and debug analysis code on your laptop against a synthetic mirror, without moving confidential data off the secure environment.
- **Collaborator sharing**: give co-authors a working dataset they can run your do-files against without clearance.
- **Replication packages**: ship the bundle alongside your published paper so journal reviewers and future researchers can rerun your regressions without special data access.
- **Code review**: let a colleague audit your analysis on synthetic data before you commit.

datamirror is not a data-curation tool for an institution to publish on behalf of users; it is a tool the user runs on their own analysis. For institutional metadata publishing see the sibling package [autolabel](https://registream.org/docs/autolabel).

## What makes it different: Layer 4 (checkpoint constraints)

Traditional synthetic-data generators match univariate and bivariate distributions; they make no promise about regression estimates. datamirror adds a fourth layer on top of that: **checkpoint constraints**, which ensure that regressions run on the synthetic data recover coefficient estimates statistically indistinguishable from the original (Δβ/SE < 3; see [docs/FIDELITY_METRIC.md](docs/FIDELITY_METRIC.md)).

```stata
* Original data
reg wellbeing age i.education female
* β = [0.003, 0.042, -0.005, -0.111, 0.205]

* Synthetic data (DataMirror)
reg wellbeing age i.education female
* β ~ [0.003, 0.043, -0.006, -0.110, 0.206]   (within 1 SE of target)
```

## Quick Start

### Installation

Requires Stata 16 or later.

`datamirror` is a peer package to the `registream` core library. From v3.0.0 of the ecosystem each module is an independent Stata package; install only what you need.

```stata
net install registream, from("https://registream.org/install/stata/latest") replace
net install datamirror, from("https://registream.org/install/stata/latest") replace
```

For local development, put `stata/src` on the ado path:

```stata
adopath + "stata/src"
```

Python and R ports are on the roadmap; see [ROADMAP.md](ROADMAP.md).

### Basic Usage

```stata
* 1. Load your sensitive data
use "my_confidential_data.dta", clear

* 2. Initialize DataMirror
datamirror init, checkpoint_dir("output") replace

* 3. Run your key analyses and checkpoint them
reg employed age female
datamirror checkpoint, tag("employment_model")

reg wellbeing age i.education female
datamirror checkpoint, tag("wellbeing_model")

* 4. Extract metadata (distributions + checkpoint targets)
datamirror extract, replace

* 5. Generate synthetic data
datamirror rebuild using "output", clear seed(12345)

* 6. Validate fidelity
datamirror check using "output"
```

## The Four-Layer Architecture

DataMirror preserves data fidelity through four constraint layers plus schema metadata:

### Schema (Metadata)
- Variable types (numeric, categorical, string)
- Value labels
- Variable labels
- Storage formats

### Layer 1: Marginal Distributions
- **Continuous**: 101-point quantile distributions (p0, p1, ..., p100). Variables whose original values are all integers are detected and rounded back to integers in the synthetic output.
- **Categorical**: complete frequency tables for all observed values.

### Layer 2: Correlation Structure
- Gaussian copula captures pairwise dependencies between variables.

### Layer 3: Stratification
- All properties hold **within strata** (e.g. by year, region, wave). Enables panel or longitudinal synthesis.

### Layer 4: Checkpoint Constraints

Regression coefficients are preserved across seven model families. The fidelity metric is Δβ/SE (see [docs/FIDELITY_METRIC.md](docs/FIDELITY_METRIC.md)); the unit-test harness asserts `max(Δβ/SE) < 3` per subtest.

Two engines share the dispatcher depending on outcome geometry:

**Iterative outcome-shift (continuous outcomes):**
- `regress` (OLS)
- `reghdfe` (fixed effects)
- `ivregress` (IV, uses instrument-conditioned shift on y)

**Direct DGP sampling (discrete outcomes):**
- `poisson` (Gamma-Poisson draw at target β*, α* = 0)
- `nbreg` (Gamma-Poisson mixture at target β*, α*; see [docs/NBREG_DGP_DECISION.md](docs/NBREG_DGP_DECISION.md))
- `logit` (inverse-logit + Bernoulli draw; see [docs/LOGIT_PROBIT_DGP_DECISION.md](docs/LOGIT_PROBIT_DGP_DECISION.md))
- `probit` (normal CDF + Bernoulli draw; same doc)

**Factor variables** are preserved by construction under DGP sampling, so the earlier restriction ("nonlinear models cannot preserve factor coefficients") no longer applies. Factor Δβ/SE lands in the same range as continuous predictors under the current 9/9 unit-test harness.

## Workflow

```
┌─────────────────────────────────────────────┐
│ EXTRACT PHASE                               │
│ Original Data                               │
│   ↓                                         │
│ datamirror init + checkpoint + extract      │
│   ↓                                         │
│ Metadata Files:                             │
│   - metadata.csv (session + counts)         │
│   - schema.csv                              │
│   - marginals_cont.csv                      │
│   - marginals_cat.csv                       │
│   - correlations.csv                        │
│   - checkpoints.csv (incl. alpha column)    │
│   - checkpoints_coef.csv (long, cp_num FK)  │
│   - manifest.csv (self-documents the dir)   │
└─────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────┐
│ REBUILD PHASE                               │
│ Metadata Files                              │
│   ↓                                         │
│ datamirror rebuild                          │
│   ↓                                         │
│ Stage 1: Gaussian-copula sample             │
│          (adjusted for Layer-2 correlations)│
│ Stage 2: Marginal transform (Layer 1)       │
│ Stage 3: Apply checkpoints (Layer 4):       │
│          - continuous outcomes: iterative   │
│          - discrete outcomes:   direct DGP  │
│ Stage 4: Apply within strata (Layer 3)      │
│   ↓                                         │
│ Synthetic Data                              │
└─────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────┐
│ VALIDATION PHASE                            │
│ datamirror check                            │
│   ↓                                         │
│ Fidelity Report:                            │
│   - Marginal KS tests                       │
│   - Correlation recovery                    │
│   - Checkpoint Δβ and Δβ/SE                 │
└─────────────────────────────────────────────┘
```

## Commands

### `datamirror init`
Initialize a DataMirror session and specify the output directory.

```stata
datamirror init, checkpoint_dir(string) [strata(varname) min_cell_size(#) quantile_trim(#) replace]
```

Options:
- `checkpoint_dir()`: directory for metadata files.
- `strata()`: stratification variable (optional).
- `min_cell_size()`: per-session minimum cell size for categorical suppression, and (under stratification) for skipping small strata from continuous marginals. Three-tier resolution: session option wins, then `registream` config, then package default 50.
- `quantile_trim()`: percentile at which `q0` and `q100` in `marginals_cont.csv` are top/bottom-coded (continuous SDC). Default 1 (stores 1st and 99th percentile as the extremes). Same three-tier resolution as `min_cell_size`. See [docs/PRIVACY.md](docs/PRIVACY.md) for rationale.
- `replace`: overwrite existing directory.

---

### `datamirror checkpoint`
Save the most recent estimation result as a replication target.

```stata
datamirror checkpoint, tag(string) [notes(string)]
```

Must be called immediately after an estimation command whose results sit in `e()`.

Supported estimation commands: `regress`, `reghdfe`, `ivregress`, `logit`, `probit`, `poisson`, `nbreg`.

---

### `datamirror extract`
Export all metadata from the current dataset.

```stata
datamirror extract [, replace]
```

Output files:
- `metadata.csv` (session info, suppression counts, min_cell_size used)
- `schema.csv`
- `marginals_cont.csv`
- `marginals_cat.csv`
- `correlations.csv`
- `checkpoints.csv` (one row per tagged regression; includes per-checkpoint `alpha` for `nbreg`)
- `checkpoints_coef.csv` (one row per coefficient across all checkpoints; `cp_num` foreign key)
- `manifest.csv` (self-describing file listing with row counts)

---

### `datamirror rebuild`
Generate synthetic data from metadata.

```stata
datamirror rebuild using path [, clear seed(#)]
```

The rebuild is fully disk-driven: it does not depend on any session state from the extract call.

---

### `datamirror check`
Validate synthetic data fidelity.

```stata
datamirror check using path
```

Reports marginal KS tests, correlation recovery, and checkpoint Δβ alongside Δβ/SE.

## Current Capabilities

**Data types:**
- Continuous numeric
- Categorical (including factor notation, `i.education`)
- Binary

**Estimation commands (Layer 4):**
- `regress`, `reghdfe`, `ivregress` (iterative outcome-shift engine)
- `poisson`, `nbreg`, `logit`, `probit` (direct DGP sampling)

**Stratification:** single stratification variable; all Layer 1–2 properties hold within strata; supports unbalanced panels.

**Missing data:** variables with missing values are supported, and the per-variable missingness share is preserved.

**Test status:** 12 unit subtests pass at the current `max(Δβ/SE) < 3` threshold: seven single-estimator subtests, multi-checkpoint orchestration, integer-support preservation, unsupported-estimator rejection, the `auto` prefix, and the UK Household Longitudinal Study end-to-end integration (data shipped at `stata/tests/data/ukhls_clean.dta`).

## Repository Structure

```
datamirror/
├── stata/
│   ├── src/
│   │   ├── datamirror.ado              # Main dispatcher
│   │   ├── _dm_constraints.ado           # Per-model Layer 4 coefficient-preservation programs
│   │   └── _dm_utils.ado    # Core utilities
│   └── tests/                          # Unit tests
├── docs/                               # Design and reference docs
├── examples/                           # Example workflows
└── replication/                        # Replication-package tests
```

## Documentation

- **[README.md](README.md)**: you are here.
- **[docs/LAYER4.md](docs/LAYER4.md)**: Layer 4 architecture (both engines).
- **[docs/SUPPORTED_MODELS.md](docs/SUPPORTED_MODELS.md)**: per-model catalog.
- **[docs/USAGE.md](docs/USAGE.md)**: usage guide with examples.
- **[docs/FIDELITY_METRIC.md](docs/FIDELITY_METRIC.md)**: why Δβ/SE and why `< 3`.
- **[docs/PRIVACY.md](docs/PRIVACY.md)**: configurable SDC controls (min cell size, quantile trim) and what they protect.
- **[docs/COMPLIANCE.md](docs/COMPLIANCE.md)**: primary-source audit against SCB, DST, SSB, Eurostat, ONS, FSRDC, IAB, and StatCan rules.
- **[docs/REQUIREMENTS_CHECKLIST.md](docs/REQUIREMENTS_CHECKLIST.md)**: flat rule-by-rule checklist across all eight agencies, status for each.
- **[docs/NBREG_DGP_DECISION.md](docs/NBREG_DGP_DECISION.md)**: why nbreg uses direct DGP sampling.
- **[docs/LOGIT_PROBIT_DGP_DECISION.md](docs/LOGIT_PROBIT_DGP_DECISION.md)**: same for logit/probit.
- **[docs/IV_CONSTRAINT_DECISION.md](docs/IV_CONSTRAINT_DECISION.md)**: closed-form Newton step for 2SLS.
- **[docs/IV_JOINT_CONSTRAINT_DECISION.md](docs/IV_JOINT_CONSTRAINT_DECISION.md)**: joint Newton for shared-outcome IV groups.
- **[replication/RESULTS.md](replication/RESULTS.md)**: 4 AEA replication packages at Δβ/SE < 3.
- **[ROADMAP.md](ROADMAP.md)**: post-v1.0 work.

## Citation

To print the recommended citation inside Stata:

```stata
datamirror cite
```

Plain-text:

> Clark, J. (2026). *datamirror: checkpoint-constrained synthetic data for register-data workflows* (version 1.0.0) [Computer software]. https://registream.org/docs/datamirror

BibTeX:

```bibtex
@software{datamirror2026,
  title   = {datamirror: Checkpoint-constrained synthetic data for register-data workflows},
  author  = {Clark, Jeffrey},
  year    = {2026},
  version = {1.0.0},
  url     = {https://registream.org/docs/datamirror}
}
```

See also [`CITATION.cff`](CITATION.cff) for machine-readable metadata.

**If you publish results generated with datamirror**, cite both the tool and the underlying methodology papers for the checkpoint-preservation layer applicable to your regression family (linked in [docs/LAYER4.md](docs/LAYER4.md)).

## Reproducibility

A checkpoint directory is an **immutable artifact**. Given the same directory and the same `seed()`, `datamirror rebuild` produces bit-for-bit identical synthetic data. A do-file that rebuilds from a checkpoint directory saved today will produce the same synthetic dataset when re-run in five years. The rebuild has no external dependencies beyond the Stata version and the `datamirror` + `registream` packages. This is true by construction: Layer 1 marginals, Layer 2 correlations, and Layer 4 checkpoint coefficients are all stored as plain CSV files; the Gaussian copula draw in Layer 3 is deterministic given the seed.

Updates to datamirror itself cannot retroactively change synthetic data produced by an earlier rebuild run. If you version-pin `datamirror` in your project (e.g. via `registream config, datamirror_version("1.0")`), your rebuild output is frozen against package changes too.

## License

BSD 3-Clause. See [LICENSE](LICENSE).

## Status

- Code complete. Four-layer architecture shipped. 12-subtest harness (seven single-estimator, multi-checkpoint orchestration, integer-support preservation, unsupported-estimator rejection, `auto` prefix, UKHLS end-to-end integration) at `max(Δβ/SE) < 3`.
- 4 AEA replication packages validate end-to-end; 349 of 353 coefficient comparisons pass at `Δβ/SE < 3`. See [replication/RESULTS.md](replication/RESULTS.md).
- Future directions (joint OLS, rare-binary copula improvement, xtreg / ivreghdfe) and Python/R ports are tracked in [ROADMAP.md](ROADMAP.md).
