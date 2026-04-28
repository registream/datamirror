# Layer 4: Checkpoint Constraints

This is the heart of datamirror. Layers 1 through 3 (marginals, Gaussian copula, stratification) preserve distributional structure. Layer 4 ensures that regressions you tag as important reproduce their coefficient estimates on the synthetic data.

---

## What Layer 4 does

Given a synthetic dataset with synthetic X (built by Layers 1-3) and a set of checkpointed regressions (each a command, a target coefficient vector β*, and for nbreg a target dispersion α*), Layer 4 adjusts the synthetic y so that re-running each checkpoint's command on the synthetic data recovers β* within sampling noise.

The fidelity metric is `Δβ/SE`, the distance between synthetic β̂ and target β* measured in units of the synthetic fit's own standard error. See [FIDELITY_METRIC.md](FIDELITY_METRIC.md) for the full rationale and threshold discussion.

---

## Two families, two methods

Layer 4 splits the work by outcome type. Linear models get a closed-form Newton step on y. Generalized linear models (logit, probit, poisson, nbreg) get direct sampling from their data-generating process. In the linear path there are no learning rates and nothing iterative; in the GLM path there is nothing iterative either, and the output y is drawn once.

### Linear-outcome family (OLS, reghdfe, IV)

For any regression `y = X β̂ + e` where β̂ is a linear functional of y, shifting y by `X (β* − β̂)` updates β̂ by exactly `β* − β̂`:

```
β̂_new = (X' X)^(-1) X' (y + X Δβ) = β̂ + Δβ
```

That's the whole step. One `matrix score` call produces the shift vector from the target coefficients, one `replace` applies it. No iteration; no learning-rate to tune.

| Estimator  | Implementation                                                                       |
|------------|--------------------------------------------------------------------------------------|
| OLS        | `matrix score dy = Δβ_named` on the `regress` design matrix (factor-variable safe)   |
| reghdfe    | Same; reghdfe's `e(b)` excludes absorbed effects, which is what we want              |
| IV (2SLS)  | Weighted-FWL Newton on residualized design: `delta_y = X̃ · (π̂ · Δβ)` with `Z̃ = M_W Z` under weights; condition-number and first-stage-F diagnostics logged |
| Joint IV   | Shared-outcome groups (e.g., Autor 2019's main-shock and gender-shock specs on the same `d_<y>`): stacked min-norm Newton across all coefficient constraints |

Full derivations: [IV_CONSTRAINT_DECISION.md](IV_CONSTRAINT_DECISION.md), [IV_JOINT_CONSTRAINT_DECISION.md](IV_JOINT_CONSTRAINT_DECISION.md). Implementation: `_dm_constrain_ols`, `_dm_constrain_fe`, `_dm_constrain_iv`, `_dm_constrain_iv_joint` in `stata/src/_dm_constraints.ado`.

### Generalized-linear-model family (logit, probit, poisson, nbreg)

For GLMs we don't try to match coefficients by perturbing an existing y. Instead we build the linear predictor `xβ*` at the target coefficients, and sample a fresh y from the canonical data-generating process of the model:

| Model   | DGP                                                  |
|---------|------------------------------------------------------|
| logit   | `p* = invlogit(xβ*); y ~ Bernoulli(p*)`              |
| probit  | `p* = normal(xβ*);   y ~ Bernoulli(p*)`              |
| poisson | `y ~ Poisson(exp(xβ*))`                              |
| nbreg   | `λ ~ Gamma(1/α*, α*·exp(xβ*)); y ~ Poisson(λ)`       |

Fitting the matching GLM on the resulting y recovers β* up to the usual `O(1/√N)` sampling noise. Factor-level coefficients come out correct automatically, because the DGP runs observation by observation rather than adjusting any one parameter at a time.

We tried the iterative-adjustment approach first; it does not work well for these models. The nbreg score equations in `(β, α)` are not orthogonal in finite samples (Lawless 1987; Kenne Pagui et al. 2022), so holding α fixed pushes β off the optimum, and letting α float lets α absorb misspecification. The binary-outcome version of the iterative approach becomes an integer-programming problem (observations moving between factor levels under a marginal-count constraint) that heuristics only approximately solve. Direct sampling sidesteps both. See [NBREG_DGP_DECISION.md](NBREG_DGP_DECISION.md) and [LOGIT_PROBIT_DGP_DECISION.md](LOGIT_PROBIT_DGP_DECISION.md) for the full argument.

One safeguard on the binary draw: `p*` is clipped to `(1e-4, 1 − 1e-4)` before sampling. This prevents downstream logit/probit refits from running into the Albert-Anderson (1984) separation boundary on rare-event strata.

Implementation: `_dm_constrain_logit`, `_dm_constrain_probit`, `_dm_constrain_binary_dgp`, `_dm_constrain_poisson`, `_dm_constrain_nbreg` in `stata/src/_dm_constraints.ado`.

---

## Orchestration

`_dm_apply_checkpoint_constraints` is the dispatcher that drives Layer 4 during rebuild:

1. Read `outbox/checkpoints.csv` to enumerate the checkpoints.
2. Load `outbox/checkpoints_coef.csv` once (long format, one row per coefficient with `cp_num` foreign key). Per-checkpoint filter by `cp_num` yields target β* (and α* for nbreg).
3. Before the per-checkpoint loop, scan for `ivregress` checkpoints sharing a `depvar`. Groups of two or more route to the joint IV adjuster; singletons route to the single-checkpoint IV path.
4. Remaining checkpoints dispatch to their per-model adjuster based on the `cmd` field.
5. Each adjuster reads β* from matrices, not from session globals. `datamirror rebuild using "outbox"` works from a fresh Stata session.

The three-pass outer loop over all checkpoints is retained for the case where a single `y` is touched by both a linear and a nonlinear adjuster. In the pure IV-only or pure-OLS-only regime, one pass suffices because each adjuster converges in a single Newton step.

---

## Factor variables

Handled uniformly by `matrix score` in the linear family: it walks the design matrix encoded in `e(b)` column names (including `i.var` expansion, base-level skipping, and `i.x#c.y` interactions) and writes the correct contribution to the update vector. The earlier hand-rolled regex parser for factor-variable notation is gone.

The GLM family handles factor effects the same way: when building `xβ*` the target coefficient for each level becomes an indicator contribution `β_level · 1[var == level]`. The canonical DGP draws then capture the factor effect in y.

---

## Multi-checkpoint shared predictors and shared outcomes

**Shared predictors across checkpoints:** the three-pass outer loop lets adjustments from one checkpoint be re-applied by the next. The unit test `test_multiple_checkpoints.do` verifies that shared-predictor configurations converge.

**Shared outcomes across IV checkpoints:** handled by the joint IV adjuster at group level. A single stacked Newton step pins all coefficient constraints simultaneously, which is strictly more efficient than cyclic projection and avoids the range-inconsistent pathologies that would require accelerated POCS. See [IV_JOINT_CONSTRAINT_DECISION.md](IV_JOINT_CONSTRAINT_DECISION.md).

**Shared outcomes across OLS checkpoints:** not handled in v1.0. Empirical investigation (Dupas 2013 T5, Duflo 2012 T9) found that nested-regressor OLS specs produce rank-deficient joint Grams where the stacked Newton step does not apply. The pragmatic v1.0 path is cyclic single-checkpoint Newton, which converges on the empirical cases tested.

**Shared outcomes across model families (IV + OLS on same y):** not yet pressured by an empirical case; a direction for future work alongside the OLS-joint extension.

---

## What Layer 4 does not preserve

- **Outcome marginal distribution exactly.** For the GLM family, y is resampled from the model's DGP, so the sample proportion or mean may differ from the observed y by `O(1/√N)`. For the linear family, y is shifted by the Newton vector. This is by design: datamirror's fidelity claim is about coefficient recovery, not marginal y preservation. Summary-statistics tables computed on synthetic y should carry a caveat (see [PRIVACY.md](PRIVACY.md)).
- **Individual-observation-level labels.** For the GLM family, y is replaced entirely. Individual y values in the synthetic data do not correspond to any specific observation in the original. This is a privacy property, not a loss.
- **Joint tail dependence beyond the Gaussian copula.** Layer 2's copula captures linear dependence; extreme-value co-movement in the tails is not preserved.

---

## Code layout

- `stata/src/_dm_constraints.ado`: per-model adjusters, `_dm_apply_checkpoint_constraints` dispatcher, and `_dm_constrain_correlations` (pre-sampling correlation adjustment used by Layer 2).
- `stata/src/_dm_utils.ado`: session lifecycle (init, checkpoint, close), extract phase, rebuild orchestration, check (validation), file I/O helpers.
- `stata/src/datamirror.ado`: public command dispatcher (`datamirror init / checkpoint / extract / rebuild / check / close / version / cite`).

---

## Test status

The unit suite (`stata/tests/dofiles/unit/`) exercises Layer 4 for all nine supported scenarios:

- OLS (`test_ols_basic.do`)
- reghdfe (`test_reghdfe_basic.do`)
- IV (`test_iv_basic.do`)
- Logit (`test_logit_basic.do`)
- Probit (`test_probit_basic.do`)
- Poisson (`test_poisson_basic.do`)
- Nbreg (`test_nbreg_basic.do`)
- Multi-checkpoint shared predictors (`test_multiple_checkpoints.do`)
- Discrete numeric variable handling (`test_discrete_numeric.do`)

All twelve assert `max(Δβ/SE) < 3` per subtest. At HEAD all twelve pass. Beyond unit tests, four AEA replication packages pass the same bar on 349 of 353 coefficient comparisons (Duflo-Hanna-Ryan 2012, Dupas-Robinson 2013, Banerjee et al. 2015, Autor-Dorn-Hanson 2019); see [replication/RESULTS.md](../replication/RESULTS.md) for the breakdown.

---

## Further reading

- [IV_CONSTRAINT_DECISION.md](IV_CONSTRAINT_DECISION.md): closed-form Newton step for single-checkpoint 2SLS with FWL residualization and analytic weights.
- [IV_JOINT_CONSTRAINT_DECISION.md](IV_JOINT_CONSTRAINT_DECISION.md): joint Newton step for shared-outcome IV groups.
- [NBREG_DGP_DECISION.md](NBREG_DGP_DECISION.md): why iterative MLE-based adjustment fails for nbreg.
- [LOGIT_PROBIT_DGP_DECISION.md](LOGIT_PROBIT_DGP_DECISION.md): sibling decision for binary models.
- [FIDELITY_METRIC.md](FIDELITY_METRIC.md): the Δβ/SE metric and the 3-SE threshold.
- [SUPPORTED_MODELS.md](SUPPORTED_MODELS.md): per-model usage and performance notes.
