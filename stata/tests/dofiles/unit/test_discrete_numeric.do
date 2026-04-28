* Test discrete-support numeric variables
* Verify that synthetic data only uses values from true support

clear all
set more off
adopath ++ "stata/src"
adopath ++ "../registream/stata/src"

* Create dataset with discrete numeric variables
clear
set obs 1000

* Discrete ordinal scale (1, 4, 10) - like user's example
gen score = .
replace score = 1 if _n <= 120
replace score = 4 if _n > 120 & _n <= 770
replace score = 10 if _n > 770

* Likert scale (1-5)
gen likert = ceil(runiform() * 5)

* Count variable (0-3)
gen count = floor(runiform() * 4)

* Stratification variable
gen wave = cond(_n <= 500, 1, 2)

* Continuous for comparison
gen age = rnormal(45, 10)

* Check true support before synthesis
di as txt _n "ORIGINAL DATA - True support:"
di as txt "score: "
tab score
di as txt "likert: "
tab likert
di as txt "count: "
tab count

* Initialize with stratification
datamirror init, checkpoint_dir("stata/tests/output/test_discrete") strata(wave) replace

* Run a model
reg age score likert count
datamirror checkpoint, tag("test_model")

* Extract
datamirror extract, replace
datamirror close

* Check schema
di as txt _n "SCHEMA - Variable classification:"
import delimited "stata/tests/output/test_discrete/schema.csv", clear varnames(1)
list varname storage

* Rebuild synthetic data
datamirror rebuild using stata/tests/output/test_discrete, clear seed(42)

* Verify discrete support is preserved
di as txt _n "SYNTHETIC DATA - Checking support preservation:"

* Check score - should ONLY have values {1, 4, 10}
di as txt _n "score variable:"
tab score
qui levelsof score, local(score_vals)
local has_invalid = 0
foreach val of local score_vals {
    if `val' != 1 & `val' != 4 & `val' != 10 {
        di as error "ERROR: score has invalid value: `val'"
        local has_invalid = 1
    }
}
if `has_invalid' == 0 {
    di as result "✓ score support preserved - only {1, 4, 10}"
}

* Check likert - should ONLY have values {1, 2, 3, 4, 5}
di as txt _n "likert variable:"
tab likert
qui levelsof likert, local(likert_vals)
local has_invalid = 0
foreach val of local likert_vals {
    if !inrange(`val', 1, 5) | `val' != floor(`val') {
        di as error "ERROR: likert has invalid value: `val'"
        local has_invalid = 1
    }
}
if `has_invalid' == 0 {
    di as result "✓ likert support preserved - only {1, 2, 3, 4, 5}"
}

* Check count - should ONLY have values {0, 1, 2, 3}
di as txt _n "count variable:"
tab count
qui levelsof count, local(count_vals)
local has_invalid = 0
foreach val of local count_vals {
    if !inrange(`val', 0, 3) | `val' != floor(`val') {
        di as error "ERROR: count has invalid value: `val'"
        local has_invalid = 1
    }
}
if `has_invalid' == 0 {
    di as result "✓ count support preserved - only {0, 1, 2, 3}"
}

* Check continuous - should have interpolated values
di as txt _n "age variable (continuous - should have non-integer values):"
qui sum age, detail
di as txt "  Min: " r(min)
di as txt "  Median: " r(p50)
di as txt "  Max: " r(max)
qui count if age != floor(age)
if r(N) > 0 {
    di as result "✓ age has interpolated values (as expected for continuous)"
}

* Summary
di as txt _n "════════════════════════════════════════════════════════════"
di as txt "DISCRETE SUPPORT TEST SUMMARY"
di as txt "════════════════════════════════════════════════════════════"
di as txt "Discrete variables should only use values from true support."
di as txt "Continuous variables should have interpolated values."
