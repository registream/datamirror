* ══════════════════════════════════════════════════════════════════════════
* Prepare UKHLS Data for datamirror Testing - Simplified Version
*
* Input : directory containing the Understanding Society delivery files
*         (a_indresp.dta through n_indresp.dta). Obtain via the UK Data
*         Service: https://www.understandingsociety.ac.uk/
* Output: stata/tests/data/ukhls_wave_n_clean.dta (single-wave slice for
*         quick datamirror development).
*
* Set UKHLS_INPUT below to the directory holding the delivery files,
* then run this file from the datamirror repository root:
*
*     do examples/prepare_ukhls_simple.do
* ══════════════════════════════════════════════════════════════════════════

clear all
set more off
set maxvar 10000

* Set this to the directory containing the UKHLS delivery .dta files.
global UKHLS_INPUT  "ukhls_delivered_data"

* Output target for the datamirror test harness.
global UKHLS_OUTPUT "stata/tests/data"

cap mkdir "$UKHLS_OUTPUT"
log using "$UKHLS_OUTPUT/ukhls_prep.log", replace text

di as txt _n "══════════════════════════════════════════════════════════════"
di as txt "Starting UKHLS Data Preparation"
di as txt "══════════════════════════════════════════════════════════════"

* Test loading one wave first
di as txt _n "Testing wave n (most recent)..."
use "$UKHLS_INPUT/n_indresp.dta", clear
di as result "Successfully loaded wave n: " _N " observations, " c(k) " variables"

* Keep working age
keep if inrange(n_age_dv, 18, 65)
di as result "After age restriction: " _N " observations"

* Keep core variables (only those that exist)
keep pidp n_age_dv n_sex_dv n_racel_dv n_qfhigh_dv n_jbstat ///
    n_sf1 n_scghq1_dv n_sclfsato ///
    n_paygu_dv n_fimnnet_dv n_gor_dv ///
    n_benbase1 n_benbase2 n_benbase4 ///
    n_bendis1 n_bendis2 n_bendis12 ///
    n_indpxus_lw

di as result "After keeping core variables: " c(k) " variables"

* Rename variables (remove n_ prefix)
rename n_age_dv age
rename n_sex_dv gender
rename n_racel_dv ethnicity
rename n_qfhigh_dv education
rename n_jbstat employment_status
rename n_sf1 health_general
rename n_scghq1_dv wellbeing
rename n_sclfsato life_satisfaction
rename n_paygu_dv pay_monthly
rename n_fimnnet_dv hh_income
rename n_gor_dv region
rename n_benbase1 benefit_income_support
rename n_benbase2 benefit_jsa
rename n_benbase4 benefit_universal_credit
rename n_bendis1 benefit_incapacity
rename n_bendis2 benefit_esa
rename n_bendis12 benefit_pip
rename n_indpxus_lw weight_long

* Add wave identifier
gen wave = 14
gen wave_str = "n"
gen year = 2022

di as result "Variables renamed and wave identifiers added"

* Create analysis variables
di as txt _n "Creating analysis variables..."

* Demographics
gen female = (gender == 2)
gen ethnic_minority = (ethnicity >= 5) if !missing(ethnicity)

gen education_cat = .
replace education_cat = 1 if inrange(education, 0, 6)
replace education_cat = 2 if inrange(education, 7, 12)
replace education_cat = 3 if inrange(education, 13, 16)
replace education_cat = 4 if education == 96
label define edu_lbl 1 "Degree" 2 "A-Level" 3 "GCSE" 4 "No Qual"
label values education_cat edu_lbl

gen age_cat = .
replace age_cat = 1 if inrange(age, 18, 24)
replace age_cat = 2 if inrange(age, 25, 34)
replace age_cat = 3 if inrange(age, 35, 44)
replace age_cat = 4 if inrange(age, 45, 54)
replace age_cat = 5 if inrange(age, 55, 65)
label define age_lbl 1 "18-24" 2 "25-34" 3 "35-44" 4 "45-54" 5 "55-65"
label values age_cat age_lbl

* Employment
gen employed = inlist(employment_status, 1, 2) if !missing(employment_status)
gen lt_sick = (employment_status == 8) if !missing(employment_status)

* Health
gen health_good = inrange(health_general, 1, 2) if !missing(health_general)
gen health_fair_poor = inrange(health_general, 4, 5) if !missing(health_general)

* Income
gen log_hh_income = ln(hh_income) if hh_income > 0
gen log_pay = ln(pay_monthly) if pay_monthly > 0

* Benefits
gen has_disability_benefit = (benefit_pip == 1)
gen has_incapacity_benefit = (benefit_esa == 1 | (benefit_universal_credit == 1 & lt_sick == 1))

* Wellbeing
egen wellbeing_std = std(wellbeing)
gen life_sat_high = (life_satisfaction >= 6) if !missing(life_satisfaction)

* Region
gen region_london_se = (region == 7 | region == 8) if !missing(region)

di as result "Analysis variables created"

* Show summary
di as txt _n "Dataset Summary:"
di as txt "  Observations: " as result _N
di as txt "  Variables: " as result c(k)
di as txt "  Wave: n (2022)"

* Save single-wave dataset
compress
save "$UKHLS_OUTPUT/ukhls_wave_n_clean.dta", replace
di as result _n "✓ Saved: $UKHLS_OUTPUT/ukhls_wave_n_clean.dta"

* Show key variables
di as txt _n "Key Variable Summary:"
sum age female employed health_good wellbeing_std log_hh_income

di as txt _n "══════════════════════════════════════════════════════════════"
di as result "DATA PREPARATION COMPLETE"
di as txt "══════════════════════════════════════════════════════════════"

log close
