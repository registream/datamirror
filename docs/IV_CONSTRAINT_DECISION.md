# IV (2SLS) Layer-4 Adjuster Decision

**Date:** 2026-04-21
**Author:** Jeffrey Clark
**Context:** Layer 4 coefficient adjustment for `ivregress 2sls` and related instrumental-variables estimators.
**Decision:** Replace the single-instrument heuristic with a Newton-step joint-gradient adjuster that operates on the residualized, weight-corrected 2SLS moment condition. Scalar heuristic retained as a weight-aware warm start; the 1x1 bug is a closed-form computation once the projection and weights are handled correctly.

This document is the IV sibling of `NBREG_DGP_DECISION.md` and `LOGIT_PROBIT_DGP_DECISION.md`. IV is different from both: the outcome is continuous (so iterative y-shift is geometrically valid, unlike nbreg or logit), but the estimator is a ratio of inner products whose denominator involves a different variable (the instrument) than the numerator, so a naive "shift y along x" update misses the target.

---

## 1. Problem statement

Layer 4 of datamirror perturbs synthetic y so that re-running a checkpointed regression on (X_syn, y_syn) recovers the published coefficient vector beta* within sampling noise. For continuous-outcome OLS this works by iterating `y := y + lambda * (beta* - beta_hat) * (x - xbar)`. For 2SLS the existing adjuster (stata/src/_dm_constraints.ado, lines 763 to 947) uses the analogous instrument-side rule:

```
y := y + lambda * (beta* - beta_hat) * (Z - Zbar)
```

applied per endogenous variable with a 1-to-1 endogenous/instrument pairing.

### The puzzle

On the Autor, Dorn, Hanson (2019) "When Work Disappears" replication we observe an inverted difficulty gradient:

| Spec | Endogenous | Instruments | Identification | Result |
| --- | --- | --- | --- | --- |
| `iv_mainshock` | 1 | 1 | just-identified 1x1 | FAIL, delta_beta/SE = 0.55 to 2.00 |
| `iv_gendershock` | 2 | 2 | just-identified 2x2 | PASS, delta_beta/SE ~ 0.00 |

Overall Autor fail rate is 40/72 = 55.6% at the private-tree baseline threshold. Every failure is a single-instrument 1x1 spec. The simpler case is structurally broken while the harder case passes. That is the signal.

Three confounds are present in both specs:

1. **Analytic weights.** `[aw=timepwt24]` is passed to `ivregress`. Stata's 2SLS under aweights uses weighted moments `Z' W X` and `Z' W y`. The heuristic uses raw `(Z - Zbar)` and raw replace on y, so the per-observation update weight is 1/n instead of w_i/sum(w).
2. **Control variables partialled out.** Autor's specifications include census-division fixed effects and demographic controls W. The 2SLS estimand for the endogenous block uses `M_W Z` (instrument residualized against controls), not raw Z. The heuristic uses raw Z.
3. **Cluster-robust SE.** `cluster(statefip)` affects SE but not beta_hat. It matters for the delta_beta/SE convergence check but not for the beta update rule.

The 2x2 case passes anyway. The explanation for both phenomena (2x2 succeeds, 1x1 fails) is in the algebra: under residualization the cross-instrument terms that drive 1x1 off target cancel symmetrically in the k x k just-identified case for this particular spec. Details in section 4.

---

## 2. Econometric framework

### 2.1 2SLS as a linear estimator

Let y be N x 1, X = [X1 X2] be N x (k + p) where X1 is N x k endogenous and X2 is N x p exogenous (including the constant and controls W), and Z_full = [Z X2] be N x (m + p) with m >= k instruments. Weighted 2SLS with analytic weights w_i (stacked in the diagonal matrix Omega = diag(w_i) / sum(w_i) after normalization) solves:

```
beta_hat = (X' Omega P_Z_Omega X)^(-1) (X' Omega P_Z_Omega y)
```

where `P_Z_Omega = Omega^(1/2) Z_full (Z_full' Omega Z_full)^(-1) Z_full' Omega^(1/2)` is the weighted projection onto the instrument span. This is the standard GMM with weight matrix `(Z' Omega Z)^(-1)` (Wooldridge 2010, Ch. 8.3; Hansen 1982).

### 2.2 Residualized endogenous block (Frisch-Waugh-Lovell for IV)

Applying FWL for IV (Baltagi 2008, Ch. 11; Angrist and Pischke 2009, Ch. 4.1.2):

```
M_W      = I - W (W' Omega W)^(-1) W' Omega      (weighted annihilator for controls)
X1_tilde = M_W X1
Z_tilde  = M_W Z
y_tilde  = M_W y
```

The 2SLS estimator for the endogenous coefficient vector beta_1 is:

```
beta_1_hat = (X1_tilde' Omega P_Ztilde_Omega X1_tilde)^(-1) (X1_tilde' Omega P_Ztilde_Omega y_tilde)
```

where `P_Ztilde_Omega` is the weighted projection onto Z_tilde. In the just-identified case m = k:

```
beta_1_hat = (Z_tilde' Omega X1_tilde)^(-1) (Z_tilde' Omega y_tilde)                      (eq. 1)
```

**This is the key equation.** The denominator is the weighted residualized cross-moment between instrument and endogenous regressor. The numerator is the weighted residualized cross-moment between instrument and outcome.

### 2.3 Scalar case (k = m = 1)

With a single endogenous X1 and single instrument Z:

```
beta_1_hat = sum_i w_i * Z_tilde_i * y_tilde_i  /  sum_i w_i * Z_tilde_i * X1_tilde_i     (eq. 2)
```

### 2.4 Perturbation of y: closed-form

Shift y by a vector delta y. Because M_W and the weighting are linear:

```
y_tilde_new = M_W (y + delta y) = y_tilde + M_W delta y
```

In the just-identified case (eq. 1):

```
beta_1_new  = (Z_tilde' Omega X1_tilde)^(-1) [ Z_tilde' Omega (y_tilde + M_W delta y) ]
            = beta_1_hat + (Z_tilde' Omega X1_tilde)^(-1) Z_tilde' Omega M_W delta y
```

Since `Z_tilde = M_W Z` and `M_W' Omega M_W = Omega M_W` (M_W is Omega-idempotent), `Z_tilde' Omega M_W = Z_tilde' Omega`. So:

```
delta_beta_1 = (Z_tilde' Omega X1_tilde)^(-1) (Z_tilde' Omega delta y)                   (eq. 3)
```

### 2.5 The exact update rule we want

Given target shift delta_beta_1 = beta_1* - beta_1_hat (a k x 1 vector), we need delta y such that eq. 3 holds. This is an underdetermined linear system (N unknowns, k equations). The minimum-norm solution (weighted-least-squares pseudoinverse, analogous to the NBREG score-equation path rejected in that doc) is:

```
delta y = Omega^(-1) Z_tilde * A^(-1) * (Z_tilde' Omega X1_tilde) * delta_beta_1         (eq. 4)
```

where `A = Z_tilde' Omega Omega^(-1) Omega Z_tilde = Z_tilde' Omega Z_tilde` is the weighted Gram of the residualized instrument. In scalar form:

```
delta y_i = w_i^(-1) * Z_tilde_i * [ (Z_tilde' Omega X1_tilde) / (Z_tilde' Omega Z_tilde) ] * delta_beta_1   (eq. 5)
```

**Equation 5 is what the adjuster should compute.** It has three pieces the current heuristic gets wrong:

- `Z_tilde` not raw Z: residualize the instrument against the controls.
- Weighted cross-moment ratio `(Z_tilde' Omega X1_tilde) / (Z_tilde' Omega Z_tilde)` as the scaling coefficient, not Var(Z). This is literally the first-stage coefficient from regressing X1 on Z given controls and weights (equivalent to the pi_hat in the reduced-form decomposition beta_IV = rho / pi, Angrist and Pischke 2009, Ch. 4.6).
- Weight correction `w_i^(-1)` on the per-observation shift.

### 2.6 Over-identified case (m > k)

With m > k, 2SLS is GMM with the efficient weight matrix `(Z_tilde' Omega Z_tilde)^(-1)` (Hansen 1982, Newey and McFadden 1994, sec. 3):

```
beta_1_hat = [X1_tilde' Omega Z_tilde (Z_tilde' Omega Z_tilde)^(-1) Z_tilde' Omega X1_tilde]^(-1)
             [X1_tilde' Omega Z_tilde (Z_tilde' Omega Z_tilde)^(-1) Z_tilde' Omega y_tilde]
```

Define the k x N instrument-weighted projector on the residualized space:

```
H = [X1_tilde' Omega Z_tilde (Z_tilde' Omega Z_tilde)^(-1) Z_tilde' Omega X1_tilde]^(-1)
    [X1_tilde' Omega Z_tilde (Z_tilde' Omega Z_tilde)^(-1) Z_tilde' Omega]         (k x N)
```

Then `beta_1_hat = H y_tilde` and `delta_beta_1 = H M_W delta y`. The minimum-norm solution is:

```
delta y = Omega^(-1) M_W' H' (H H')^(-1) delta_beta_1                               (eq. 6)
```

### 2.7 Joint-gradient Newton step (what to ship)

Eq. 5 and eq. 6 are exact (up to `O(1/N)` sampling drift reintroduced by re-estimating `beta_hat`) and one-shot when all quantities are computed on the current synthetic data. Treat them as a Newton step on the reduced loss `L(y) = ||beta_hat(y) - beta_1*||^2` with Jacobian:

```
J = d beta_hat / d y = H M_W        (k x N, just-identified reduces to eq. 3)
```

### 2.8 Why the current heuristic is not eq. 5

The current code computes `y := y + lambda * Delta_beta * (Z - Zbar)` per endogenous. Expand in the scalar case under no weights and no controls (Omega = I/N, W = {1}):

- `(Z - Zbar)` equals `Z_tilde` (residualization against a constant only).
- The scaling factor is `1` (arbitrary lambda).
- The correct scaling factor from eq. 5 is `(Z_tilde' X1_tilde) / (Z_tilde' Z_tilde)` = first-stage coefficient pi_hat.

So the heuristic is eq. 5 with `lambda` substituted for `pi_hat`. When pi_hat happens to be near 1 and controls are orthogonal, the heuristic works. When pi_hat is far from 1 (weak or strong instruments) or controls are correlated with the instrument (Autor's census-division fixed effects), it does not. This is the structural bug.

---

## 3. Why 2x2 passes and 1x1 fails

Expanding eq. 3 for a 2x2 just-identified spec with diagonal pairing (endog_j paired to inst_j):

```
delta_beta_1 = (Z_tilde' Omega X1_tilde)^(-1) Z_tilde' Omega delta y            (2 x 1)
```

If the heuristic sets `delta y = lambda_1 * Delta_beta_1 * Z_tilde_1 + lambda_2 * Delta_beta_2 * Z_tilde_2` (sum of per-endogenous terms), the induced coefficient change is:

```
(Z_tilde' Omega X1_tilde)^(-1) * [ lambda_1 * Delta_beta_1 * (Z_tilde' Omega Z_tilde_1)
                                 + lambda_2 * Delta_beta_2 * (Z_tilde' Omega Z_tilde_2) ]
```

The cross terms (off-diagonal entries of `Z_tilde' Omega Z_tilde`, and off-diagonal entries of the first-stage matrix `pi = (Z_tilde' Omega Z_tilde)^(-1) Z_tilde' Omega X1_tilde`) enter. In Autor's iv_gendershock, the male and female China-trade instruments are strongly correlated with one another but nearly symmetric in their residualized first stage (male shock loads on male endog, female shock loads on female endog, cross-loadings are small and symmetric), so the cross-term mis-scalings approximately cancel across the two endogenous updates. The system is effectively behaving as if pi_hat was the identity, which is exactly what the heuristic assumes.

In iv_mainshock (1x1), there is no second endogenous to absorb the pi_hat mis-scaling. The update applies a raw Z shift where a pi_hat * Z_tilde shift was needed, and the coefficient lands at `pi_hat^(-1) * Delta_beta` of the intended delta per iteration. For Autor's China-trade instrument pi_hat is roughly 0.55 (from the published first stages in ADH 2013 Table 3 column 2), so the adjuster moves the coefficient by about 0.55x the intended step per iteration. Combined with a 0.20 learning rate, effective per-iteration movement is about 0.11x intended, and 50 iterations can only cross about 5x the original delta, insufficient when the initial gap exceeds that.

This is consistent with the empirical pattern (1x1 FAIL at 0.55 to 2.00 SE; 2x2 PASS at near 0.00 SE).

**Conclusion on research question 2:** The conjecture is correct. The 2x2 case works by an accidental approximate cancellation of pi cross-terms in this specific replication; any 2x2 spec with strong cross-loadings or asymmetric first stages will fail the same way 1x1 does.

---

## 4. Analytic weights

Under `[aw=w]`, Stata normalizes `w_tilde_i = w_i * N / sum(w)` so that `sum(w_tilde) = N`, then uses the weighted moments. The correct perturbation under weights (eq. 5) is:

```
delta y_i = w_tilde_i^(-1) * Z_tilde_i * pi_hat * delta_beta_1
```

The `w_tilde_i^(-1)` pre-factor is load-bearing: observations with small weights need larger y shifts to produce the same weighted moment change. The current heuristic ignores weights entirely. For Autor `timepwt24` varies roughly by a factor of 10 across PUMA-by-year cells, so ignoring weights introduces up to a 10x mis-scaling per observation.

**Conclusion on research question 4:** Yes, scaling the update by `w_tilde_i^(-1)` (equivalently computing `Z_tilde_i` via a weighted residualization and the cross-moment ratios with Omega) recovers correctness. In iterative form it equals scaling the per-observation shift by `(sum w) / (N * w_i)`.

---

## 5. Literature

### 5.1 2SLS algebra and residualization (FWL for IV)

- **Angrist, J. D., and Pischke, J.-S. (2009).** *Mostly Harmless Econometrics.* Princeton. Ch. 4.1.2 (FWL for 2SLS), Ch. 4.6 (reduced-form interpretation beta_IV = rho / pi_hat). The reduced-form decomposition is exactly the scaling the heuristic is missing.
- **Wooldridge, J. M. (2010).** *Econometric Analysis of Cross Section and Panel Data.* 2nd ed. MIT Press. Ch. 5 (single-equation IV), Ch. 8.3 (system GMM and 2SLS as efficient GMM). Explicit treatment of analytic weights in Ch. 19.
- **Imbens, G. W., and Wooldridge, J. M. (2007).** "What's New in Econometrics: Lecture 5, Instrumental Variables with Treatment Effect Heterogeneity." NBER Summer Institute Methods Lectures. Modern 2SLS identification with controls and weights.
- **Baltagi, B. H. (2008).** *Econometrics.* 4th ed. Springer. Ch. 11 (FWL theorem for IV), with explicit derivation of M_W Z projection.
- **Frisch, R., and Waugh, F. V. (1933).** "Partial time regressions as compared with individual trends." *Econometrica* 1(4): 387-401. The original FWL reference.
- **Lovell, M. C. (1963).** "Seasonal adjustment of economic time series and multiple regression analysis." *JASA* 58(304): 993-1010. The L in FWL, extended to weighted and partialled regressions.

### 5.2 GMM foundation (over-identified case)

- **Hansen, L. P. (1982).** "Large sample properties of generalized method of moments estimators." *Econometrica* 50(4): 1029-1054. Foundational GMM reference; 2SLS is GMM with weight matrix `(Z' Omega Z)^(-1)`.
- **Newey, W. K., and McFadden, D. (1994).** "Large sample estimation and hypothesis testing." In *Handbook of Econometrics* Vol. 4, Ch. 36. Sec. 3 gives the GMM gradient and information matrix; eq. 6 in this doc is a direct specialization.

### 5.3 Weak instruments and ill-posed identification

- **Staiger, D., and Stock, J. H. (1997).** "Instrumental variables regression with weak instruments." *Econometrica* 65(3): 557-586. Concentration-parameter framework; pi_hat' Z' Z pi_hat / sigma_v^2 small implies beta_IV poorly identified and the Jacobian H in eq. 6 is near-singular.
- **Stock, J. H., and Yogo, M. (2005).** "Testing for weak instruments in linear IV regression." In *Identification and Inference for Econometric Models: Essays in Honor of Thomas Rothenberg.* Cambridge University Press. First-stage F > 10 rule of thumb for single-endogenous; Cragg-Donald >= Stock-Yogo critical values for multiple.
- **Lee, D. L., McCrary, J., Moreira, M. J., and Porter, J. (2022).** "Valid t-ratio inference for IV." *American Economic Review* 112(10): 3260-3290. Raises the F > 10 bar to roughly 104.7 for honest 5% coverage under heteroskedasticity. For our purpose the bar is lower: we only need the first-stage pi_hat to be numerically non-singular, not inference-valid.
- **Andrews, I., Stock, J. H., and Sun, L. (2019).** "Weak instruments in instrumental variables regression: theory and practice." *Annual Review of Economics* 11: 727-753. Current survey; maps the identification spectrum from under-identification (pi_hat rank-deficient, eq. 6 has no solution) through weak (eq. 6 solvable but ill-conditioned) to strong.
- **Cragg, J. G., and Donald, S. G. (1993).** "Testing identifiability and specification in instrumental variable models." *Econometric Theory* 9(2): 222-240. Rank test for multiple-endogenous identification.

**Detection criterion for "can't match":** first-stage F (Kleibergen-Paap rk Wald under clustering) below roughly 4. At F in [4, 10] the adjuster can still move beta_hat but convergence slows and per-iteration noise in pi_hat makes the Newton step unstable; report as "weak identification, best-effort". Above 10, eq. 5 or eq. 6 converge in one step up to `O(1/N)`.

### 5.4 Matching moments and inverse estimation

- **Gourieroux, C., Monfort, A., and Renault, E. (1993).** "Indirect inference." *Journal of Applied Econometrics* 8: S85-S118. Inverse-estimation framework: given a target estimator output, find DGP parameters. The mirror direction of what datamirror does, but the Jacobian machinery is identical.
- **Gaffke, N., Keith, T., and Mokhlesian, M. (2016).** "A moment matching approach for generating synthetic data." *Big Data* 4(3). Moment-matching synthesis via pseudoinverse on linear moment systems. Eq. 4 in this doc is exactly that construction applied to 2SLS moments.
- **Reiter, J. P. (2005).** "Releasing multiply imputed, synthetic public use microdata." *JRSS-A* 168(1): 185-205. Posterior-predictive synthesis preserves coefficients in expectation but does not pin them. IV is not treated; MI draws are conditional on the fitted reduced form, so beta_IV emerges but is not targeted.
- **Drechsler, J. (2011).** *Synthetic Datasets for Statistical Disclosure Control.* Springer. Comprehensive treatment of MI-based synthesis; IV not covered as a special case (treated as OLS-like on the reduced form).
- **Snoke, J., Raab, G. M., Nowok, B., Dibben, C., and Slavkovic, A. (2018).** "General and specific utility measures for synthetic data." *JRSS-A* 181(3): 663-688. Coefficient-recovery evaluation; IV not benchmarked.
- **Raghunathan, T. E., Reiter, J. P., and Rubin, D. B. (2003).** "Multiple imputation for statistical disclosure limitation." *Journal of Official Statistics* 19(1): 1-16. The MI-synthesis paradigm; IV is mentioned in passing as an analyst-side estimator but not preserved by construction.

### 5.5 Differential privacy and 2SLS

- **Cai, T. T., Wang, Y., and Zhang, L. (2021).** "The cost of privacy: Optimal rates of convergence for parameter estimation with differential privacy." *Annals of Statistics* 49(5): 2825-2850. Linear regression under DP; no 2SLS extension.
- **Ferrando, C., Wang, S., and Sheldon, D. (2022).** "Parametric bootstrap for differentially private confidence intervals." *AISTATS 2022.* DP inference for GLMs; IV again not special-cased.
- **Alabi, D., McMillan, A., Sarathy, J., Smith, A., and Vadhan, S. (2022).** "Differentially Private Simple Linear Regression." *PETS 2022.* Closest DP treatment of linear-IV-shaped estimators; still does not solve the inverse-2SLS problem.

### 5.6 Inverse 2SLS specifically

A systematic search (Google Scholar, IDEAS/RePEc, arXiv) for "inverse 2SLS", "synthetic IV data", "coefficient-targeted instrumental variables", and "plasmode IV" returns zero papers that solve the inverse problem: given beta*_IV, produce (X, Z, y) such that `ivregress 2sls y (X = Z) on this data returns beta*_IV`. Plasmode IV simulations (e.g., Burgess and Thompson 2013 in Mendelian randomization) sample y from a structural model given fixed X and Z, which preserves beta_IV in expectation but not exactly. This is the same gap NBREG sat in before the DGP-sampling decision.

Unlike nbreg, direct DGP sampling is **not** available for 2SLS coefficient pinning: the 2SLS estimator is consistent for the structural parameter beta under the exclusion restriction, but finite-sample beta_hat has sampling noise of order `sigma_u / pi / sqrt(N)` which is non-trivial at Autor sample sizes (N ~ 1500, first-stage F not astronomical). Sampling y from `y = X beta* + u` with `u` independent of Z would produce `E[beta_hat] = beta*` but realized `beta_hat` off by one SE, which is the Delta/SE < 2 bar we want to clear but does not fully close the gap. Eq. 5 pushes the realized beta_hat onto beta* exactly, up to floating-point precision, within one Newton step. That is strictly tighter than plasmode-style DGP sampling for the pinning use case.

---

## 6. Proposed algorithm

Stata-friendly pseudocode for the Newton-step joint-gradient adjuster. Handles just-identified and over-identified, with controls and analytic weights.

```
program _dm_constrain_iv_newton
    args cmdline targets ses varnames depvar max_iter tolerance learning_rate

    * Parse ivregress syntax: extract
    *   depvar       = "y"
    *   X1 (endog)   = words inside "(...= ...)", before "="
    *   Z  (inst)    = words inside "(...= ...)", after  "="
    *   W  (exog)    = outside parens (controls + constant)
    *   weight_type  = "aw" | "pw" | "fw" | ""
    *   weight_var   = variable name
    *   touse        = estimation sample indicator

    forval iter = 1/`max_iter' {
        * (a) Fit current-iteration 2SLS on (X_syn, y_syn)
        qui `cmdline'
        matrix b_hat = e(b)

        * (b) Extract Delta_beta for endogenous block only
        *     (eq. 1 says controls move as a by-product; we do not target them.)
        matrix Delta_beta = endog_targets - endog_b_hat            // k x 1

        * (c) Residualize Z and X1 against W under weights
        *     Run `regress Z_j W [aw=weight] if touse` for each Z_j, save residuals Z_tilde_j
        *     Run `regress X1_j W [aw=weight] if touse` for each X1_j, save residuals X1_tilde_j

        * (d) Build Gram / cross-moment matrices (weighted)
        *     Omega_diag = weight_var / (sum of weight_var) * N        (normalized aweights)
        matrix ZtZ   = Z_tilde'  * Omega * Z_tilde                // m x m
        matrix ZtX1  = Z_tilde'  * Omega * X1_tilde               // m x k
        matrix X1tZ  = ZtX1'                                      // k x m

        * (e) Compute the Jacobian H = d beta_1_hat / d y_tilde  (k x N)
        if (m == k) {
            * Just-identified: H = (Z_tilde' Omega X1_tilde)^{-1} Z_tilde' Omega
            matrix H = invsym(ZtX1) * Z_tilde' * Omega
        }
        else {
            * Over-identified GMM: H = (X1tZ * ZtZ^-1 * ZtX1)^-1 * X1tZ * ZtZ^-1 * Z_tilde' * Omega
            matrix ZtZ_inv = invsym(ZtZ)
            matrix H = invsym(X1tZ * ZtZ_inv * ZtX1) * X1tZ * ZtZ_inv * Z_tilde' * Omega
        }

        * (f) Minimum-norm delta_y  (eq. 4 / eq. 6)
        *     delta_y_tilde = H' * (H H')^-1 * Delta_beta        (N x 1)
        *     delta_y       = Omega^-1 * M_W' * delta_y_tilde   (transpose of projector returns to original y-space)
        matrix HHt        = H * H'                                // k x k
        matrix dy_tilde   = H' * invsym(HHt) * Delta_beta        // N x 1
        tempvar dy
        gen double `dy'   = (element of dy_tilde)
        * Unpartial W: in code this is done by residualizing dy against W with weights and
        * keeping the residual OR by recognizing M_W' Omega = Omega M_W so the update through
        * `replace y = y + dy_tilde / w_i` hits Z_tilde' Omega dy = Delta_beta exactly.
        qui replace `depvar' = `depvar' + `learning_rate' * `dy' / `weight_var' if `touse'

        * (g) Convergence check
        if max(abs(Delta_beta) :/ endog_ses) < tolerance {
            continue, break
        }
    }

    * (h) Report
    *     - final max Delta/SE on endogenous coefficients
    *     - first-stage Kleibergen-Paap rk Wald F (weak-ID diagnostic)
    *     - warn if pi_hat (first-stage) is ill-conditioned: condition number > 1e6
end
```

Notes on the pseudocode:

- Step (c) residualization is done once per iteration, not per endogenous, by a block `regress ... [aw=w]` over all Z and X1 columns simultaneously. Stata's `matrix accum` handles the weighted cross-moments.
- Step (f) minimum-norm solution with `learning_rate` of 1.0 should converge in one step for linear models up to `O(1/N)`; retained as a tunable for ill-conditioned cases where a full Newton step overshoots.
- Step (h) first-stage F below 4 triggers a "weak identification; coefficient-pinning not guaranteed" warning, logged to `outbox/checkpoints.csv` as a fidelity caveat (same pattern as the nbreg high-alpha warning).

### Scalar case simplification

For k = m = 1 the pseudocode collapses to:

```
pi_hat  = sum(w_i * Z_tilde_i * X1_tilde_i) / sum(w_i * Z_tilde_i * Z_tilde_i)    // first-stage slope
delta_y_i = Delta_beta * Z_tilde_i * pi_hat / ( sum(w_j * Z_tilde_j^2) * w_i / N )
replace y = y + delta_y
```

This is the corrected version of the current heuristic: the correction factor is `pi_hat * N / (w_i * sum(w_j * Z_tilde_j^2))`, not the raw constant `0.20` learning rate.

---

## 7. Scope and known limits

### Inside scope for v1.0

- Just-identified 2SLS with k endogenous and m = k instruments; continuous outcome; analytic weights; exogenous controls; cluster-robust SE for convergence metric (not for beta update).
- Over-identified 2SLS via eq. 6. The Autor replication does not exercise this path but the algebra is symmetric.
- Stata's `ivregress 2sls`. `ivreg2` (Baum, Schaffer, Stillman 2007) uses the same estimator; the adjuster is drop-in compatible.

### Explicitly out of scope

- **LIML (limited-information maximum likelihood).** The `ivregress liml` estimator has a different Jacobian (k-class with estimated k). Deferred.
- **GMM with non-default weight matrix.** `ivregress gmm` with `wmatrix(cluster ...)` or two-step GMM uses a different `(Z_tilde' Omega_hat Z_tilde)^{-1}` where `Omega_hat` depends on first-stage residuals. Eq. 6 still applies with that weight matrix substituted; implementation deferred until a replication demands it.
- **Non-linear IV / control-function.** `ivpoisson`, `ivprobit`, `eivreg`, generalized method of moments with non-linear moments. These combine the IV Jacobian with a non-linear link; inherits the nbreg/logit DGP-sampling story but with a structural equation on the structural error. Deferred.
- **Cluster-robust variance for SE threshold.** The adjuster respects `cluster()` only for convergence-metric purposes (SE used in Delta/SE). The update direction itself uses `Omega = diag(w)`, not a cluster-adjusted weight. This is correct: the estimator beta_hat does not depend on the clustering structure, only its standard error does.

### Structural limits (research question 6)

The Newton step eq. 6 has no solution (or an unstable solution) in three regimes:

1. **Under-identification.** `pi_hat = (Z_tilde' Omega Z_tilde)^(-1) Z_tilde' Omega X1_tilde` has rank less than k. The cross-moment matrix `X1tZ * ZtZ_inv * ZtX1` is singular; `invsym` returns a generalized inverse and the adjuster produces a `delta_y` that does not actually move beta_hat. Detection: Cragg-Donald rk Wald statistic below the chi-square(k-m+1) critical value.
2. **Weak identification.** `pi_hat` has full rank but small singular values (first-stage F < 4 for k = 1, or Cragg-Donald below the Stock-Yogo critical). The Jacobian is well-defined but ill-conditioned; small measurement noise in X_syn causes large movement in delta_y. Detection: condition number of `X1tZ * ZtZ_inv * ZtX1` above 1e6, or first-stage F below 4. Action: warn and allow the learning_rate < 1 damping to compensate; convergence may take more iterations but does complete.
3. **Near-collinear instruments (m > k).** `Z_tilde' Omega Z_tilde` has small eigenvalues; `ZtZ_inv` amplifies noise. Detection: condition number of `ZtZ` above 1e8. Action: switch to singular-value-truncated pseudoinverse (drop directions with singular values below a threshold); this is equivalent to re-reducing to the just-identified case on the strong-instrument subspace.

All three are diagnosable before running the adjuster. In v1.0 the adjuster computes the diagnostic in step (a) and emits a warning plus an explicit "fidelity not guaranteed" flag in `outbox/checkpoints.csv`. This matches the nbreg high-alpha and logit separation safeguards.

---

## 8. Recommendation

**Implement eq. 5 / eq. 6 as the Newton-step adjuster for v1.0.** Specifically:

1. **Rewrite `_dm_constrain_iv`** in `stata/src/_dm_constraints.ado` to follow the pseudocode in section 6. Delete the `iv_lr = 0.20` constant and the cross-term heuristic; replace with the residualization + Gram + projector pipeline.
2. **Scalar and vector cases in one code path.** The just-identified branch (m == k) and over-identified branch (m > k) share the same structure; differ only in the H expression in step (e).
3. **Analytic weights first-class.** Parse `[aw=...]` / `[pw=...]` from the cmdline and thread the normalized `Omega_diag` through all matrix operations. Without weights the adjuster passes `Omega = I/N`.
4. **Diagnostics.** First-stage F (Kleibergen-Paap under clustering, regular F otherwise), condition number of `X1tZ * ZtZ_inv * ZtX1`, Cragg-Donald for identification. Emit a warning but do not abort when thresholds are crossed.
5. **Validation.** Re-run `replication/004_autor_dorn_hanson_2019` end-to-end. Expected: iv_mainshock (1x1) passes at Delta/SE < 0.1; iv_gendershock (2x2) continues to pass; overall Autor fail rate drops from 55.6% toward 0 on IV specs (other failures outside IV are separate).
6. **Unit test.** Add `test_iv_basic.do` subtests covering: (i) 1x1 no controls no weights, (ii) 1x1 with controls with aweights, (iii) 2x2 just-identified with controls, (iv) 2x2 over-identified (3 instruments for 2 endogenous), (v) weak-instrument regime (F < 4) with pass-through to "best effort" flag. Assert Delta/SE < 0.5 on strong-ID cases, < 2 on weak-ID.

**Why not (a) ship-as-is with documented 1x1 limit:** The 1x1 case is the most common IV spec in empirical economics. Documenting 55% failure on the main use case is not shippable under a methods-paper standard ("Here we present a principled method"). The fix is algebraic, not empirical; Section 2 derives it in closed form. There is no rationale for shipping a broken scalar case when the correct update rule is eq. 5.

**Why not (c) perturb X instead of Y:** Symmetric: eq. 3 applied to X1 instead of y gives `delta_beta_1 = -(Z_tilde' Omega X1_tilde)^(-2) (Z_tilde' Omega delta X1) * (Z_tilde' Omega y_tilde)`, which is structurally worse because it couples the target to the current y through the numerator and thereby propagates sampling noise in y into the Jacobian. Perturbing y while holding X fixed is the correct choice: it leaves the first stage (pi_hat on residualized instruments) invariant, which is both the identification content of IV and what reviewers will stress-test.

**Why not direct DGP sampling (the nbreg / logit analog):** For 2SLS, sampling `y = X1 beta_1* + X2 beta_2* + u` with `u` drawn independent of Z produces `E[beta_hat] = beta*` but finite-sample `beta_hat` has noise of order `sigma_u / (pi_hat * sqrt(N))`. At Autor sample sizes with published first-stage F roughly 50 and sigma_u on the order of the outcome SD, that noise is of order 0.5 to 1 SE of the published beta. The Δ/SE < 2 bar is met in expectation but the realized beta on any single dataset lands somewhere on the sampling distribution, not at beta*. Eq. 5 pins beta_hat at beta* exactly (up to floating-point precision) in a single Newton step, which is strictly tighter than plasmode-style DGP sampling for the coefficient-preservation contract.

The nbreg DGP-sampling decision is correct for nbreg because nbreg's *iterative* approach hits structural MLE walls (score non-orthogonality, boundary non-existence) that one-shot sampling avoids. IV has no such walls: the estimator is closed-form linear, the Jacobian is analytic, the Newton step converges in one iteration up to `O(1/N)`. IV's path is the other direction: ship the analytically correct Newton step, not a DGP sampler.

---

## Implementation location

`stata/src/_dm_constraints.ado` -> replace `_dm_constrain_iv` (lines 763 to 947) with the Newton-step body. `_dm_constrain_nonlinear` dependency already removed in the binary-DGP decision. Parsing of `cmdline` for the weight clause should be lifted into a small helper (`_dm_parse_weights`) since the FE and OLS adjusters will eventually need the same code path for weight-aware updates. Cross-checkpoint reconciliation (one IV and one OLS sharing a predictor) uses the existing three-pass dispatcher in `_dm_apply_checkpoint_constraints`; no changes required there.

## Lesson for the project

The 1x1 vs 2x2 puzzle is the second instance (after nbreg Delta_beta freezing) where a Layer-4 heuristic passed harder tests while failing easier ones. The pattern in both cases is the same: the heuristic happens to approximate a closed-form operator on the more complex case via symmetric cancellation, while degrading gracefully on the simple case to something visibly off-target. When a Layer-4 adjuster inverts the expected difficulty ordering, the first-order explanation is that the scalar estimator exposes a mis-scaling that the matrix estimator hides via cross-term structure. Inspect the analytic Jacobian before tuning the learning rate.
