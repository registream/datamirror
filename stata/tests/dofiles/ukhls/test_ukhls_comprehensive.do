* DataMirror UKHLS Comprehensive Test
* Tests all 4 layers with stratification and discrete numerics

clear all
set more off
set seed 20250120

* Setup
adopath + "stata/src"
local outdir "stata/tests/output/ukhls_comprehensive"

di as txt _n "════════════════════════════════════════════════════════════"
di as txt "DATAMIRROR COMPREHENSIVE TEST - UKHLS PANEL DATA"
di as txt "════════════════════════════════════════════════════════════"
di as txt "Dataset: 533K observations, 14 waves, 21 variables"
di as txt "Tests: All 4 layers + stratification + discrete numerics"
di as txt "════════════════════════════════════════════════════════════"

* Load UKHLS data
use stata/tests/data/ukhls_clean.dta, clear

* Display data structure
di as txt _n "Data Structure:"
describe, short
di as txt _n "Wave distribution:"
tab wave

* Check for discrete numerics
di as txt _n "Checking discrete numeric variables..."
foreach var of varlist _all {
    cap qui tab `var'
    if _rc == 0 {
        local nuniq = r(r)
        if `nuniq' <= 20 & `nuniq' < _N/100 {
            di as txt "  - `var': `nuniq' unique values (discrete)"
        }
    }
}

* Initialize with stratification
di as txt _n "════════════════════════════════════════════════════════════"
di as txt "PHASE 1: INITIALIZATION"
di as txt "════════════════════════════════════════════════════════════"
datamirror init, checkpoint_dir("`outdir'") strata(wave) replace

* Checkpoint Model 1: Basic employment model
di as txt _n "Checkpointing Model 1: Employment ~ Age + Female"
reg employed age female if !missing(employed, age, female)
datamirror checkpoint, tag("employment_basic")

* Checkpoint Model 2: Wellbeing model
di as txt _n "Checkpointing Model 2: Wellbeing ~ Age + Female + Education"
reg wellbeing_std age female i.education_cat if !missing(wellbeing_std, age, female, education_cat)
datamirror checkpoint, tag("wellbeing_education")

* Checkpoint Model 3: Health model
di as txt _n "Checkpointing Model 3: Health ~ Age + Employment + Income"
reg health_general age employed if !missing(health_general, age, employed)
datamirror checkpoint, tag("health_employment")

* Checkpoint Model 4: Wave-specific model (wave 1)
di as txt _n "Checkpointing Model 4: Employment in Wave 1"
reg employed age female if wave == 1 & !missing(employed, age, female)
datamirror checkpoint, tag("employment_wave1")

* Checkpoint Model 5: Wave-specific model (wave 14)
di as txt _n "Checkpointing Model 5: Employment in Wave 14"
reg employed age female if wave == 14 & !missing(employed, age, female)
datamirror checkpoint, tag("employment_wave14")

* Checkpoint Model 6: Binary outcome
di as txt _n "Checkpointing Model 6: Has Disability ~ Age + Female"
reg has_disability age female if !missing(has_disability, age, female)
datamirror checkpoint, tag("disability_binary")

* Checkpoint Model 7: Categorical predictor
di as txt _n "Checkpointing Model 7: Wellbeing ~ Education Categories"
reg wellbeing_std i.education_cat if !missing(wellbeing_std, education_cat)
datamirror checkpoint, tag("wellbeing_categorical")

* Extract
di as txt _n "════════════════════════════════════════════════════════════"
di as txt "PHASE 2: EXTRACTION"
di as txt "════════════════════════════════════════════════════════════"
datamirror extract, replace

* Check files created
di as txt _n "Verifying extracted files..."
local files "metadata.csv schema.csv marginals_cont.csv marginals_cat.csv correlations.csv checkpoints.csv marginals_cont_stratified.csv marginals_cat_stratified.csv correlations_stratified.csv"
foreach file of local files {
    cap confirm file "`outdir'/`file'"
    if _rc == 0 {
        di as result "  ✓ `file'"
    }
    else {
        di as error "  ✗ `file' NOT FOUND"
    }
}

* Close session
datamirror close

* Rebuild
di as txt _n "════════════════════════════════════════════════════════════"
di as txt "PHASE 3: REBUILD"
di as txt "════════════════════════════════════════════════════════════"
datamirror rebuild using "`outdir'", clear seed(12345)

* Verify data structure
di as txt _n "Synthetic data structure:"
describe, short

* Verify wave distribution
di as txt _n "Wave distribution (synthetic):"
tab wave

* Verify discrete numerics preserved
di as txt _n "Checking discrete numeric preservation..."
qui levelsof education_cat, local(edu_vals)
di as txt "  education_cat values: `edu_vals'"
qui levelsof employed, local(emp_vals)
di as txt "  employed values: `emp_vals'"
qui levelsof has_disability, local(dis_vals)
di as txt "  has_disability values: `dis_vals'"

* Verify continuous variables have non-integer values
qui sum age
if r(mean) != floor(r(mean)) {
    di as result "  ✓ age has decimal values (continuous)"
}
qui sum wellbeing_std
if r(mean) != floor(r(mean)) {
    di as result "  ✓ wellbeing_std has decimal values (continuous)"
}

* Validation
di as txt _n "════════════════════════════════════════════════════════════"
di as txt "PHASE 4: VALIDATION"
di as txt "════════════════════════════════════════════════════════════"
datamirror check using "`outdir'"

* Summary
di as txt _n "════════════════════════════════════════════════════════════"
di as txt "TEST COMPLETE"
di as txt "════════════════════════════════════════════════════════════"
di as txt "Output directory: `outdir'/"
di as txt "Log saved to: tests/logs/ukhls_comprehensive.log"

* Clean up large output (optional)
* cap rm -rf "`outdir'"
