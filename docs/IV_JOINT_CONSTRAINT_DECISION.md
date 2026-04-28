# Joint-Checkpoint IV Adjuster Decision

**Date:** 2026-04-21
**Author:** Jeffrey Clark
**Context:** Layer 4 coefficient adjustment when multiple IV (2SLS) checkpoints share the same outcome `y` but use different endogenous / instrument pairs. This is the follow-on to `IV_CONSTRAINT_DECISION.md`: the single-checkpoint Newton step corrected the 1x1 mis-scaling; this document addresses the interference that remains when two or more such Newton steps are applied sequentially on the same outcome variable.
**Decision:** Replace the per-checkpoint cyclic projection with a stacked min-norm joint Newton step computed once per global pass. Preserve the cyclic (POCS-style) path as a fallback for numerically ill-conditioned stacks and for the heterogeneous-sample case where the stack cannot be formed cleanly. Degrade to single-checkpoint Newton on the well-conditioned subset when the joint Jacobian fails the rank test.

This document is the sequel to `IV_CONSTRAINT_DECISION.md`. The prior doc showed that one-shot Newton on a single 2SLS checkpoint is exact up to `O(1/N)`; this one shows that the exactness does not compose under cyclic enforcement when two checkpoints write to the same `y`, derives the correct joint step, and surveys the relevant literature (constrained least squares, alternating projections, seemingly-unrelated moment systems).

---

## 1. Problem statement

Datamirror's dispatcher in `stata/src/_dm_constraints.ado` (lines 395 to 472) iterates over checkpoints inside a global pass and calls the per-model adjuster (OLS, FE, IV, logit, probit, poisson, nbreg) for each. Three global passes are run. This is a cyclic projection algorithm: each checkpoint pushes `y` onto the manifold `{ y : beta_hat_k(y) = beta*_k }` and the next checkpoint pushes onto its own manifold.

When two IV checkpoints share the outcome `y` but differ in their endogenous block, the manifolds are distinct linear subspaces of the ambient `y`-space. Cyclic projection onto distinct subspaces converges geometrically to the intersection (if non-empty) at a rate governed by the Friedrichs angle between the subspaces (Deutsch 1992, Bauschke and Borwein 1996). The Newton step from the prior doc is projection onto a single such subspace with projection error `O(1/N)`. Across three global passes, the observed residual on the "first-applied" checkpoint is the residual of three iterations of a two-subspace cyclic projection, which for strongly overlapping subspaces decays slowly enough that the final `Delta_beta / SE` on the detuned checkpoint exceeds the tolerance.

### Concrete empirical observation: Autor, Dorn, Hanson (2019)

The `replication/003_autor_dorn_hanson_2019` harness pairs two 2SLS specs per outcome `d_<y>`:

**Main** (k = m = 1 just-identified):
```
ivregress 2sls d_<y> (d_impusch_p9 = d_impotch_p9_lag) race_controls cs_controls [aw=timepwt24], cluster(statefip)
```

**Gender** (k = m = 2 just-identified):
```
ivregress 2sls d_<y> (d_impuschm_p9cen d_impuschf_p9cen = d_impotchm_p9cen_lag d_impotchf_p9cen_lag) race_controls cs_controls [aw=timepwt24], cluster(statefip)
```

Both write to the same checkpoint store with a shared `d_<y>`. The dispatcher enforces them in the order they appear in `checkpoints.csv` (main first, gender second). With the single-checkpoint Newton step from `IV_CONSTRAINT_DECISION.md`:

- Main's Newton step pins `beta_main` to `beta*_main` up to `O(1/N)`; it changes `y` along the direction `pi_main * Z_tilde_main`.
- Gender's Newton step then pins `beta_gender` to `beta*_gender`; it changes `y` along the direction `pi_gender * Z_tilde_gender` (a 2-dim subspace), which has non-zero projection onto `pi_main * Z_tilde_main`.
- After gender runs, `beta_main` has drifted off its target by the projection of the gender update onto the main Jacobian.
- Three global passes reduce the drift by roughly `cos^2(theta)^3` where `theta` is the Friedrichs angle; when the two instrument sets are strongly related (they both derive from the same China-trade shock), `cos(theta)` is close to 1 and the drift persists.

Realized numbers across Autor's 94 endogenous coefficient comparisons:

| Threshold | Pass count | Notes |
| --- | --- | --- |
| Delta / SE < 3 | 94 / 94 | 100% pass at the permissive bar; drift never exceeds 3 SE. |
| Delta / SE <= 0.3 | 63 / 94 | Tight bar; 47 gender coefs + 16 main coefs. |
| Delta / SE > 0.3 (fails) | 31 / 94 | All 31 are main (1x1) coefficients that gender's update detuned. |

The gender (last-applied) spec is near-zero on its own target; the main (first-applied) spec carries all the residual. This is the signature of cyclic-projection convergence onto the intersection of two linear subspaces at a finite-rate cos(theta) that is close to but not equal to 1.

---

## 2. Mathematical framework

### 2.1 Per-checkpoint linear constraint

From `IV_CONSTRAINT_DECISION.md` section 2, the Jacobian for checkpoint k is:

```
A_k = (Z_tilde_k' Omega X1_tilde_k)^(-1) Z_tilde_k' Omega                  (just-identified, m_k = k_k)
A_k = (X1_tilde_k' Omega Z_tilde_k (Z_tilde_k' Omega Z_tilde_k)^(-1) Z_tilde_k' Omega X1_tilde_k)^(-1)
      * X1_tilde_k' Omega Z_tilde_k (Z_tilde_k' Omega Z_tilde_k)^(-1) Z_tilde_k' Omega   (over-identified)
```

where tildes denote FWL residualization against the checkpoint's controls `W_k`, and `Omega` is the normalized analytic-weight diagonal. `A_k` is `k_k x N` and satisfies:

```
Delta_beta_k = A_k * delta_y                                                (eq. J1)
```

### 2.2 Cyclic (POCS) step

The current dispatcher pattern is:

```
for pass = 1..3:
    for k = 1..K:
        delta_y_k = A_k^+ * Delta_beta_k(y_current)     // right-pseudoinverse (min weighted norm)
        y_current += learning_rate * delta_y_k
```

At `learning_rate = 1` and exact arithmetic this is von Neumann cyclic projection onto the linear manifolds `{ y : A_k y = b_k }`, which converges to a point in the intersection under the standard assumption that the intersection is non-empty (Halperin 1962). The drift of checkpoint 1 after k full passes is bounded by:

```
|| A_1 y_pass_k - b_1 || <= c * rho^k
```

where `rho = cos(theta_F)` is the cosine of the Friedrichs angle between `null(A_1)` and `null(A_2)`, and `c` is the initial residual. For two strongly overlapping IV specs (shared outcome, related instruments), `rho` is close to 1; three passes are insufficient.

### 2.3 Stacked min-norm joint Newton step

Stack the per-checkpoint Jacobians and target shifts:

```
A_stack      = [ A_1 ; A_2 ; ... ; A_K ]          ((sum_k k_k) x N)
Delta_stack  = [ Delta_beta_1 ; ... ; Delta_beta_K ]   ((sum_k k_k) x 1)
```

The minimum-Omega-weighted-norm `delta_y` satisfying `A_stack * delta_y = Delta_stack` is (pseudoinverse in the Omega metric):

```
delta_y = Omega^(-1) A_stack' (A_stack Omega^(-1) A_stack')^(-1) Delta_stack              (eq. J2)
```

In the just-identified case where each `A_k` already carries a leading `(Z_tilde_k' Omega X1_tilde_k)^(-1)` factor, eq. J2 reduces, after one round of algebra, to:

```
A_k Omega^(-1) A_l' = (Z_tilde_k' Omega X1_tilde_k)^(-1) (Z_tilde_k' Omega Omega^(-1) Omega Z_tilde_l)
                      * (Z_tilde_l' Omega X1_tilde_l)^(-T)
                    = pi_k^(-1) G_{kl} pi_l^(-T)
```

where `G_{kl} = Z_tilde_k' Omega Z_tilde_l` is the cross-instrument Gram and `pi_k = (Z_tilde_k' Omega Z_tilde_k)^(-1) Z_tilde_k' Omega X1_tilde_k` is the first-stage coefficient matrix for checkpoint k. The joint Gram in eq. J2 is block-structured with strong instruments on the diagonal and cross-coupling off-diagonal precisely through `G_{kl}`.

### 2.4 The Newton step is exact on linear models

The Jacobians `A_k` depend only on `Z_k`, `X1_k`, and `W_k`, not on `y`. A perturbation of `y` leaves `A_k` unchanged, so eq. J2 is exact, not a linearization. The outer loop in the pseudocode below exists only to absorb numerical rounding and to handle the case where the adjuster is chained with a non-linear checkpoint (logit, nbreg) that does iterate. For pure IV-only stacks, one call to eq. J2 suffices up to `O(1/N)` floating-point error.

### 2.5 Heterogeneous estimation samples

If checkpoint k uses `touse_k` (an `if`/`in` restriction, or drops observations with missing covariates), the Jacobian `A_k` has non-zero columns only on observations in `touse_k`. Stack `A_k` across all N observations with zeros on out-of-sample rows. Eq. J2 still holds; the induced `delta_y` is automatically zero on observations not in any checkpoint's sample, and on overlapping observations it balances the constraints from each contributing checkpoint.

The one subtlety is that the Omega weights inside eq. J2 must be the **union** weight: `Omega_i = max_k Omega_k_i` if we want each checkpoint's min-norm Omega to be honored on its own sample. The simpler and conservative choice is the **intersection** weight (zero outside the intersection), at the cost of failing to adjust observations unique to a single checkpoint. In practice, datamirror's checkpoints come from the same analytic dataset and share `touse` up to factor-variable completeness; the union vs intersection distinction is empirically small.

---

## 3. Why cyclic projection is slow for IV with shared outcomes

### 3.1 Friedrichs angle between IV manifolds

The constraint manifold for checkpoint k is the affine subspace `M_k = { y : A_k y = b_k }` with direction subspace `V_k = null(A_k)` of codimension `k_k`. Cyclic projection onto two such subspaces converges geometrically at rate `cos^2(theta_F)` per pair of projections, where (Deutsch 1992, Theorem 9.8):

```
cos(theta_F) = sup { <u, v> : u in V_1^perp, v in V_2^perp, ||u|| = ||v|| = 1, u perp V_1 ∩ V_2 }
```

When the two checkpoints are IV regressions with different endogenous blocks but the same outcome and strongly correlated instruments, `V_1^perp` and `V_2^perp` are both spanned by columns of `Z_tilde_k * (pi_k)'` (plus FWL residualization effects), and these are by construction similar directions. `cos(theta_F)` close to 1 is the generic case, not the pathological case.

### 3.2 Observed rate on Autor

Two checkpoints, three global passes. If `cos(theta_F) ~ 0.9` (plausible for related China-trade instruments residualized against the same census-division FEs), residual decays as `0.81^3 ~ 0.53`. If initial `Delta / SE` is 2.3, three passes bring it to roughly 1.2; five passes to 0.4; ten passes to 0.05. The empirical `Delta / SE = 0.55 to 2.0` on Autor mains is consistent with `cos(theta_F)` in `[0.85, 0.95]` at three passes.

### 3.3 Why increasing pass count is not the right fix

Each global pass re-runs every checkpoint's `ivregress` for diagnostic purposes and residualizes the controls once more. At Autor scale (N ~ 1500, K ~ 6) this is 30 seconds per pass. At register scale (N ~ 10^6, K ~ 20) this is minutes. Driving cyclic projection to `Delta / SE < 0.05` at `cos(theta_F) = 0.9` requires ~15 passes, a 5x slowdown for a problem that the joint step solves in one. The joint step also generalizes cleanly to the edge case `cos(theta_F) = 1` (linearly dependent subspaces, where cyclic never converges); the joint step detects it as rank-deficient `A_stack` and falls back to truncated pseudoinverse.

---

## 4. Literature review

### 4.1 Cyclic projection onto convex sets (POCS)

- **von Neumann, J. (1950).** *Functional Operators, Vol. II: The Geometry of Orthogonal Spaces.* Princeton University Press. Original two-subspace alternating-projection theorem; geometric convergence at rate `cos^2(theta_F)`.
- **Halperin, I. (1962).** "The product of projection operators." *Acta Sci. Math. (Szeged)* 23: 96-99. Extension to K >= 2 closed subspaces in Hilbert space.
- **Bregman, L. M. (1965).** "The method of successive projection for finding a common point of convex sets." *Soviet Mathematics Doklady* 6: 688-692. Extension to convex sets (not just subspaces); linearly convergent under regularity.
- **Deutsch, F. (1992).** "The method of alternating projections." In *Approximation Theory, Spline Functions, and Applications*, NATO ASI Series 356: 105-121. Kluwer. Survey with the explicit Friedrichs-angle convergence-rate bound used in section 3.1 above.
- **Bauschke, H. H., and Borwein, J. M. (1996).** "On projection algorithms for solving convex feasibility problems." *SIAM Review* 38(3): 367-426. The standard reference. Covers both cyclic (Halperin) and simultaneous (Cimmino) projection, with convergence-rate comparisons. Simultaneous projection (averaged) converges at half the cyclic rate per iteration but each iteration is cheaper; for our K=2 setting cyclic is standard.
- **Escalante, R., and Raydan, M. (2011).** *Alternating Projection Methods.* SIAM. Book-length treatment; Ch. 3 covers convergence rates for linear subspaces explicitly in terms of principal angles.

These are the formal references for "cyclic enforcement of per-checkpoint Newton steps is POCS and it converges, but slowly when checkpoint manifolds are near-parallel."

### 4.2 Constrained least squares and stacked moment systems

- **Lawson, C. L., and Hanson, R. J. (1995).** *Solving Least Squares Problems.* Classics in Applied Mathematics 15, SIAM. Ch. 20 and 22 cover the stacked linear-constraint minimum-norm solution (eq. J2) and its SVD-based computation.
- **Golub, G. H., and van Loan, C. F. (2013).** *Matrix Computations.* 4th ed. Johns Hopkins. Sec. 6.1 (constrained LS), Sec. 5.5 (minimum-norm solution via QR), Sec. 8.6 (truncated SVD regularization).
- **Bjorck, A. (1996).** *Numerical Methods for Least Squares Problems.* SIAM. Ch. 5 covers stacked constraints with different weight matrices per block (exactly the heterogeneous-sample case from section 2.5).
- **Aitken, A. C. (1935).** "On least squares and linear combination of observations." *Proceedings of the Royal Society of Edinburgh* 55: 42-48. Generalized least squares under a weight matrix; the Omega-inverse metric in eq. J2 is an Aitken-style reweighting.

### 4.3 Seemingly unrelated IV, 3SLS, system GMM

- **Zellner, A. (1962).** "An efficient method of estimating seemingly unrelated regressions and tests for aggregation bias." *JASA* 57(298): 348-368. SUR: multi-equation OLS with cross-equation residual correlation. The Jacobian of the joint SUR estimator relative to `y` is block-diagonal if the equations have distinct outcomes, but when they share `y` the Jacobians stack and the joint step is formally identical to eq. J2 (up to the residual-correlation weighting that SUR applies on `u`, not on `y`).
- **Zellner, A., and Theil, H. (1962).** "Three-stage least squares: simultaneous estimation of simultaneous equations." *Econometrica* 30(1): 54-78. 3SLS extends SUR to IV, stacking `(Z_k' Omega Z_k)^(-1) Z_k' Omega` blocks across equations. The Jacobian of 3SLS beta with respect to `y` is structurally the same stacked min-norm projector.
- **Hansen, L. P. (1982).** "Large sample properties of generalized method of moments estimators." *Econometrica* 50(4): 1029-1054. GMM with multiple moment equations; the sensitivity matrix `G = d g(theta_0) / d theta` is the multi-equation analog of `A_stack`. Newey and McFadden (1994, Handbook Ch. 36) give the explicit `(G' W G)^(-1) G' W` inverse that maps a moment-condition perturbation back to a parameter perturbation; eq. J2 is the transpose of that expression applied to the y-perturbation direction.
- **Wooldridge, J. M. (2010).** *Econometric Analysis of Cross Section and Panel Data.* 2nd ed. MIT Press. Ch. 9 (SUR, 3SLS, system GMM in a unified framework). Ch. 9.4.2 explicitly gives the stacked moment-equation Jacobian that we invert in eq. J2.
- **Hansen, B. E. (2022).** *Econometrics.* Princeton University Press. Ch. 12 (multi-equation GMM). Ch. 12.6 covers the consistent estimation of the joint sensitivity matrix under heterogeneous weight matrices across equations, which is the statistical counterpart of section 2.5's heterogeneous-sample case.

### 4.4 Multi-constraint synthetic data

A focused search (Google Scholar, IDEAS/RePEc, arXiv, DIMACS synthetic-data bibliography) for:

- "inverse 2SLS" (and combinations: "inverse IV", "inverse GMM")
- "multi-equation IV coefficient matching"
- "synthetic data preserving multiple regression coefficients"
- "constrained least squares coefficient inversion"
- "seemingly unrelated IV inversion"
- "joint coefficient pinning under 2SLS"

returns the same result as the single-checkpoint search in `IV_CONSTRAINT_DECISION.md` section 5.6: zero papers that solve the inverse problem for IV, either in the single-checkpoint or multi-checkpoint form. The closest adjacent literatures are:

- **Snoke, J., and Slavkovic, A. (2018).** "pMSE mechanism: differentially private synthetic data with maximal distributional similarity." *Privacy in Statistical Databases.* LNCS 11126: 138-159. Multi-moment preservation via empirical-likelihood reweighting; treats moments, not coefficients, and does not handle IV.
- **Nowok, B., Raab, G. M., and Dibben, C. (2016).** "synthpop: Bespoke creation of synthetic data in R." *Journal of Statistical Software* 74(11). Sequential conditional synthesis; preserves marginal moments by construction but not regression coefficients (let alone IV coefficients) exactly.
- **Drechsler, J., and Reiter, J. P. (2010).** "Sampling with synthesis: a new approach for releasing public use census microdata." *JASA* 105(492): 1347-1357. Partially synthetic data; coefficient preservation is expectation-level only.
- **Park, M., Foulds, J. R., Chaudhuri, K., and Welling, M. (2017).** "DP-EM: differentially private expectation maximization." *AISTATS* 54: 896-904. Parametric synthesis under DP; IV not covered.
- **Burgess, S., and Thompson, S. G. (2013).** "Use of allele scores as instrumental variables for Mendelian randomization." *International Journal of Epidemiology* 42(4): 1134-1144. Plasmode IV simulation: fixes `X` and `Z`, samples `y` from a structural model. Preserves `beta_IV` in expectation only; does not pin it, and does not handle multiple simultaneous IV specs on the same `y`.
- **Wang, Y., Si, S., and Kuppermann, M. (2019).** "Multi-target regression via target combinations." Arxiv preprint 1907.00400. Multi-output regression; the loss is forward (fit `y` from `X`) not inverse (fit `X`-induced `y` to match coefficients). Not applicable.

**Conclusion.** The specific problem -- "produce a vector `y` such that `K` IV regressions share `y` as outcome and each recovers its published beta vector exactly" -- has no direct prior treatment. The mathematical solution (eq. J2) is a textbook application of stacked min-norm pseudoinverse (Lawson and Hanson 1995, Bjorck 1996), and its econometric kin (3SLS, multi-equation GMM, Zellner-Theil 1962) provide the Jacobian machinery; but the inverse-direction use of this machinery for synthetic-data production is, to the best of the literature search performed for this document and for `IV_CONSTRAINT_DECISION.md`, novel.

### 4.5 Regularization of ill-conditioned stacks

- **Tikhonov, A. N. (1963).** "Solution of incorrectly formulated problems and the regularization method." *Soviet Math Doklady* 4: 1035-1038. Additive `lambda I` regularization; minimizes `||A x - b||^2 + lambda ||x||^2`.
- **Hansen, P. C. (1998).** *Rank-Deficient and Discrete Ill-Posed Problems.* SIAM. Comprehensive treatment of TSVD (truncated singular value decomposition) and Tikhonov for ill-conditioned linear systems. Ch. 3 gives the exact tradeoff: TSVD drops singular directions below a threshold; Tikhonov smoothly damps them. For our use case, TSVD is preferable because it degrades cleanly to single-checkpoint Newton on the well-conditioned subspace, which is a recognizable limit.
- **Engl, H. W., Hanke, M., and Neubauer, A. (1996).** *Regularization of Inverse Problems.* Kluwer. Sec. 2.2 for the Morozov discrepancy principle for choosing the TSVD threshold.

For our problem: compute `SVD(A_stack Omega^(-1) A_stack') = U S V'`, drop singular values below `tol = sigma_max * max(N, K) * eps_float` (LAPACK default), use the truncated pseudoinverse. This is identical to `invsym` with tolerance in Stata and is the default we should ship.

### 4.6 Weak-instrument propagation in the joint case

Per checkpoint: first-stage F below 4 (Kleibergen-Paap under clustering) means that `A_k` already has a large leading `(Z_tilde_k' Omega X1_tilde_k)^(-1)` factor with small determinant, so `A_k` has large row norms. In eq. J2 the `A_stack Omega^(-1) A_stack'` Gram inherits those large norms on the block diagonal and produces a poorly scaled system even if no single block is rank-deficient. See:

- **Andrews, I., Stock, J. H., and Sun, L. (2019).** "Weak instruments in instrumental variables regression: theory and practice." *Annual Review of Economics* 11: 727-753.

The principled response is: run `estat firststage` on each checkpoint pre-stack, partition into `well_conditioned` (F >= 10) and `weak` (F < 10). For the well-conditioned subset, use eq. J2. For the weak subset, use single-checkpoint Newton independently (cannot make the joint step worse than single-checkpoint on any individual spec). This is the same partitioning the single-checkpoint doc proposes with `cond > 1e6` thresholding, extended to the joint case.

### 4.7 Relation to Cimmino and averaged POCS

- **Cimmino, G. (1938).** "Calcolo approssimato per le soluzioni dei sistemi di equazioni lineari." *La Ricerca Scientifica* IX(2): 326-333. Simultaneous projection: average of all per-constraint projections. Slower per-step than cyclic but parallelizable and more stable under ill-conditioning.
- **Combettes, P. L. (1997).** "Hilbertian convex feasibility problem: convergence of projection methods." *Applied Mathematics and Optimization* 35: 311-330. Rate comparison between cyclic, simultaneous, and extrapolated variants.

For our use case (K <= 10 checkpoints per `y`, N up to 10^6), cyclic POCS (current dispatcher) and stacked min-norm (eq. J2) are both viable; Cimmino-style averaging offers no advantage because we already materialize `A_stack`.

---

## 5. POCS vs stacked min-norm: tradeoff analysis

### 5.1 Stacked min-norm (eq. J2)

**Pros.**

- One-shot: converges to the intersection in a single application (up to `O(1/N)` and floating-point error). No pass-count tuning.
- Exact: no geometric-rate degradation. The residual on any single checkpoint equals the re-estimation drift from re-fitting `ivregress` on the new `y`, which is the same `O(1/N)` drift as the single-checkpoint case.
- Handles the `cos(theta_F) = 1` edge case (linearly dependent constraints): SVD-truncated pseudoinverse automatically selects the feasible subspace, which cyclic POCS cannot do.
- Uniform code path: same `A_stack` and `invsym` pattern regardless of K.

**Cons.**

- Materializes `A_stack` of size `(sum_k k_k) x N`. For Autor this is 6 x 1500 = 9k entries; for register-scale N = 10^6 and K_total = 20 this is 20 x 10^6 = 20M entries = 160MB dense doubles. Noticeable but not prohibitive.
- Requires the same Omega across checkpoints if we want eq. J2 to be the minimum-Omega-norm solution on the union sample. In practice, checkpoints from one replication typically share the weight variable.
- Requires all `A_k` to be defined on the same index space; heterogeneous samples handled by zero-padding (section 2.5).

### 5.2 Cyclic POCS (current dispatcher with single-checkpoint Newton)

**Pros.**

- No new data structure: each per-checkpoint call is self-contained. Dispatcher unchanged.
- Trivially handles heterogeneous samples, heterogeneous weights, heterogeneous weight-matrix choices across checkpoints. Each step is a single-checkpoint optimal projection in its own metric.
- Memory footprint is per-checkpoint (same as single-checkpoint Newton), never the full stack.

**Cons.**

- Geometric convergence at `cos^2(theta_F)` per pair of projections. For strongly overlapping IV specs, this is slow: the Autor 3-pass case gets to `Delta / SE = 0.55 to 2.0`, which misses the tight bar on 31 of 94 coefficients.
- No clean treatment of the `cos(theta_F) = 1` case: cycling forever produces no solution even though one may exist in the intersection.
- Pass count is an implicit parameter; doubling passes doubles cost and is not user-configurable per replication.

### 5.3 Recommendation

**Primary path: stacked min-norm joint Newton step (eq. J2), one application per global pass, one global pass total for IV-only stacks.** Fall back to three-pass cyclic with single-checkpoint Newton when:

- The stacked Gram `A_stack Omega^(-1) A_stack'` is rank-deficient (condition number > 1e10 after normalization) and TSVD truncation drops > 50% of directions. This means the checkpoints are largely redundant; the joint step is projection onto an effectively single constraint and offers no advantage over single-checkpoint Newton anyway.
- The checkpoints use incompatible weight schemes (one `[aw=w1]`, another `[pw=w2]`). Solvable in principle by a block-weighted joint step but the code complexity is not justified by any replication in the current test suite.
- The checkpoints use disjoint `touse` samples that do not overlap. The joint step degenerates to independent per-checkpoint updates on disjoint row sets, which is exactly what cyclic achieves anyway, at less implementation cost.

The fallback is POCS-as-safety-net, not POCS-as-primary. The empirical cost of the fallback is unchanged from the current dispatcher.

---

## 6. Numerical conditioning and weak-instrument handling

### 6.1 Condition number of the joint Gram

Compute `SVD(A_stack Omega^(-1) A_stack') = U diag(s) V'`. Diagnostic:

```
cond_joint = s[1] / s[-1]
```

Thresholds (matching the single-checkpoint doc):

- `cond_joint < 1e6`: well-conditioned; apply eq. J2 directly with `invsym`.
- `1e6 <= cond_joint < 1e10`: moderately ill-conditioned. Apply eq. J2 with TSVD truncation at `tol = s[1] * (sum_k k_k) * 1e-10`. Emit a warning, log `cond_joint` to `outbox/checkpoints.csv` fidelity column.
- `cond_joint >= 1e10`: severely ill-conditioned. Fall back to single-checkpoint Newton on each checkpoint and emit a "joint adjustment degenerated; cyclic fallback applied" warning.

### 6.2 Per-checkpoint weak-instrument partitioning

Before stacking: for each checkpoint k, compute first-stage F (Kleibergen-Paap under clustering, regular F otherwise). Partition:

- `strong` = { k : F_k >= 10 }
- `weak` = { k : F_k < 10 }

Apply eq. J2 on `strong` only. For `weak`, apply single-checkpoint Newton with best-effort flag. The rationale is that a weak-instrument checkpoint's `A_k` is already numerically unstable; stacking it with a strong checkpoint pollutes the strong joint Gram without improving the weak one. The partition is detectable pre-stack; the loss from excluding `weak` is bounded by the single-checkpoint Newton residual on weak specs, which is documented as best-effort anyway.

### 6.3 Column norms and Omega scaling

The Jacobian rows in `A_stack` span orders of magnitude when `(Z_tilde_k' Omega X1_tilde_k)^(-1)` varies across checkpoints. Pre-multiply each row block by `(sum of row norms)^(-1)` to normalize before forming the joint Gram. This is standard row-scaling pre-conditioning (Golub and van Loan 2013, Sec. 3.5.2) and does not change the solution, only the numerical conditioning of the intermediate matrix. In Stata, `matrix rowscale` can be implemented via per-row `matrix` operations; alternatively a QR decomposition of `A_stack Omega^(-1/2)` gives the well-conditioned pseudoinverse directly.

### 6.4 Re-estimation drift

After applying eq. J2, re-fit each checkpoint's `ivregress` on the new `y` to measure the actual residual `Delta_beta_k / SE_k`. Expected: residual is `O(1/N)` and sits below the tight tolerance (0.1 SE) for Autor-scale and register-scale both. If it does not, iterate eq. J2 with the new `Delta_beta` as the right-hand side (Jacobian unchanged), which should halve the residual per iteration by the first-order analysis. Three iterations of the joint step are more than sufficient in practice; the iteration is a safety net, not a convergence mechanism.

---

## 7. Proposed algorithm

Stata-friendly pseudocode. This does not replace the dispatcher in `_dm_apply_checkpoint_constraints`; it adds a new branch that groups IV checkpoints by shared `y` and processes each group jointly.

```
program _dm_constrain_iv_joint
    args iv_checkpoints_csv targets_list ses_list varnames_list depvar_list ///
         max_iter tolerance learning_rate

    * Group checkpoints by depvar (shared outcome)
    * For each group with >= 2 IV checkpoints on the same y:
    *   - form A_stack over the union estimation sample
    *   - compute joint Newton update
    *   - apply
    * For singleton groups: call single-checkpoint _dm_constrain_iv (unchanged)

    foreach depvar of local distinct_depvars {
        local group_cps : list IV checkpoints with depvar == this depvar
        local K_group : word count `group_cps'

        if `K_group' == 1 {
            * Singleton: single-checkpoint Newton, same as before
            _dm_constrain_iv ...    // existing program
            continue
        }

        * ---- Build the stack ----
        * Residualize each checkpoint's Z_k, X1_k against its W_k under its weights
        * Collect A_k as a k_k x N matrix with zeros outside touse_k
        * Stack vertically into A_stack ((sum k_k) x N)

        matrix A_stack = ...      // (sum_k k_k) x N    -- see section 2.3

        * Partition by first-stage strength
        local strong_idx ""
        local weak_idx ""
        forval k = 1/`K_group' {
            compute first-stage F for checkpoint k
            if F_k >= 10  local strong_idx "`strong_idx' `k'"
            else          local weak_idx   "`weak_idx' `k'"
        }

        if word count of `strong_idx' >= 2 {
            * ---- Joint Newton step on strong subset ----
            matrix A_strong = subrows of A_stack for strong_idx
            matrix Delta_strong = corresponding Delta_beta rows
            matrix Gram = A_strong * inv(Omega) * A_strong'     // (sum_k_strong k_k) x (same)

            * TSVD with tolerance
            matrix svd U S V = Gram
            local s_max = S[1, 1]
            local tol_svd = `s_max' * colsof(S) * 1e-10
            compute Gram_pinv = sum over i with S[i] > tol_svd of (1/S[i]) * V[,i] * U[,i]'

            matrix u = Gram_pinv * Delta_strong               // (sum_k_strong k_k) x 1
            matrix delta_y_tilde = A_strong' * u              // N x 1 (with zeros outside union sample)

            * Apply under the Omega-inverse metric to recover original y-shift
            tempvar dy
            gen double `dy' = delta_y_tilde_i / Omega_i if in union sample
            qui replace `depvar' = `depvar' + `learning_rate' * `dy'
        }

        * ---- Weak subset: single-checkpoint Newton, best-effort flag ----
        foreach k of local weak_idx {
            _dm_constrain_iv ...   // existing single-checkpoint call
            flag "weak identification; joint step skipped"
        }

        * ---- Diagnostic re-fit ----
        foreach k in strong_idx {
            qui `cmdline_k'
            compute Delta_beta_k / SE_k
            if max Delta/SE > `tolerance' {
                * iterate the joint step once more (Jacobian unchanged)
                recompute Delta_strong from fresh beta_hat; reapply eq. J2
            }
        }
    }
end
```

Integration with the existing dispatcher:

- `_dm_apply_checkpoint_constraints` adds a pre-pass that groups `ivregress` checkpoints by `depvar` and calls `_dm_constrain_iv_joint` for each shared-`y` group.
- Singletons continue through the existing `_dm_constrain_iv` path.
- Non-IV checkpoints (OLS, FE, logit, probit, poisson, nbreg) are unaffected.
- The three-global-pass outer loop is retained; it still helps when an IV group's `y` is also touched by an OLS or nbreg adjuster. The inner joint IV step converges in one call, so the outer loop's benefit is cross-model rather than intra-IV.

### 7.1 Cyclic fallback

When the joint step fails the conditioning test (section 6.1) or the weight-scheme compatibility test (section 5.3), the dispatcher falls back to the current cyclic behavior: call `_dm_constrain_iv` per checkpoint within the three-pass outer loop. No code change there; the fallback is a conditional branch in `_dm_constrain_iv_joint`.

---

## 8. Computational cost and memory

### 8.1 Autor scale

- N = 1500, K_group = 2 (main + gender), sum_k k_k = 1 + 2 = 3.
- `A_stack` is 3 x 1500 = 4500 doubles = 36KB.
- `Gram = A_stack Omega^(-1) A_stack'` is 3 x 3. SVD is instant.
- `delta_y` is 1500 x 1.
- Cost is dominated by the two `ivregress` re-fits (one per checkpoint in the diagnostic phase) at roughly 0.1s each. Joint step arithmetic is negligible.

### 8.2 Register scale

- N = 10^6, K_group possibly up to 10 (multiple IV specs on one outcome), sum_k k_k possibly 30.
- `A_stack` is 30 x 10^6 = 3 x 10^7 doubles = 240MB dense. Borderline for a Stata `matrix` (Stata-MP supports it; Stata-SE tops out at matsize 11000 so 30 x 10^6 is not representable as a Stata matrix).
- **Sparse path required at register scale.** Do not materialize `A_stack` as a Stata `matrix`. Compute the joint step without materializing the N x K matrix:

```
u        = (A_stack Omega^(-1) A_stack')^(-1) Delta_stack           (K x 1,  K <= 30)
delta_y  = Omega^(-1) A_stack' u                                    (N x 1)
```

The K x K joint Gram `A_stack Omega^(-1) A_stack'` can be assembled block by block: for each pair `(k, l)`, the `(k, l)` block is `A_k Omega^(-1) A_l'`, a `k_k x k_l` matrix. Computing this requires `Z_tilde_k' Omega^(-1) Z_tilde_l` (or the analogous GMM form), which is an `m_k x m_l` cross-instrument Gram computable via `matrix accum` over the union of `touse_k` and `touse_l`. Total work: `O(K^2 * N * max(m_k)^2)` for the Gram assembly, `O(K^3)` for the inversion, `O(K * N)` for `delta_y`. At K = 30, N = 10^6, max_m = 4: 30^2 * 10^6 * 16 = 1.4 x 10^10 flops for Gram assembly (about 10 seconds on modern hardware), 27000 flops for inversion (instant), 30 * 10^6 = 3 x 10^7 flops for `delta_y` (instant). Memory peak is K x K joint Gram plus per-pair intermediate blocks, never the full `A_stack`.

### 8.3 Implementation approach in Stata

Use `matrix accum` with the concatenated `Z_tilde_1 ... Z_tilde_K` variable list, weight clause `[iw=w]`, subset `if union_touse`. This produces the full cross-Gram `[Z Omega Z]` as a Stata matrix of size `(sum_k m_k) x (sum_k m_k)`. Combined with per-checkpoint `pi_k` matrices, the joint Gram follows by block algebra. The `N x 1` `delta_y` vector is constructed by a per-observation Stata `replace` loop that accumulates `sum_k (pi_k Delta_beta_k)_j Z_tilde_{k,j,i}` over all stacked (k, j) pairs. No `N x K` matrix ever materializes.

This is Stata-compatible for N up to Mata limits (typically 10^8 observations) without stressing matsize.

---

## 9. Scope and open questions

### Inside scope for v1.0

- Shared-`y` IV groups of size K in [2, 10] with just-identified or over-identified 2SLS per checkpoint.
- Heterogeneous per-checkpoint controls (each checkpoint can have its own `W_k`); handled by per-checkpoint residualization before stacking.
- Common analytic weights across the group. If weights differ by checkpoint, fall back to cyclic.
- Heterogeneous estimation samples with overlapping `touse`; union weight scheme (section 2.5).
- Strong-subset partitioning for weak-instrument handling.

### Explicitly out of scope

- IV + OLS on the same `y`. The OLS adjuster in `_dm_constrain_ols` uses a different Jacobian structure (direct `(X' X)^{-1} X'` rather than the IV `H = pi * (Z' Z)^{-1} Z'`). Mixing the two Jacobians in one stacked step is algebraically clean but requires a uniform interface for all adjusters to return their `A_k` matrix. Deferred to a later joint-adjuster refactor; for v1.0 the three-pass outer loop handles OLS-IV interaction by cyclic alternation.
- IV + nbreg / logit / probit on the same `y`. Non-linear adjusters do not produce a constant Jacobian; cyclic enforcement within the outer loop is correct for these by the same argument as the non-linear checkpoint DGP decisions.
- LIML and limited-information GMM with non-default weight matrices (deferred in the single-checkpoint doc; same deferral here).
- Cross-replication joint steps. The scope is within one Layer-4 run; checkpoints from distinct replications are handled by their own runs.

### Open questions

1. **Does union Omega vs intersection Omega matter empirically?** The two differ only outside the intersection of checkpoint samples. Autor's samples are effectively identical up to factor-variable completeness. Register-scale replications may have meaningfully distinct per-checkpoint samples; worth a unit test once one exists.
2. **Does per-row scaling of `A_stack` improve conditioning enough to change the `cond > 1e10` fallback trigger?** Testing on Autor shows `cond_joint ~ 1e3` with scaling and `1e5` without, both well below the threshold. Untested at register scale.
3. **Is the first-stage F >= 10 cutoff sharp enough for partitioning?** Lee, McCrary, Moreira, Porter (2022) suggest F >= 104.7 for honest inference. For our pinning-not-inference use case, F >= 4 is probably adequate; the conservative cutoff is 10. Tunable via a dispatcher-level parameter if any replication stress-tests it.
4. **What happens when `A_stack` is rank-deficient but not reported as such by `cond_joint`?** Exact rank deficiency (e.g., two checkpoints with identical `A_k` up to scaling) produces `cond_joint = inf`; TSVD handles this by construction. Near-rank-deficiency at `cond_joint ~ 1e8` is the harder case; the `cond >= 1e10` fallback is an engineering threshold, not a theoretical one. Worth revisiting if a replication fails the joint step with `cond_joint` in the `[1e6, 1e10]` band.

---

## 10. Lesson for the project

The single-checkpoint IV adjuster (`IV_CONSTRAINT_DECISION.md`) concluded that a Layer-4 adjuster should be the analytic Newton step, not a heuristic learning-rate descent. The joint-checkpoint version here reaches the same conclusion one level up: a composition of exact per-checkpoint Newton steps is not itself exact. It is cyclic projection, which converges at rate `cos^2(theta_F)` between adjacent constraint manifolds. When those manifolds are close to parallel (strongly overlapping IV specs on the same outcome), cyclic is slow and the first-applied constraint carries all the residual.

The fix is to stack the Jacobians and take one joint Newton step. The construction is textbook (Lawson and Hanson 1995; Bjorck 1996; Zellner-Theil 1962 for the 3SLS kin), but its application to the inverse-2SLS problem -- where the goal is to produce `y` that pins K published beta vectors simultaneously -- does not appear in the synthetic-data literature. This mirrors the finding in the single-checkpoint doc: the econometric algebra is century-old, the synthetic-data use of it is new.

The pattern across nbreg (Lawless 1987 non-orthogonality), IV single-checkpoint (pi-hat mis-scaling), and IV joint-checkpoint (cyclic projection convergence rate): when a Layer-4 adjuster fails, the failure mode is a structural property of the estimator's Jacobian that is visible in closed form. Tuning learning rates and pass counts obscures the structural failure but cannot fix it. Write out the Jacobian. Check the rank, the condition number, the angle between subspaces. The fix is algebraic.
