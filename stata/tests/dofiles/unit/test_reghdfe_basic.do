* =============================================================================
* Test: reghdfe Basic - Layer 4 checkpoint constraints for fixed effects
* Purpose: Test reghdfe coefficient matching with synthetic data
* Method: Δβ/SE < 3 (inferential fidelity; synthetic β̂ within 3 SE of target).
* =============================================================================

clear all
set more off
set seed 12345

* Add DataMirror to path
adopath ++ "stata/src"
adopath ++ "../registream/stata/src"

di as text ""
di as text "=========================================="
di as text "Test: reghdfe Basic"
di as text "=========================================="
di as text ""

* -----------------------------------------------------------------------------
* Test 1: Simple FE with Individual Effects
* -----------------------------------------------------------------------------

di as text "Test 1: reghdfe with individual fixed effects"
di as text "----------------------------------------------------------"

clear
set obs 50
gen id = _n

* Expand to create panel (10 periods per individual)
expand 10
bysort id: gen t = _n

* Generate predictors
gen x1 = rnormal(0, 1)
gen x2 = rnormal(0, 1.5)

* Generate individual fixed effects
gen alpha_i = rnormal(0, 2)
by id: replace alpha_i = alpha_i[1]

* Generate outcome
* True coefficients: x1 = 1.5, x2 = -0.8
gen y = alpha_i + 1.5*x1 - 0.8*x2 + rnormal(0, 1)

* Summary statistics
di as text ""
di as text "Data summary:"
sum y x1 x2

* Fit original model
di as text ""
di as text "Original reghdfe model:"
reghdfe y x1 x2, absorb(id) nocons

* Store original coefficients
local b_x1_orig = _b[x1]
local b_x2_orig = _b[x2]

di as text ""
di as text "Original coefficients:"
di as text "  x1: " %8.4f `b_x1_orig'
di as text "  x2: " %8.4f `b_x2_orig'

* Initialize DataMirror
local outdir "stata/tests/output/test_reghdfe_basic/test1"
cap mkdir "stata/tests/output"
cap mkdir "stata/tests/output/test_reghdfe_basic"
cap mkdir "`outdir'"

datamirror init, checkpoint_dir("`outdir'") replace

* Checkpoint the model
reghdfe y x1 x2, absorb(id) nocons
datamirror checkpoint, tag("reghdfe_simple")

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
di as text "Synthetic reghdfe model:"
reghdfe y x1 x2, absorb(id) nocons

* Compare coefficients using Δβ/SE (inferential fidelity).
local b_x1_synth = _b[x1]
local b_x2_synth = _b[x2]

local se_x1_synth = _se[x1]
local se_x2_synth = _se[x2]

local delta_x1 = abs(`b_x1_synth' - `b_x1_orig')
local delta_x2 = abs(`b_x2_synth' - `b_x2_orig')

local dse_x1 = `delta_x1' / `se_x1_synth'
local dse_x2 = `delta_x2' / `se_x2_synth'

di as text ""
di as text "Coefficient comparison:"
di as text "  Variable    Original    Synthetic       Δ      Δ/SE"
di as text "  ----------------------------------------------------------"
di as text "  x1       " %10.4f `b_x1_orig' "  " %10.4f `b_x1_synth' "  " %8.4f `delta_x1' "  " %6.3f `dse_x1'
di as text "  x2       " %10.4f `b_x2_orig' "  " %10.4f `b_x2_synth' "  " %8.4f `delta_x2' "  " %6.3f `dse_x2'

local max_dse_all = max(`dse_x1', `dse_x2')
di as text "  ----------------------------------------------------------"
di as text "  Max Δβ/SE: " %6.3f `max_dse_all'

* Test assertion: all slopes within 3 SE of target.
if `max_dse_all' < 3.0 {
    di as result "  ✓ PASS (all Δβ/SE < 3)"
    local test1_pass = 1
}
else {
    di as error "  ✗ FAIL (some Δβ/SE ≥ 3)"
    local test1_pass = 0
}

* -----------------------------------------------------------------------------
* Test 2: reghdfe with Two Predictors
* -----------------------------------------------------------------------------

di as text ""
di as text ""
di as text "Test 2: reghdfe with two predictors"
di as text "----------------------------------------------------------"

clear
set obs 40
gen id = _n
expand 10
bysort id: gen t = _n
set seed 54321

* Generate predictors
gen x1 = rnormal(0, 1)
gen x2 = rnormal(0, 1.5)

* Generate individual fixed effects
gen alpha_i = rnormal(0, 2)
by id: replace alpha_i = alpha_i[1]

* Generate outcome
* True: x1=1.0, x2=-0.6
gen y = alpha_i + 1.0*x1 - 0.6*x2 + rnormal(0, 1)

* Summary
di as text ""
di as text "Data summary:"
sum y x1 x2

* Fit original model
di as text ""
di as text "Original reghdfe model:"
reghdfe y x1 x2, absorb(id) nocons

* Store coefficients
local b_x1_orig = _b[x1]
local b_x2_orig = _b[x2]

di as text ""
di as text "Original coefficients:"
di as text "  x1: " %8.4f `b_x1_orig'
di as text "  x2: " %8.4f `b_x2_orig'

* Initialize DataMirror
local outdir "stata/tests/output/test_reghdfe_basic/test2"
cap mkdir "`outdir'"

datamirror init, checkpoint_dir("`outdir'") replace

* Checkpoint
reghdfe y x1 x2, absorb(id) nocons
datamirror checkpoint, tag("reghdfe_two_pred")

* Extract and rebuild
di as text ""
di as text "Extracting and rebuilding..."
datamirror extract, replace
datamirror rebuild using "`outdir'", clear seed(88888)

* Re-run on synthetic
di as text ""
di as text "Synthetic reghdfe model:"
reghdfe y x1 x2, absorb(id) nocons

* Compare using Δβ/SE (inferential fidelity).
local b_x1_synth = _b[x1]
local b_x2_synth = _b[x2]

local se_x1_synth = _se[x1]
local se_x2_synth = _se[x2]

local delta_x1 = abs(`b_x1_synth' - `b_x1_orig')
local delta_x2 = abs(`b_x2_synth' - `b_x2_orig')

local dse_x1 = `delta_x1' / `se_x1_synth'
local dse_x2 = `delta_x2' / `se_x2_synth'

di as text ""
di as text "Coefficient comparison:"
di as text "  Variable    Original    Synthetic       Δ      Δ/SE"
di as text "  ----------------------------------------------------------"
di as text "  x1       " %10.4f `b_x1_orig' "  " %10.4f `b_x1_synth' "  " %8.4f `delta_x1' "  " %6.3f `dse_x1'
di as text "  x2       " %10.4f `b_x2_orig' "  " %10.4f `b_x2_synth' "  " %8.4f `delta_x2' "  " %6.3f `dse_x2'

local max_dse_all = max(`dse_x1', `dse_x2')
di as text "  ----------------------------------------------------------"
di as text "  Max Δβ/SE: " %6.3f `max_dse_all'

* Test assertion: all slopes within 3 SE of target.
if `max_dse_all' < 3.0 {
    di as result "  ✓ PASS (all Δβ/SE < 3)"
    local test2_pass = 1
}
else {
    di as error "  ✗ FAIL (some Δβ/SE ≥ 3)"
    local test2_pass = 0
}

* -----------------------------------------------------------------------------
* Test 3: Multiple Fixed Effects + Multiple Predictors
* -----------------------------------------------------------------------------

di as text ""
di as text ""
di as text "Test 3: reghdfe with multiple FE and predictors"
di as text "----------------------------------------------------------"

clear
set obs 30
gen id = _n
expand 15  // 15 time periods
bysort id: gen wave = _n
set seed 11111

* Generate predictors
gen x1 = rnormal(0, 1)
gen x2 = rnormal(0, 1.2)
gen x3 = rnormal(0, 0.8)

* Generate two-way fixed effects
gen alpha_i = rnormal(0, 2)
by id: replace alpha_i = alpha_i[1]

gen gamma_t = rnormal(0, 1.5)
sort wave
by wave: replace gamma_t = gamma_t[1]
sort id wave

* Generate outcome
gen y = alpha_i + gamma_t + 1.0*x1 - 0.5*x2 + 0.8*x3 + rnormal(0, 1)

* Fit original
di as text ""
di as text "Original reghdfe model (two-way FE):"
reghdfe y x1 x2 x3, absorb(id wave) nocons

* Store coefficients
local b_x1_orig = _b[x1]
local b_x2_orig = _b[x2]
local b_x3_orig = _b[x3]

di as text ""
di as text "Original coefficients:"
di as text "  x1: " %8.4f `b_x1_orig'
di as text "  x2: " %8.4f `b_x2_orig'
di as text "  x3: " %8.4f `b_x3_orig'

* DataMirror workflow
local outdir "stata/tests/output/test_reghdfe_basic/test3"
cap mkdir "`outdir'"

* Small test dataset (30 ids × 15 waves = 450 obs, 30 obs per wave).
* Override the default min_cell_size(50) so wave and gamma_t survive
* privacy suppression during extract. Otherwise the absorb() variables
* never make it into synthetic data and the synthetic-side reghdfe
* errors with "variable wave not found".
datamirror init, checkpoint_dir("`outdir'") replace min_cell_size(5)
reghdfe y x1 x2 x3, absorb(id wave) nocons
datamirror checkpoint, tag("reghdfe_twoway")

datamirror extract, replace
datamirror rebuild using "`outdir'", clear seed(77777)

* Re-run
di as text ""
di as text "Synthetic reghdfe model:"
reghdfe y x1 x2 x3, absorb(id wave) nocons

* Compare using Δβ/SE (inferential fidelity).
local b_x1_synth = _b[x1]
local b_x2_synth = _b[x2]
local b_x3_synth = _b[x3]

local se_x1_synth = _se[x1]
local se_x2_synth = _se[x2]
local se_x3_synth = _se[x3]

local delta_x1 = abs(`b_x1_synth' - `b_x1_orig')
local delta_x2 = abs(`b_x2_synth' - `b_x2_orig')
local delta_x3 = abs(`b_x3_synth' - `b_x3_orig')

local dse_x1 = `delta_x1' / `se_x1_synth'
local dse_x2 = `delta_x2' / `se_x2_synth'
local dse_x3 = `delta_x3' / `se_x3_synth'

di as text ""
di as text "Coefficient comparison:"
di as text "  Variable    Original    Synthetic       Δ      Δ/SE"
di as text "  ----------------------------------------------------------"
di as text "  x1       " %10.4f `b_x1_orig' "  " %10.4f `b_x1_synth' "  " %8.4f `delta_x1' "  " %6.3f `dse_x1'
di as text "  x2       " %10.4f `b_x2_orig' "  " %10.4f `b_x2_synth' "  " %8.4f `delta_x2' "  " %6.3f `dse_x2'
di as text "  x3       " %10.4f `b_x3_orig' "  " %10.4f `b_x3_synth' "  " %8.4f `delta_x3' "  " %6.3f `dse_x3'

local max_dse_all = max(`dse_x1', `dse_x2', `dse_x3')
di as text "  ----------------------------------------------------------"
di as text "  Max Δβ/SE: " %6.3f `max_dse_all'

* Test assertion: all slopes within 3 SE of target.
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
di as text "Test Summary: reghdfe Basic"
di as text "=========================================="
di as text ""
di as text "Test 1 (Simple FE):     " cond(`test1_pass', "✓ PASS", "✗ FAIL")
di as text "Test 2 (Two Pred):      " cond(`test2_pass', "✓ PASS", "✗ FAIL")
di as text "Test 3 (Two-way FE):    " cond(`test3_pass', "✓ PASS", "✗ FAIL")
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
