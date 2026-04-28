# NBREG: Direct DGP Sampling Decision

**Date:** 2026-04-21
**Author:** Jeffrey Clark
**Context:** Layer 4 coefficient adjustment for negative binomial regression (`nbreg`)
**Decision:** Replace the iterative gradient-descent adjuster with direct data-generating-process sampling (Gamma-Poisson mixture at target parameters).

---

## What the old approach was

`_dm_constrain_nbreg` called `_dm_constrain_nonlinear` with `model_type="nbreg"`. The nonlinear engine ran an iterative loop:

1. Fit `nbreg y on X` (with `constraints(1): [lnalpha]_cons = ln(α_orig)`) to pin α.
2. Compute residual gradient `(y - μ) / (1 + α·μ)`.
3. Shift y (or in later versions, shift x) by `λ · Δβ · gradient` where Δβ = target − fitted.
4. Clip y ≥ 0 so `nbreg` wouldn't error with `r(459)`.
5. Repeat until convergence or max iterations.

## What actually happened

On the synthetic unit test (`rnbinomial(mu, 0.5)`, so α ≈ 0.5):

- **With α constraint pinned:** Δβ freezes at 1.16 for ~130 iterations, then slowly grows to 1.4. β never reaches target.
- **Without α constraint:** Stata's ML diverges catastrophically (Δβ: 1.6 → 32 by iteration 10, followed by `r(430) convergence not achieved`).
- **Additive y-shift + clip at 0:** works for Poisson (α=0) but the clip distorts the distribution enough to break nbreg's constrained ML when α is appreciable.
- **Multiplicative y-shift `exp(λ · Δβ · (x − x̄))`:** compounds too aggressively, Δβ blows up to ~20 by iteration 10.
- **Scaled learning rate (0.25×):** makes β more stuck, not less.

No first-order heuristic on y (or x) converged for nbreg with α ≈ 0.5.

## Why iterative MLE-based adjustment is structurally wrong for nbreg

The NB2 log-likelihood score for β at fixed α is:

```
∂L/∂β_j = Σ_i x_ij · (y_i − μ_i) / (1 + α·μ_i)
```

Two structural facts make iterative y-shift fail:

1. **β̂ and α̂ are not orthogonal in finite samples** (Lawless 1987; Kenne Pagui, Salvan, Sartori 2022). Pinning α forces β to sit on a non-optimal ridge of the likelihood, which the constrained MLE will return regardless of y. Δβ freezes.
2. **MLE non-existence near boundary.** Lloyd-Smith (2007) shows the NB2 MLE fails to exist when the sample variance approaches the sample mean. Clipping y ≥ 0 or multiplicatively scaling y drives the data toward that boundary, producing `r(430)`.

This is not a tuning issue. It is the geometry of the NB2 likelihood on perturbed data. Any iterative approach that calls `nbreg` on iteratively-shifted y will hit one of these two walls.

## Why direct DGP sampling is correct

The NB2 model's data-generating process is the Gamma-Poisson mixture:

```
μ*_i = exp(X_i · β*)                  (target linear predictor)
λ_i  ~ Gamma(1/α*, α* · μ*_i)         (rate heterogeneity; mean μ*_i, var α*·μ*²_i)
y_i  ~ Poisson(λ_i)                   (conditional count)
```

Marginally, `y_i | X_i ~ NB2(μ*_i, α*)` with mean `μ*_i` and variance `μ*_i + α*·μ*²_i`.

**By construction**, fitting `nbreg y on X` on data generated this way recovers β* within sampling error of order `O(1/√N)`. No iteration, no MLE surgery, no clip boundary. The estimator does what it was designed to do, because the data comes from the model.

This is textbook NB2. Our Poisson path (which passes) essentially already does this when α=0, since the Gamma collapses to a constant and Poisson sampling is all that's left.

## What this means for architecture

Layer 4 for nbreg becomes one-shot replacement rather than iterative refinement. Specifically:

- **Layer 1-3** (marginals, copula, stratification) produce synthetic X and a placeholder y.
- **Layer 4 for nbreg** discards the placeholder y and samples a fresh y from NB2(X·β*, α*).
- The single-checkpoint case (what the unit test exercises) is clean.
- The multi-checkpoint case (e.g., one nbreg checkpoint plus one OLS checkpoint sharing predictors) becomes order-dependent. For v1.0 we document that nbreg should be the final checkpoint applied when mixed with others. Multi-checkpoint nbreg reconciliation is deferred.

## Literature

Primary sources for the decision:

**On why iterative MLE fails for nbreg with shifted y:**

- **Lawless, J. F. (1987).** "Negative binomial and mixed Poisson regression." *Canadian Journal of Statistics* 15(3): 209-225. Classical reference for NB2 score, information matrix, and the non-orthogonality of β̂ and α̂.
- **Kenne Pagui, E. C., Salvan, A., & Sartori, N. (2022).** "Improved estimation in negative binomial regression." *Statistics in Medicine* 41(13): 2410-2427. https://pmc.ncbi.nlm.nih.gov/articles/PMC9314673/. Mean and median bias correction for nbreg, documents score coupling.
- **Lloyd-Smith, J. O. (2007).** "Maximum likelihood estimation of the negative binomial dispersion parameter for highly overdispersed data, with applications to infectious diseases." *PLOS ONE* 2(2): e180. Non-existence of MLE near Poisson boundary.

**On what the correct synthesis approach is (and what the state of the art covers):**

- **Franklin, J. M., Schneeweiss, S., Polinski, J. M., & Rassen, J. A. (2014).** "Plasmode simulation for the evaluation of pharmacoepidemiologic methods." *Computational Statistics & Data Analysis* 72: 219-226. https://pmc.ncbi.nlm.nih.gov/articles/PMC3935334/. Plasmode paradigm; does not cover nbreg.
- **Schreck, N., et al. (2024).** "Statistical plasmode simulations: potentials, challenges and recommendations." *Statistics in Medicine*. https://onlinelibrary.wiley.com/doi/full/10.1002/sim.10012. Current reference on plasmode; warns that plasmode does not guarantee target coefficient recovery.
- **Nowok, B., Raab, G. M., & Dibben, C. (2016).** "synthpop: Bespoke Creation of Synthetic Data in R." *Journal of Statistical Software* 74(11). Default count treatment is CART; no nbreg special-casing; fidelity is checked post hoc via `compare.fit.synds`.
- **Raab, G. M., Nowok, B., & Dibben, C. (2022).** "Saturated count models for Simulating Synthetic data." *JRSS-A* 185(4): 1613-1640. Uses saturated Poisson log-linear on the multiway table; does not extend to NB2.
- **Kleinke, K., & Reinecke, J.** `countimp` package for multiple imputation of count outcomes. Documents nbreg MCMC convergence failures when observed dispersion drifts from the prior: same pathology we hit.
- **Reiter, J. P. (2005, 2009); Drechsler, J. (2011).** *Synthetic Datasets for Statistical Disclosure Control.* MI-based synthesis samples y from posterior predictive of the fitted model; coefficients preserved in expectation under combining rules, never pinned exactly.

**On direct NB2 DGP sampling (the method we adopt):**

- **McCullagh, P., & Nelder, J. A. (1989).** *Generalized Linear Models.* 2nd ed. Chapman & Hall. §6.2.3 NB2 as Gamma-Poisson mixture.
- **Cameron, A. C., & Trivedi, P. K. (2013).** *Regression Analysis of Count Data.* 2nd ed. Cambridge University Press. Ch. 3.3, NB2 DGP specification; §2.6, sampling from NB2.
- **Stata `rgamma()` and `rpoisson()` documentation.** Standard Stata functions for the mixture draw.

**On the general inference problem with synthetic data:**

- **Wang, Y., et al. (2025).** "GLM Inference with AI-Generated Synthetic Data Using Misspecified Linear Regression." arXiv:2503.21968. Shows the GLM estimator on synthetic data converges slower than √n without correction; recovers √n rate by supplying `X'X` and a misspecified-OLS debiasing step. Directly relevant: naive synthesis under-preserves GLM coefficients even asymptotically.
- **Gaffke, N., Keith, T., & Mokhlesian, M. (2016).** "A moment matching approach for generating synthetic data." *Big Data* 4(3). Moment-matching framework; the alternative path we did not take (score-equation construction via pseudoinverse).

## Alternative paths considered and rejected

1. **Score-equation construction.** Solve `Σ x_ij(y_i − μ*_i)/(1+αμ*_i) = 0` directly as an underdetermined linear system in residuals. Pseudoinverse solution, stochastic rounding. Exact at float precision. Rejected because Gamma-Poisson sampling is simpler, more interpretable, and has the right statistical guarantees without custom numerical linear algebra.
2. **Copula-side encoding.** Modify Layer 2 (coefficient-aware copula) to target β* in the joint before sampling. Rejected because the copula stage is already pre-sampling and touching it for nbreg specifically would create cross-layer coupling that other models do not need.
3. **Adjusted profile likelihood (Cox-Reid / McCarthy 2012).** Use APL with α profiled out, via custom `ml model` evaluator. Rejected because it still requires iterative optimisation and the Gamma-Poisson path gives the right answer in one shot.
4. **Keep iterative adjustment, soften README.** Document `nbreg Δβ < 0.05` as `best-effort when α < 0.15`. Rejected because the user (Jeffrey, 2026-04-21) explicitly required 9/9 unit tests passing, not a softened claim.

## Implementation location

`stata/src/_dm_constraints.ado` → `_dm_constrain_nbreg`. Replaces the thin wrapper that called `_dm_constrain_nonlinear` with a direct sampler that uses Stata's `rgamma()` and `rpoisson()`. Factor variables are decoded from the coefficient-column names via regex (same pattern as the existing factor-swap code) so that `μ*_i = exp(X_i · β*)` correctly accumulates level-indicator contributions.

The `model_type = nbreg` branch in `_dm_constrain_nonlinear` is removed; nbreg no longer enters that engine.

## Lesson for the project

The README claim `Δβ < 0.05 for nbreg (continuous predictors) ✓` was aspirational. The unit test (`test_nbreg_basic.do`) has existed since initial commit and has always failed on its first and third subtests with α=0.5, but the harness could not run end-to-end (cite placeholder + command_line quoting bugs) so the failure was invisible. Once the harness was unblocked (2026-04-21), the gap surfaced immediately.

Going forward: do not ship a `✓` next to a claim until a test runs end-to-end and passes at the documented tolerance. This is saved as a feedback memory.
