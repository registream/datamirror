# Fidelity Metric: Δβ/SE

**Date:** 2026-04-21
**Purpose:** Document the metric datamirror uses to judge whether synthetic data reproduces the target regression coefficients, and the threshold used in the test suite.

---

## The metric

For each coefficient `j` in a checkpointed regression, datamirror computes:

```
Δβ_j / SE_j
```

where `Δβ_j = |β̂_synth_j − β*_j|` is the absolute difference between the coefficient estimated on synthetic data and the target coefficient (recorded at checkpoint time), and `SE_j` is the standard error of the synthetic-data fit.

A value of 1 means the synthetic estimate is one standard error away from target. A value of 2 means two standard errors (roughly the 95% CI edge). A value of 3 means three standard errors (roughly 99.7% CI).

This is the natural "statistically indistinguishable from target" check: are we inside the confidence interval the estimator itself would draw around the synthetic estimate?

## Why not a fixed Δβ threshold

Earlier versions of the test suite used fixed absolute thresholds like `Δβ < 0.05` for continuous coefficients and `Δβ < 0.10` for intercepts. These are problematic:

1. **Sampling noise scales with the estimator's own uncertainty.** A coefficient with SE = 0.02 should land within ~0.04 of target (2 SE); a coefficient with SE = 0.5 should land within ~1.0 of target. One number does not fit both.
2. **Finite-N variance is not zero.** Even a perfectly specified DGP returns estimates that fluctuate by O(1/√N) across realisations. A strict point-estimate threshold will flake on noise rather than signal a real regression.
3. **Cross-model calibration is hard.** OLS coefficients on standardised predictors are on a different scale than nbreg log-link coefficients. A unified Δβ/SE scales both to the same "standard errors from target" units.

Δβ/SE makes the fidelity claim precise: the synthetic-data estimate is within the confidence interval around target, as judged by the estimator's own precision.

## The test threshold: 3 SE

Each subtest in the unit suite asserts `max(Δβ/SE) < 3` across the subtest's coefficients. 3 SE, not 2 SE. The reason is multiplicity.

### Single coefficient

For a well-specified DGP, each Δβ/SE is asymptotically `|N(0, 1)|`. A single-coefficient threshold of 2 SE corresponds to the standard 95% CI (P(|Z| < 2) ≈ 0.954). This is textbook.

### Max across k coefficients

The tests compute `max(Δβ/SE)` over several coefficients per subtest, then check that max against the threshold. Under the null, the max of k i.i.d. |N(0,1)| variables exceeds a threshold more often than a single draw does.

P(max(|Z|_1, ..., |Z|_k) < t):

| k coefs | t=2 SE | t=3 SE |
|---------|--------|--------|
| 1       | 0.954  | 0.997  |
| 3       | 0.869  | 0.991  |
| 4       | 0.828  | 0.988  |
| 5       | 0.790  | 0.985  |

At 2 SE with 4 coefficients per subtest, 17% of clean runs fail by chance. Across 9 subtests with a similar profile, expected flakes per full harness run ≈ 2 to 3. That is unacceptable for a regression test suite where we want failures to indicate real problems.

At 3 SE with 4 coefficients per subtest, ~1.2% fail by chance per subtest. Across 9 subtests, expected flakes ≈ 0.15 per run. Stable enough to trust.

### Bonferroni view

Equivalently, if we want a joint false-reject rate `α` across k coefficients in a subtest, the per-coefficient rate is `α/k` (Bonferroni-adjusted), which inverts to the following critical values under the standard normal:

| k coefs | Joint α = 0.05 → t | Joint α = 0.01 → t |
|---------|--------------------|--------------------|
| 3       | 2.39 SE            | 2.93 SE            |
| 4       | 2.50 SE            | 3.02 SE            |
| 5       | 2.58 SE            | 3.09 SE            |

A 3 SE per-coefficient threshold delivers approximately 99% joint CI across 3 to 5 coefficients per subtest. That is the right calibration for automated tests: strict enough to catch real regressions, lax enough to not flake on sampling noise.

### What happens in practice

Across the 9 unit tests, observed `max(Δβ/SE)` values span roughly 0.04 to 1.87 for tests that pass comfortably. The 3 SE ceiling is a safety margin rather than a tight fit. A test that lands near 2 SE is unusual but not a failure signal; a test that lands near 3 SE would prompt us to look at N (too small), the DGP (misspecified), or the data (pathological).

## What the paper should report

The test threshold is a yes/no gate for regression testing. The paper (and any user-facing accuracy claim) should report the full observed distribution of Δβ/SE from the replication packages, not a binary "passes at threshold X". Useful summary statistics:

- Median Δβ/SE across all coefficients in a replication
- 95th percentile
- Maximum
- Fraction of coefficients below 1 SE, below 2 SE, below 3 SE

This is the honest portrait of datamirror's accuracy. The test-suite threshold exists to catch regressions; the empirical distribution is the real claim.

## How this relates to other tools

The fidelity literature splits on this question:

- **Plasmode** (Franklin 2014, Schreck 2024) simulates y from the fitted model and reports coefficient recovery distributions without a binary pass/fail.
- **synthpop** (Nowok 2016) reports per-coefficient `compare.fit.synds` standardised differences, which is functionally equivalent to Δβ/SE with the original fit's SE as reference.
- **MI-synthesis** (Reiter 2005, Raghunathan 2003) uses Rubin's combining rules to construct a joint test of inferential equivalence. Closest to what we would do for a formal paper claim.

Datamirror's Δβ/SE < 3 convention is consistent with the standardised-difference diagnostics in synthpop and with the multi-coefficient max-statistic used in plasmode validation studies.

## TL;DR

- Δβ/SE replaces fixed Δβ thresholds: each coefficient is judged against the estimator's own precision.
- The test suite asserts `max(Δβ/SE) < 3` per subtest.
- 3 SE, not 2, because the max over k coefficients inflates the single-coefficient false-reject rate. 3 SE corresponds to ~99% joint CI across typical subtest sizes (3-5 coefficients).
- Tests are for regression-catching. The paper's accuracy claim should report the observed distribution, not a binary gate.

## References

- **Bonferroni, C. E. (1936).** "Teoria statistica delle classi e calcolo delle probabilità." *Pubblicazioni del R Istituto Superiore di Scienze Economiche e Commerciali di Firenze* 8: 3-62. Classical multiple-comparison correction.
- **Hochberg, Y., Tamhane, A. C. (1987).** *Multiple Comparison Procedures.* Wiley. Standard reference on max-statistic inference.
- **Franklin, J. M. et al. (2014).** "Plasmode simulation for the evaluation of pharmacoepidemiologic methods." *Computational Statistics & Data Analysis* 72. Reports coefficient recovery distributions.
- **Nowok, B., Raab, G. M., Dibben, C. (2016).** "synthpop: Bespoke Creation of Synthetic Data in R." *Journal of Statistical Software* 74(11). Discusses standardised-difference diagnostics.
- **Schreck, N. et al. (2024).** "Statistical plasmode simulations: potentials, challenges and recommendations." *Statistics in Medicine*. Current state-of-the-art review.
- **NBREG_DGP_DECISION.md** and **LOGIT_PROBIT_DGP_DECISION.md** (this repo): sibling decisions explaining why direct DGP sampling gives Δβ/SE ~ N(0,1) asymptotically for the nonlinear model family.
