# Supported Regression Models

Per-model documentation for datamirror's Layer 4 checkpoint-constraint engine.

---

## Strategy table

Every supported command is handled by one of two principled methods. No learning rates, no iteration knobs.

| Command                  | Family         | Method                                           | Fidelity target | Decision doc                                                        |
|--------------------------|----------------|--------------------------------------------------|-----------------|---------------------------------------------------------------------|
| `regress`                | linear         | Closed-form Newton via `matrix score`            | Δβ/SE < 3       | [LAYER4.md](LAYER4.md)                                              |
| `reghdfe`                | linear (FE)    | Closed-form Newton on FE-absorbed design         | Δβ/SE < 3       | [LAYER4.md](LAYER4.md)                                              |
| `ivregress 2sls`         | linear (IV)    | Weighted-FWL Newton on residualized design       | Δβ/SE < 3       | [IV_CONSTRAINT_DECISION.md](IV_CONSTRAINT_DECISION.md)              |
| `ivregress 2sls` (shared-outcome groups) | linear (IV) | Joint stacked min-norm Newton across all coefficient constraints | Δβ/SE < 3 | [IV_JOINT_CONSTRAINT_DECISION.md](IV_JOINT_CONSTRAINT_DECISION.md) |
| `logit`, `logistic`      | binary GLM     | Direct Bernoulli DGP at target `xβ*`             | Δβ/SE < 3       | [LOGIT_PROBIT_DGP_DECISION.md](LOGIT_PROBIT_DGP_DECISION.md)        |
| `probit`                 | binary GLM     | Direct Bernoulli DGP with probit link            | Δβ/SE < 3       | [LOGIT_PROBIT_DGP_DECISION.md](LOGIT_PROBIT_DGP_DECISION.md)        |
| `poisson`                | count GLM      | Direct Poisson DGP at target `exp(xβ*)`          | Δβ/SE < 3       | [NBREG_DGP_DECISION.md](NBREG_DGP_DECISION.md)                      |
| `nbreg`                  | count GLM      | Direct Gamma-Poisson DGP with α fixed at α_orig  | Δβ/SE < 3       | [NBREG_DGP_DECISION.md](NBREG_DGP_DECISION.md)                      |

Factor variables, interactions, analytic weights, and clustered standard errors are handled natively by all commands. See [FIDELITY_METRIC.md](FIDELITY_METRIC.md) for the 3-SE threshold rationale.

Per-model programs live in `stata/src/_dm_constraints.ado`. Shared utilities live in `stata/src/_dm_utils.ado`.

---

## Method family 1: closed-form Newton (linear models)

Linear estimators have the convenient property that β̂ is a linear functional of y. That means we can compute the exact shift to y that moves β̂ to any target β* in one step:

```
β̂_new = (X'X)^(-1) X' (y + X·Δβ) = β̂ + Δβ
```

Exact up to floating-point precision. Stata's `matrix score` gives us this with one call, and the implementation is short enough to fit on a screen.

### `regress` (OLS)

```stata
regress outcome predictor1 predictor2 i.factor_var
```

Implementation: Stata's `matrix score` applied to a coefficient-difference vector with colnames matching `e(b)`. Factor variables, interactions, and base levels are handled by the `matrix score` machinery; no hand-rolled regex parser is needed.

### `reghdfe` (fixed effects)

```stata
reghdfe outcome predictor1 predictor2, absorb(id year)
```

Same formula as OLS, applied to `e(b)` which excludes absorbed effects. Singleton observations dropped by reghdfe are preserved unchanged in the output dataset. Intercept recovery in FE models is arbitrary (post-demeaning grand mean) and is not targeted.

### `ivregress 2sls` (single checkpoint)

```stata
ivregress 2sls outcome (endogenous = instrument) exogenous
```

The 2SLS coefficient on endogenous `X_1` under weights `Ω` and controls `W` is:

```
β̂_1 = (Z̃' Ω X̃_1)^(-1) (Z̃' Ω y_tilde)
```

where tildes denote Frisch-Waugh-Lovell residualization against `W`. The Newton step that moves β̂_1 by Δβ is:

```
delta_y = X̃_1 · (π̂ · Δβ)
```

where `π̂` is the weighted first-stage slope. First-stage F is reported as a diagnostic (warning if F < 10).

### `ivregress 2sls` joint (shared-outcome groups)

When multiple `ivregress` specifications share the same outcome (e.g., Autor 2019's `iv_mainshock` and `iv_gendershock` both regressing on `d_<y>`), applying the single-checkpoint Newton sequentially produces POCS-style slow convergence. The joint adjuster stacks all coefficient constraints into one linear system and solves once:

```
delta_y = Ω^(-1) A_stack' (A_stack Ω^(-1) A_stack')^(-1) Δβ_stack
```

Every coefficient across the group is pinned simultaneously. Over-identified specs (`m > k` instruments per endogenous block) fall back to single-checkpoint cyclic.

---

## Method family 2: direct DGP sampling (generalized linear models)

For GLMs the shift-based Newton step does not apply cleanly: the link function makes β a nonlinear functional of y, and attempts at iterative adjustment run into the structural issues documented in the decision files below. So we take a different path: given target `β*` (and `α*` for nbreg), build the linear predictor `xβ*` on the synthetic X, and draw `y` fresh from the model's canonical DGP.

| Model      | DGP                                                  |
|------------|------------------------------------------------------|
| `logit`    | `p* = invlogit(xβ*); y ~ Bernoulli(p*)`              |
| `probit`   | `p* = normal(xβ*);   y ~ Bernoulli(p*)`              |
| `poisson`  | `y ~ Poisson(exp(xβ*))`                              |
| `nbreg`    | `λ ~ Gamma(1/α*, α*·exp(xβ*)); y ~ Poisson(λ)`       |

Fitting the matching model on this `y` recovers `β*` within `O(1/√N)` sampling noise by construction. Factor-level coefficients are preserved because the DGP is applied at the observation level.

### `logit` / `logistic` / `probit`

Separation safeguard: `p*` is clipped to `(1e-4, 1 − 1e-4)` before the Bernoulli draw so downstream refits do not hit the Albert-Anderson (1984) MLE non-existence boundary on rare-event strata.

### `poisson`

Special case of the negative-binomial DGP with `α = 0` (no overdispersion).

### `nbreg`

`α*` is read from the `alpha` column in `checkpoints.csv` (recorded at extract time). `α` is held fixed because the NB2 score equation is non-orthogonal in `(β, α)` (Lawless 1987, Kenne Pagui et al. 2022); freely refitting would drift. Marginally, `y_i | X_i ~ NB2(μ*_i, α*)`.

---

## Known limitations

- **Nested-regressor shared-outcome OLS**: multiple `regress` specifications sharing an outcome with nested regressor sets converge slowly under cyclic Newton. Joint OLS is a direction for future work via an accelerated-projection approach.
- **Rare binaries**: Gaussian copula correlations are not well preserved for binary variables with prevalence below ~0.1. Coefficient estimates for regressions involving such variables may have elevated Δβ/SE. A warning is emitted at extract time when detected.
- **Unsupported commands**: `ologit`, `oprobit`, `mlogit`, `stcox`, `tobit`, `ivpoisson`, `ivregress liml`, `ivregress gmm` with non-default weight matrix. Attempting `datamirror checkpoint` after these commands produces a clean "not supported in v1.0" error.
- **Outcome marginal distribution**: for the GLM family, `y` is resampled from the model's DGP, so the sample proportion or mean may differ from the observed `y` by `O(1/√N)`. This is by design.

---

## References

- **Closed-form Newton for OLS/FE/IV**: Frisch & Waugh (1933), Lovell (1963), Angrist & Pischke (2009) ch. 4. See [IV_CONSTRAINT_DECISION.md](IV_CONSTRAINT_DECISION.md) for the IV derivation.
- **Joint IV Newton**: Zellner & Theil (1962), Hansen (1982), Newey & McFadden (1994). See [IV_JOINT_CONSTRAINT_DECISION.md](IV_JOINT_CONSTRAINT_DECISION.md).
- **NB2 DGP rationale**: Lawless (1987), Lloyd-Smith (2007), Kenne Pagui, Salvan & Sartori (2022). See [NBREG_DGP_DECISION.md](NBREG_DGP_DECISION.md).
- **Binary-outcome DGP rationale**: Albert & Anderson (1984) on MLE separation; plasmode and MI-synthesis literature on Bernoulli sampling. See [LOGIT_PROBIT_DGP_DECISION.md](LOGIT_PROBIT_DGP_DECISION.md).
- **Fidelity metric**: [FIDELITY_METRIC.md](FIDELITY_METRIC.md).
- **Weak-instrument diagnostics**: Stock & Yogo (2005).

---

## Where to go next

| Your goal                                           | Read this                                                                             |
|-----------------------------------------------------|---------------------------------------------------------------------------------------|
| "What is datamirror?"                               | [README.md](../README.md)                                                             |
| "How do I use datamirror?"                          | [USAGE.md](USAGE.md)                                                                  |
| "How is Layer 4 structured?"                        | [LAYER4.md](LAYER4.md)                                                                |
| "Why DGP sampling for nbreg?"                       | [NBREG_DGP_DECISION.md](NBREG_DGP_DECISION.md)                                        |
| "Why DGP sampling for logit / probit?"              | [LOGIT_PROBIT_DGP_DECISION.md](LOGIT_PROBIT_DGP_DECISION.md)                          |
| "Why Newton step for IV?"                           | [IV_CONSTRAINT_DECISION.md](IV_CONSTRAINT_DECISION.md)                                |
| "Why joint Newton for shared-outcome IV?"           | [IV_JOINT_CONSTRAINT_DECISION.md](IV_JOINT_CONSTRAINT_DECISION.md)                    |
| "What's the Δβ/SE threshold?"                       | [FIDELITY_METRIC.md](FIDELITY_METRIC.md)                                              |
| "What privacy does datamirror claim?"               | [PRIVACY.md](PRIVACY.md)                                                              |
| "Where's the evidence from real replications?"      | [../replication/RESULTS.md](../replication/RESULTS.md)                                |
