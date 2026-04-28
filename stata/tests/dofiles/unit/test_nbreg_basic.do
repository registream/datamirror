* =============================================================================
* Test: Negative Binomial Basic - Layer 4 checkpoint constraints for nbreg models
* Purpose: Test nbreg coefficient recovery with overdispersed count data.
* Method: Δβ/SE < 3 (inferential fidelity; synthetic β̂ within 3 SE of target).
*         Layer 4 for nbreg uses direct Gamma-Poisson DGP sampling (see
*         docs/NBREG_DGP_DECISION.md), which gives O(1/√N) sampling noise;
*         a fixed point-estimate threshold (e.g. Δβ < 0.05) is noisy on
*         finite samples and the Δβ/SE metric is the principled check.
* =============================================================================

clear all
set more off
set seed 12345

* Add DataMirror to path
adopath ++ "stata/src"
adopath ++ "../registream/stata/src"

di as text ""
di as text "=========================================="
di as text "Test: Negative Binomial Basic"
di as text "=========================================="
di as text ""

* -----------------------------------------------------------------------------
* Test 1: Simple Count Outcome with Continuous Predictors
* -----------------------------------------------------------------------------

di as text "Test 1: Simple negative binomial with continuous predictors"
di as text "----------------------------------------------------------"

clear
set obs 1000

* Generate predictors
gen x1 = rnormal(0, 1)
gen x2 = rnormal(0, 1.5)

* Generate count outcome from negative binomial model
* True coefficients: intercept = 0.5, x1 = 0.3, x2 = -0.2
gen xb = 0.5 + 0.3*x1 - 0.2*x2
gen mu = exp(xb)
* Generate overdispersed counts (dispersion parameter α ≈ 0.5)
gen y = rnbinomial(mu, 0.5)

* Drop intermediate variables (not part of final dataset)
drop xb mu

* Summary statistics
di as text ""
di as text "Data summary:"
sum y x1 x2
di as text "Mean count: " %5.3f r(mean)

* Fit original model
di as text ""
di as text "Original negative binomial model:"
nbreg y x1 x2
matrix b_orig = e(b)

* Store original coefficients
local b_x1_orig = _b[x1]
local b_x2_orig = _b[x2]
local b_cons_orig = _b[_cons]

di as text ""
di as text "Original coefficients:"
di as text "  x1:    " %8.4f `b_x1_orig'
di as text "  x2:    " %8.4f `b_x2_orig'
di as text "  _cons: " %8.4f `b_cons_orig'

* Initialize DataMirror
local outdir "stata/tests/output/test_nbreg_basic/test1"
cap mkdir "stata/tests/output"
cap mkdir "stata/tests/output/test_nbreg_basic"
cap mkdir "`outdir'"

datamirror init, checkpoint_dir("`outdir'") replace

* Checkpoint the model
nbreg y x1 x2
datamirror checkpoint, tag("nbreg_simple")

* Extract metadata
di as text ""
di as text "Extracting metadata..."
datamirror extract, replace

* Rebuild synthetic data
di as text ""
di as text "Rebuilding synthetic data..."
datamirror rebuild using "`outdir'", clear seed(99999)

di as text ""
di as text "Synthetic data summary:"
sum y x1 x2

* Re-run model on synthetic data
di as text ""
di as text "Synthetic negative binomial model:"
nbreg y x1 x2
matrix b_synth = e(b)

* Compare coefficients using Δβ/SE (inferential fidelity): synthetic β̂
* is within ~2 standard errors of the target. Point-estimate Δβ alone
* is a noisy criterion for finite-N count data; Δβ/SE scales with the
* estimator's own precision and is the natural "statistically
* indistinguishable" check.
local b_x1_synth = _b[x1]
local b_x2_synth = _b[x2]
local b_cons_synth = _b[_cons]

local se_x1_synth = _se[x1]
local se_x2_synth = _se[x2]
local se_cons_synth = _se[_cons]

local delta_x1 = abs(`b_x1_synth' - `b_x1_orig')
local delta_x2 = abs(`b_x2_synth' - `b_x2_orig')
local delta_cons = abs(`b_cons_synth' - `b_cons_orig')

local dse_x1 = `delta_x1' / `se_x1_synth'
local dse_x2 = `delta_x2' / `se_x2_synth'
local dse_cons = `delta_cons' / `se_cons_synth'

di as text ""
di as text "Coefficient comparison:"
di as text "  Variable    Original    Synthetic       Δ      Δ/SE"
di as text "  ----------------------------------------------------------"
di as text "  x1       " %10.4f `b_x1_orig' "  " %10.4f `b_x1_synth' "  " %8.4f `delta_x1' "  " %6.3f `dse_x1'
di as text "  x2       " %10.4f `b_x2_orig' "  " %10.4f `b_x2_synth' "  " %8.4f `delta_x2' "  " %6.3f `dse_x2'
di as text "  _cons    " %10.4f `b_cons_orig' "  " %10.4f `b_cons_synth' "  " %8.4f `delta_cons' "  " %6.3f `dse_cons'

local max_dse_cont = max(`dse_x1', `dse_x2')
local max_dse_all = max(`dse_x1', `dse_x2', `dse_cons')
di as text "  ----------------------------------------------------------"
di as text "  Max Δβ/SE (continuous): " %6.3f `max_dse_cont'
di as text "  Max Δβ/SE (with _cons): " %6.3f `max_dse_all'

* Test assertion: all coefficients within 3 SE of target.
if `max_dse_all' < 3.0 {
    di as result "  ✓ PASS (all Δβ/SE < 3)"
    local test1_pass = 1
}
else {
    di as error "  ✗ FAIL (some Δβ/SE ≥ 3)"
    local test1_pass = 0
}

* -----------------------------------------------------------------------------
* Test 2: Count Outcome with Factor Variables
* -----------------------------------------------------------------------------

di as text ""
di as text ""
di as text "Test 2: Negative binomial with factor variables"
di as text "----------------------------------------------------------"

clear
set obs 1000
set seed 54321

* Generate predictors
gen x1 = rnormal(0, 1)
gen treatment = floor(runiform()*3) + 1  // 1, 2, 3

* Generate outcome with treatment effects
* True: base=1, level2=+0.3, level3=+0.5
gen xb = 0.8 + 0.25*x1
replace xb = xb + 0.3 if treatment == 2
replace xb = xb + 0.5 if treatment == 3
gen mu = exp(xb)
gen y = rnbinomial(mu, 0.5)

* Drop intermediate variables
drop xb mu

* Summary
di as text ""
di as text "Data summary:"
sum y x1
tab treatment

* Fit original model
di as text ""
di as text "Original negative binomial model:"
nbreg y x1 i.treatment
matrix b_orig = e(b)

* Store coefficients
local b_x1_orig = _b[x1]
local b_trt2_orig = _b[2.treatment]
local b_trt3_orig = _b[3.treatment]
local b_cons_orig = _b[_cons]

di as text ""
di as text "Original coefficients:"
di as text "  x1:          " %8.4f `b_x1_orig'
di as text "  2.treatment: " %8.4f `b_trt2_orig'
di as text "  3.treatment: " %8.4f `b_trt3_orig'
di as text "  _cons:       " %8.4f `b_cons_orig'

* Initialize DataMirror
local outdir "stata/tests/output/test_nbreg_basic/test2"
cap mkdir "`outdir'"

datamirror init, checkpoint_dir("`outdir'") replace

* Checkpoint
nbreg y x1 i.treatment
datamirror checkpoint, tag("nbreg_factor")

* Extract and rebuild
di as text ""
di as text "Extracting and rebuilding..."
datamirror extract, replace
datamirror rebuild using "`outdir'", clear seed(88888)

* Re-run on synthetic
di as text ""
di as text "Synthetic negative binomial model:"
nbreg y x1 i.treatment

* Compare using Δβ/SE (inferential fidelity, within 3 SE of target).
local b_x1_synth = _b[x1]
local b_trt2_synth = _b[2.treatment]
local b_trt3_synth = _b[3.treatment]
local b_cons_synth = _b[_cons]

local se_x1_synth = _se[x1]
local se_trt2_synth = _se[2.treatment]
local se_trt3_synth = _se[3.treatment]
local se_cons_synth = _se[_cons]

local delta_x1 = abs(`b_x1_synth' - `b_x1_orig')
local delta_trt2 = abs(`b_trt2_synth' - `b_trt2_orig')
local delta_trt3 = abs(`b_trt3_synth' - `b_trt3_orig')
local delta_cons = abs(`b_cons_synth' - `b_cons_orig')

local dse_x1 = `delta_x1' / `se_x1_synth'
local dse_trt2 = `delta_trt2' / `se_trt2_synth'
local dse_trt3 = `delta_trt3' / `se_trt3_synth'
local dse_cons = `delta_cons' / `se_cons_synth'

di as text ""
di as text "Coefficient comparison:"
di as text "  Variable      Original    Synthetic       Δ      Δ/SE"
di as text "  --------------------------------------------------------"
di as text "  x1         " %10.4f `b_x1_orig' "  " %10.4f `b_x1_synth' "  " %8.4f `delta_x1' "  " %6.3f `dse_x1'
di as text "  2.treatment" %10.4f `b_trt2_orig' "  " %10.4f `b_trt2_synth' "  " %8.4f `delta_trt2' "  " %6.3f `dse_trt2'
di as text "  3.treatment" %10.4f `b_trt3_orig' "  " %10.4f `b_trt3_synth' "  " %8.4f `delta_trt3' "  " %6.3f `dse_trt3'
di as text "  _cons      " %10.4f `b_cons_orig' "  " %10.4f `b_cons_synth' "  " %8.4f `delta_cons' "  " %6.3f `dse_cons'

local max_dse_cont = `dse_x1'
local max_dse_factor = max(`dse_trt2', `dse_trt3')
local max_dse_all = max(`dse_x1', `dse_trt2', `dse_trt3', `dse_cons')
di as text "  --------------------------------------------------------"
di as text "  Max Δβ/SE (continuous): " %6.3f `max_dse_cont'
di as text "  Max Δβ/SE (factors):    " %6.3f `max_dse_factor'
di as text "  Max Δβ/SE (with _cons): " %6.3f `max_dse_all'

* With DGP sampling (Gamma-Poisson mixture at target β*, α*), all
* coefficients — continuous AND factor — should land within ~2 SE
* of target. Factors are no longer a "cannot adjust" limitation:
* they're sampled from the target DGP like everything else.
if `max_dse_all' < 3.0 {
    di as result "  ✓ PASS (all Δβ/SE < 3)"
    local test2_pass = 1
}
else {
    di as error "  ✗ FAIL (some Δβ/SE ≥ 3)"
    local test2_pass = 0
}

* -----------------------------------------------------------------------------
* Test 3: Multiple Predictors
* -----------------------------------------------------------------------------

di as text ""
di as text ""
di as text "Test 3: Negative binomial with multiple continuous predictors"
di as text "----------------------------------------------------------"

clear
set obs 1500
set seed 11111

* Generate 5 predictors
gen x1 = rnormal(0, 1)
gen x2 = rnormal(0, 1.2)
gen x3 = rnormal(0, 0.8)
gen x4 = rnormal(0, 1.5)
gen x5 = rnormal(0, 0.9)

* Generate outcome
gen xb = 0.3 + 0.25*x1 - 0.15*x2 + 0.1*x3 - 0.2*x4 + 0.3*x5
gen mu = exp(xb)
gen y = rnbinomial(mu, 0.5)

* Drop intermediate variables
drop xb mu

* Fit original
di as text ""
di as text "Original negative binomial model (5 predictors):"
nbreg y x1 x2 x3 x4 x5

* Store coefficients
forval i = 1/5 {
    local b_x`i'_orig = _b[x`i']
}
local b_cons_orig = _b[_cons]

* DataMirror workflow
local outdir "stata/tests/output/test_nbreg_basic/test3"
cap mkdir "`outdir'"

datamirror init, checkpoint_dir("`outdir'") replace
nbreg y x1 x2 x3 x4 x5
datamirror checkpoint, tag("nbreg_multi")

datamirror extract, replace
datamirror rebuild using "`outdir'", clear seed(77777)

* Re-run
di as text ""
di as text "Synthetic negative binomial model:"
nbreg y x1 x2 x3 x4 x5

* Compare using Δβ/SE (inferential fidelity, within 3 SE of target).
di as text ""
di as text "Coefficient comparison:"
di as text "  Variable    Original    Synthetic       Δ      Δ/SE"
di as text "  ----------------------------------------------------------"

local max_dse_cont = 0
forval i = 1/5 {
    local b_x`i'_synth = _b[x`i']
    local se_x`i'_synth = _se[x`i']
    local delta_x`i' = abs(`b_x`i'_synth' - `b_x`i'_orig')
    local dse_x`i' = `delta_x`i'' / `se_x`i'_synth'
    di as text "  x`i'      " %10.4f `b_x`i'_orig' "  " %10.4f `b_x`i'_synth' "  " %8.4f `delta_x`i'' "  " %6.3f `dse_x`i''
    if `dse_x`i'' > `max_dse_cont' {
        local max_dse_cont = `dse_x`i''
    }
}

local b_cons_synth = _b[_cons]
local se_cons_synth = _se[_cons]
local delta_cons = abs(`b_cons_synth' - `b_cons_orig')
local dse_cons = `delta_cons' / `se_cons_synth'
di as text "  _cons    " %10.4f `b_cons_orig' "  " %10.4f `b_cons_synth' "  " %8.4f `delta_cons' "  " %6.3f `dse_cons'

local max_dse_all = max(`max_dse_cont', `dse_cons')

di as text "  ----------------------------------------------------------"
di as text "  Max Δβ/SE (continuous only): " %6.3f `max_dse_cont'
di as text "  Intercept Δβ/SE:             " %6.3f `dse_cons'
di as text "  Max Δβ/SE (with intercept):  " %6.3f `max_dse_all'

if `max_dse_all' < 3.0 {
    di as result "  ✓ PASS (all Δβ/SE < 3)"
    local test3_pass = 1
}
else {
    di as error "  ✗ FAIL (some Δβ/SE ≥ 3)"
    local test3_pass = 0
}

* -----------------------------------------------------------------------------
* Final Summary
* -----------------------------------------------------------------------------

di as text ""
di as text ""
di as text "=========================================="
di as text "Test Summary: Negative Binomial Basic"
di as text "=========================================="
di as text ""
di as text "Test 1 (Simple):        " cond(`test1_pass', "✓ PASS", "✗ FAIL")
di as text "Test 2 (Factors):       " cond(`test2_pass', "✓ PASS", "✗ FAIL")
di as text "Test 3 (Multiple):      " cond(`test3_pass', "✓ PASS", "✗ FAIL")
di as text ""

local all_pass = `test1_pass' & `test2_pass' & `test3_pass'

if `all_pass' {
    di as result "=========================================="
    di as result "ALL TESTS PASSED ✓"
    di as result "=========================================="
    exit 0
}
else {
    di as error "=========================================="
    di as error "SOME TESTS FAILED ✗"
    di as error "=========================================="
    exit 1
}
