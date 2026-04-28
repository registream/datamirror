# Logit / Probit: Direct DGP Sampling Decision

**Date:** 2026-04-21
**Author:** Jeffrey Clark
**Context:** Layer 4 coefficient adjustment for binary-outcome models.
**Decision:** Replace the iterative paired-swap + predictor-shift engine with direct Bernoulli sampling from the model's canonical DGP. Sibling decision to `NBREG_DGP_DECISION.md`; generalises the same principle to binary outcomes.

---

## What the old approach was

`_dm_constrain_logit` and `_dm_constrain_probit` both called `_dm_constrain_nonlinear`, which ran an iterative loop:

1. Fit `logit` or `probit` on the current (X, y).
2. For each factor variable with |Δβ| above tolerance: swap observations between adjacent levels to shift that coefficient.
3. For each continuous predictor: shift x by `λ · Δβ · gradient` (y is discrete so the outcome cannot be shifted).
4. Repeat for up to max_iter iterations.

## What actually happened

The continuous-predictor path worked (unit-test subtests with only continuous predictors passed with Δβ/SE well under 2). The factor-variable path did not: observed Δβ/SE in logit/probit factor subtests landed around 7, well beyond the 2-SE target. The swap algorithm shifts observations in a way that is topologically coarse: you can only move entire observations between levels, and the constraint of preserving marginal class counts (of y) forces tight trade-offs that do not recover factor coefficients at reasonable tolerance.

The tests worked around this by asserting on continuous coefficients only and displaying factor Δβ/SE as a diagnostic.

## Why iterative paired-swap is structurally weak for factor preservation

Binary outcomes live on the Bernoulli lattice: each y is 0 or 1. Shifting X to change β̂ works when the predictor is continuous (you have a smooth dimension to move along). For factor levels, the algorithm has two levers: move *which observations* sit at each level, and accept the marginal-count preservation constraint. Those levers are discrete, and targeting a specific β̂ change through them is an integer-programming problem that the existing heuristic (adjacent-level swapping) solves only approximately.

The paired-swap engine was invented because earlier Layer-4 code assumed we should not resample y (we only observed y, so we adjusted X around it). Once we accept DGP sampling for count models (NB2 decision, 2026-04-21), there is no principled reason to keep the resample-avoidance constraint for binary models. Every plasmode and MI-synthesis paper on binary outcomes samples y from the fitted model.

## Why direct DGP sampling is correct

The binary DGP for logit is:
```
p*_i = invlogit(X_i · β*)
y_i  ~ Bernoulli(p*_i)
```

For probit:
```
p*_i = Φ(X_i · β*)
y_i  ~ Bernoulli(p*_i)
```

Fitting `logit y on X` or `probit y on X` on data generated this way recovers β* within sampling error of order O(1/√N). Factor-level coefficients are recovered by construction because the DGP is applied at the observation level, not the coefficient level. This is textbook generalised-linear-model theory (McCullagh & Nelder §4).

## Implementation notes

- **Inverse link.** Stata's `invlogit()` for logit, `normal()` for probit. Both accept a linear predictor as argument.
- **Linear-predictor construction.** Same pattern as `_dm_constrain_poisson` / `_dm_constrain_nbreg`: loop over the varnames / target coefficients, accumulate `xb += target · X` for continuous predictors and `xb += target · (base == level)` for decoded factor levels.
- **Bernoulli draw in Stata.** `y = runiform() < p_star` produces a 0/1 vector with `P(y=1) = p_star`. No separate `rbinomial` call needed; the direct uniform comparison is idiomatic.
- **Separation safeguard.** For linear predictors with |xb| > ~6, `p*` saturates near 0 or 1. A subsequent `logit` fit can then hit separation (Albert and Anderson 1984; Heinze and Schemper 2002) and fail to converge. Clip `p*` to `[ε, 1-ε]` with `ε = 1e-4` before sampling. This is analogous to the post-sampling clip we use for count outcomes against the mean-variance MLE boundary, just on the probability scale.
- **Engine consolidation.** After this change, `_dm_constrain_nonlinear` has zero callers (logit, probit, poisson, nbreg all bypass it now). It can be removed.

## Tradeoffs honestly

**What we lose:**

1. *Exact marginal class count.* The paired-swap preserved `Σy_i` by construction. DGP sampling gives `E[Σy_i] = Σp*_i` with `O(√N)` fluctuation. In practice the class proportion differs from the original by at most about `1/√N`. Not a meaningful loss for coefficient fidelity claims.
2. *Observation-level label stability.* Swap kept `y` close to the observed values where possible. DGP resamples `y` completely. This is actually a privacy win (cleaner break from observed outcomes), not a loss.

**What we gain:**

1. *Factor coefficients preserved by construction.* The core motivation. Δβ/SE for factor levels now lands in the same O(1/√N) range as continuous predictors.
2. *Unified story across all four nonlinear models.* logit, probit, poisson, nbreg all use direct DGP sampling. `_dm_constrain_nonlinear` goes away entirely.
3. *Legibility.* "Sample y from the fitted model" is textbook GLM synthesis. "Swap adjacent factor levels while preserving marginal counts" is a datamirror-specific heuristic that nobody else in the literature uses for this purpose.
4. *Smaller codebase.* The ~200-line paired-swap engine is deleted.

## Literature

The key references for direct DGP on binary outcomes (overlap with the nbreg decision doc; new ones specific to binary):

- **Franklin, J. M., Schneeweiss, S., Polinski, J. M., Rassen, J. A. (2014).** "Plasmode simulation for the evaluation of pharmacoepidemiologic methods in complex healthcare databases." *Computational Statistics & Data Analysis* 72: 219-226. https://pmc.ncbi.nlm.nih.gov/articles/PMC3935334/. Canonical plasmode paper; binary outcomes drawn as `y ~ Bernoulli(invlogit(Xβ))` with intercept tuned to set prevalence.
- **Schreck, N., Slynko, A., Saadati, M., Benner, A. (2024).** "Statistical plasmode simulations: potentials, challenges and recommendations." *Statistics in Medicine* 43(9). https://onlinelibrary.wiley.com/doi/full/10.1002/sim.10012. Current state-of-the-art review; endorses the Bernoulli-via-link-function construction.
- **Reiter, J. P. (2003, 2005).** Multiple foundational synthetic-data papers. Binary synthesis is a posterior-predictive Bernoulli draw from the fitted logistic regression.
- **Drechsler, J. (2011).** *Synthetic Datasets for Statistical Disclosure Control.* Springer. §4.4: Bernoulli sampling from a fitted logistic is the default for binary synthesis.
- **Nowok, B., Raab, G. M., Dibben, C. (2016).** "synthpop: Bespoke Creation of Synthetic Data in R." *Journal of Statistical Software* 74(11). `syn.logreg` does precisely the direct DGP construction.
- **Stadler, T., Oprisanu, B., Troncoso, C. (2022).** "Synthetic Data: Anonymisation Groundhog Day." *USENIX Security 2022.* Evaluates binary-classifier fidelity on synthetic data; parametric / copula methods (direct DGP family) outperform GANs on coefficient recovery.
- **Albert, A., Anderson, J. A. (1984).** "On the existence of maximum likelihood estimates in logistic regression models." *Biometrika* 71(1): 1-10. Classical reference on separation. Motivates the `p*` clip.
- **Heinze, G., Schemper, M. (2002).** "A solution to the problem of separation in logistic regression." *Statistics in Medicine* 21(16): 2409-2419. Firth penalisation for separated data; alternative to clipping if the MLE divergence is observed in practice.
- **Mansournia, M. A., Geroldinger, A., Greenland, S., Heinze, G. (2018).** "Separation in Logistic Regression: Causes, Consequences, and Control." *American Journal of Epidemiology* 187(4): 864-870. Useful overview if the clip safeguard proves insufficient.

The nbreg decision doc (`NBREG_DGP_DECISION.md`) carries the broader literature review on synthesis-for-coefficient-preservation across the GLM family. This document is the binary-specific addendum.

## Consequence for the codebase

After this change:

- `_dm_constrain_logit` and `_dm_constrain_probit` become direct-sampling bodies (same structure as `_dm_constrain_poisson`, which is the α=0 limit of `_dm_constrain_nbreg`).
- `_dm_constrain_nonlinear` loses its last callers and is removed.
- `_dm_constraints.ado` shrinks by ~200 lines.
- The logit / probit Test 2 factor carve-out ("continuous only because factors are not adjustable") is no longer needed. Tests assert on all coefficients; factors pass by construction.

## Alternative considered and rejected

- **Keep paired-swap for marginal-count preservation.** Rejected because datamirror's fidelity claim is about coefficient recovery, not marginal counts. If a future use case genuinely requires exact marginal counts (e.g., a user-facing `datamirror init, preserve_class_counts` option), it can be layered on top of direct DGP via a post-sampling flip-to-target-prevalence pass. Not needed for v1.0.
