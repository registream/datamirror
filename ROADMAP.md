# DataMirror Roadmap

What is shipped in v1.0 and what remains.

---

## Shipped in v1.0

Layer 4 implements two principled families, each applicable to the model class where its mathematics is exact. All 12 unit tests pass at `Δβ/SE < 3`; four AEA replication packages pass the same bar on 390+ coefficient comparisons.

| Command          | Family     | Method                                      | Unit test               | Δβ/SE |
|------------------|------------|---------------------------------------------|-------------------------|-------|
| `regress`        | linear     | Closed-form Newton via `matrix score`       | `test_ols_basic.do`     | < 3   |
| `reghdfe`        | linear     | Closed-form Newton (FE-absorbed design)     | `test_reghdfe_basic.do` | < 3   |
| `ivregress 2sls` | linear     | Weighted-FWL Newton on residualized design  | `test_iv_basic.do`      | < 3   |
| `ivregress 2sls` (shared-outcome groups) | linear | Joint stacked min-norm Newton | (Autor replication)     | < 3   |
| `logit`          | binary     | Direct Bernoulli DGP                        | `test_logit_basic.do`   | < 3   |
| `probit`         | binary     | Direct Bernoulli DGP                        | `test_probit_basic.do`  | < 3   |
| `poisson`        | count      | Direct Poisson DGP                          | `test_poisson_basic.do` | < 3   |
| `nbreg`          | count      | Direct Gamma-Poisson DGP (α fixed)          | `test_nbreg_basic.do`   | < 3   |

Plus orchestration for shared predictors across multiple checkpoints (`test_multiple_checkpoints.do`) and integer-support preservation for discrete numeric variables (`test_discrete_numeric.do`).

Fidelity metric: `Δβ/SE` (see [docs/FIDELITY_METRIC.md](docs/FIDELITY_METRIC.md) for the 3-SE threshold rationale). Point-estimate Δβ thresholds are no longer used. Full release notes in [CHANGELOG.md](CHANGELOG.md); architecture in [docs/LAYER4.md](docs/LAYER4.md).

---

## Tier 1: next for v1.1

| Item                           | Rationale                                     | Approach                                                  |
|--------------------------------|-----------------------------------------------|-----------------------------------------------------------|
| Joint OLS (shared-outcome)     | Cycle-POCS is slow on nested-regressor specs  | Accelerated projection (Dykstra) on the stacked system    |
| Rare-binary copula improvement | Banerjee T1A balance-table misses at ≤0.3 SE  | Conditional binary sampling from probit on continuous slice |
| `xtreg, fe`                    | Panel fixed effects                           | Within-transform + closed-form Newton                      |
| `xtreg, re`                    | Panel random effects                          | Random-effects projection                                  |
| `ivreghdfe`                    | IV plus absorbed FE                           | Closed-form Newton on partialled-out sample                |
| Cross-model shared-outcome     | IV and OLS touching same y                    | Joint stacked system across model families                 |
| Harmonize replication compare-script metrics | Duflo T3 / T7-10 and Dupas T1 report "FAIL" under legacy `Δβ < 0.05` or `Δβ/SE < 1` thresholds even though every coefficient passes the canonical `Δβ/SE < 3` bar | Rewrite each compare script to report `Δβ/SE` against the canonical v1.0 threshold; keep per-coefficient tables but update the pass-fail verdict |

The v1.1 items close the remaining gaps that surfaced during the four-paper replication validation. Auto-checkpoint via the `datamirror auto` prefix shipped in v1.0.

---

## Tier 2: after v1.1

| Command    | Rationale                  | Approach                               |
|------------|----------------------------|----------------------------------------|
| `ologit`   | Ordered outcomes           | Proportional-odds DGP                  |
| `oprobit`  | Ordered outcomes           | Ordered-normal DGP                     |
| `mlogit`   | Multinomial outcomes       | Multinomial-logit DGP                  |
| `stcox`    | Survival analysis (Cox PH) | Exponential-baseline DGP or plasmode   |
| `tobit`    | Censored outcomes          | Truncated-normal DGP                   |

All four nonlinear candidates will follow the same direct-DGP pattern as logit/probit/poisson/nbreg (sample y from the model's canonical data-generating process at target β*).

---

## Tier 3: long horizon

- **Backward-inference engine** (v2 methodology, target venue Journal of Econometrics). Reconstructs master-file structure and derived variables from checkpoint constraints alone. Design proposal is tracked in the RegiStream research notes (separate repo).
- **Panel-within-stratified synthesis**. Current stratified synthesis preserves within-strata properties but assumes cross-sectional independence; true panel support requires unit-level copula plus temporal structure.
- **Python port**. Mirror the Stata module via pandas accessors plus a backend that implements the four layers.
- **R port**. Mirror via a haven-based pipeline.
- **Non-Gaussian copulas**. Gumbel or t-copulas for applications where joint tail dependence matters (survival, extreme values).

---

## What datamirror does not attempt

- **Differential privacy.** Datamirror is a statistical-disclosure-control tool with a parametric, auditable footprint (Figure 1b in Ricciato 2026). It does not offer formal differential-privacy guarantees. If DP is required, compose with a DP mechanism on top of the extract-layer summaries.
- **Deep-learning synthesis.** VAE or GAN synthetic data is explicitly out of scope. Datamirror is a parametric, auditable copula approach; if a project requires deep generative models, compose them on top of Layer 1-3.
- **Outcome-marginal preservation as a primary fidelity claim.** Datamirror preserves coefficients. Outcome summary-statistics tables computed on synthetic y should carry a caveat; see [docs/PRIVACY.md](docs/PRIVACY.md) and [docs/LAYER4.md](docs/LAYER4.md).

---

## How decisions get made

When a new model is proposed for Layer 4, a brief decision doc is written (mirror the format of [docs/NBREG_DGP_DECISION.md](docs/NBREG_DGP_DECISION.md) or [docs/LOGIT_PROBIT_DGP_DECISION.md](docs/LOGIT_PROBIT_DGP_DECISION.md)) before code lands. This keeps the methodological record durable and reviewer-checkable.
