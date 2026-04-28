* ══════════════════════════════════════════════════════════════════════════
* Prepare UKHLS Data for datamirror Testing
*
* Purpose: create a comprehensive cleaned panel dataset from all UKHLS waves
*          (a_indresp.dta through n_indresp.dta), merged and harmonized,
*          written to stata/tests/data/ukhls_clean.dta for the datamirror
*          integration test. See also prepare_ukhls_simple.do for a
*          single-wave slice used during development.
*
* Input : directory containing the Understanding Society delivery files.
*         Obtain via the UK Data Service:
*             https://www.understandingsociety.ac.uk/
* Output: stata/tests/data/ukhls_clean.dta
*
* Set UKHLS_INPUT below to the directory holding the delivery files,
* then run this file from the datamirror repository root:
*
*     do examples/prepare_ukhls_data.do
* ══════════════════════════════════════════════════════════════════════════

clear all
set more off
set maxvar 10000

* Set this to the directory containing the UKHLS delivery .dta files.
global UKHLS_INPUT  "ukhls_delivered_data"

* Output target for the datamirror test harness.
global UKHLS_OUTPUT "stata/tests/data"

cap mkdir "$UKHLS_OUTPUT"

* ══════════════════════════════════════════════════════════════════════════
* PART 1: Load and Merge All Waves
* ══════════════════════════════════════════════════════════════════════════

di as txt _n "══════════════════════════════════════════════════════════════"
di as txt "PART 1: Loading and Merging 14 Waves"
di as txt "══════════════════════════════════════════════════════════════"

* Define core variables to keep from each wave
local target_vars pidp hidp psu strata country gor_dv age_dv sex_dv ///
    qfhigh_dv jbstat jbhrs jbsoc00_cc ///
    sf1 sf3a scghq1_dv sclfsato ///
    paygu_dv fimnnet_dv ///
    racel_dv plbornc month istrtdaty ///
    benbase1 benbase2 benbase3 benbase4 ///
    bendis1 bendis2 bendis5 bendis12 bendis97 ///
    jbiindb_dv employ ///
    indpxus_lw indpxus_xw

* Loop through each wave
foreach w in a b c d e f g h i j k l m n {

    local filepath "$UKHLS_INPUT/`w'_indresp.dta"

    * Check file exists
    capture confirm file "`filepath'"
    if _rc != 0 {
        di as error "File not found: `filepath', skipping..."
        continue
    }

    di as txt _n "Processing wave `w'..."
    use "`filepath'", clear

    * Build list of variables to keep
    local vars_to_keep

    foreach var in `target_vars' {
        * Check for wave-prefixed version
        cap confirm variable `w'_`var'
        if _rc == 0 {
            * Rename by removing wave prefix
            rename `w'_`var' `var'
            local vars_to_keep `vars_to_keep' `var'
        }
        else {
            * Check for non-prefixed version
            cap confirm variable `var'
            if _rc == 0 {
                local vars_to_keep `vars_to_keep' `var'
            }
        }
    }

    * Keep only target variables
    keep `vars_to_keep'

    * Add wave identifier
    gen wave = strpos("abcdefghijklmn", "`w'")
    label variable wave "Wave Number"
    order wave, first

    * Save temporary wave file
    tempfile wave_`w'
    save `wave_`w''

    di as res "  Wave `w': " _N " observations, " `: word count `vars_to_keep'' " variables"
}

* Append all waves
di as txt _n "Appending all waves..."
use `wave_a', clear
foreach w in b c d e f g h i j k l m n {
    cap append using `wave_`w''
}

* Verify unique identifier
isid pidp wave

di as res _n "Combined dataset: " _N " person-wave observations"

* ══════════════════════════════════════════════════════════════════════════
* PART 2: Create Time Variables
* ══════════════════════════════════════════════════════════════════════════

di as txt _n "══════════════════════════════════════════════════════════════"
di as txt "PART 2: Creating Time Variables"
di as txt "══════════════════════════════════════════════════════════════"

* Wave string
gen wave_str = ""
replace wave_str = "a" if wave == 1
replace wave_str = "b" if wave == 2
replace wave_str = "c" if wave == 3
replace wave_str = "d" if wave == 4
replace wave_str = "e" if wave == 5
replace wave_str = "f" if wave == 6
replace wave_str = "g" if wave == 7
replace wave_str = "h" if wave == 8
replace wave_str = "i" if wave == 9
replace wave_str = "j" if wave == 10
replace wave_str = "k" if wave == 11
replace wave_str = "l" if wave == 12
replace wave_str = "m" if wave == 13
replace wave_str = "n" if wave == 14
order wave_str, after(wave)

* Create year variable
* Interviews span Jan-Dec for wave, or following Jan-Dec for late responders
gen year = .

* First interview period (Jan-Dec of base year)
local base_year = 2009
forvalues i = 1/14 {
    replace year = `base_year' + `i' - 1 if wave == `i' & inrange(month, 1, 12)
}

* Second interview period (following year for late responders)
local base_year = 2010
forvalues i = 1/14 {
    replace year = `base_year' + `i' - 1 if wave == `i' & month > 12 & month < .
}

label var year "Interview Year"
order year, after(wave_str)

di as res "Year range: " r(min) " to " r(max)

* ══════════════════════════════════════════════════════════════════════════
* PART 3: Variable Cleaning and Creation
* ══════════════════════════════════════════════════════════════════════════

di as txt _n "══════════════════════════════════════════════════════════════"
di as txt "PART 3: Variable Cleaning and Recoding"
di as txt "══════════════════════════════════════════════════════════════"

* Rename for clarity
rename racel_dv ethnicity
rename sf1 health_general
rename sf3a health_limit_work
rename sex_dv gender
rename sclfsato life_satisfaction
rename paygu_dv pay_monthly
rename qfhigh_dv education
rename scghq1_dv wellbeing
rename benbase1 benefit_income_support
rename benbase2 benefit_jsa
rename bendis1 benefit_incapacity
rename benbase3 benefit_child
rename bendis97 benefit_other
rename bendis12 benefit_pip
rename bendis2 benefit_esa
rename benbase4 benefit_universal_credit
rename jbiindb_dv sector
rename bendis5 benefit_dla
rename plbornc place_born

* Drop Northern Ireland
drop if gor_dv == 12
di as res "Dropped Northern Ireland observations"

* ──────────────────────────────────────────────────────────────────────────
* Demographics
* ──────────────────────────────────────────────────────────────────────────

* Age categories
gen age_cat = .
replace age_cat = 1 if inrange(age_dv, 18, 24)
replace age_cat = 2 if inrange(age_dv, 25, 34)
replace age_cat = 3 if inrange(age_dv, 35, 44)
replace age_cat = 4 if inrange(age_dv, 45, 54)
replace age_cat = 5 if inrange(age_dv, 55, 64)
replace age_cat = 6 if age_dv >= 65 & age_dv < .

label define age_cat_lbl 1 "18-24" 2 "25-34" 3 "35-44" 4 "45-54" 5 "55-64" 6 "65+"
label values age_cat age_cat_lbl
label var age_cat "Age Category"

* Gender
gen female = (gender == 2)
label var female "Female (vs Male)"

* Ethnicity binary
gen ethnic_minority = (ethnicity >= 5) if !missing(ethnicity)
label var ethnic_minority "Ethnic Minority (vs White)"

* Region binary (London/Southeast vs Rest)
gen region_london_se = (gor_dv == 7 | gor_dv == 8) if !missing(gor_dv)
label var region_london_se "London/Southeast"

label define region_lbl ///
    1 "North East" 2 "North West" 3 "Yorkshire" 4 "East Midlands" ///
    5 "West Midlands" 6 "East" 7 "London" 8 "South East" ///
    9 "South West" 10 "Wales" 11 "Scotland"
label values gor_dv region_lbl
label var gor_dv "Region"

* ──────────────────────────────────────────────────────────────────────────
* Education
* ──────────────────────────────────────────────────────────────────────────

gen education_cat = .
replace education_cat = 1 if inrange(education, 0, 6)   // Degree/Professional
replace education_cat = 2 if inrange(education, 7, 12)  // A-Level
replace education_cat = 3 if inrange(education, 13, 16) // GCSE
replace education_cat = 4 if education == 96            // None

label define edu_lbl ///
    1 "Degree/Professional" 2 "A-Level" 3 "GCSE" 4 "No Qualification"
label values education_cat edu_lbl
label var education_cat "Education Level"

* ──────────────────────────────────────────────────────────────────────────
* Employment
* ──────────────────────────────────────────────────────────────────────────

gen employment_status = ""
replace employment_status = "Employed" if jbstat == 2
replace employment_status = "Self-Employed" if jbstat == 1
replace employment_status = "LT Sick" if jbstat == 8
replace employment_status = "Family Care" if jbstat == 6
replace employment_status = "Student" if jbstat == 7
replace employment_status = "Retired" if jbstat == 4
replace employment_status = "Unemployed" if jbstat == 3
replace employment_status = "Other" if jbstat > 0 & ///
    !inlist(jbstat, 1, 2, 3, 4, 6, 7, 8)

label var employment_status "Employment Status (Detailed)"

* Employment binary
gen employed = inlist(jbstat, 1, 2) if !missing(jbstat)
label var employed "Employed (Paid or Self-Employed)"

* Long-term sick
gen lt_sick = (jbstat == 8) if !missing(jbstat)
label var lt_sick "Long-Term Sick/Disabled"

* ──────────────────────────────────────────────────────────────────────────
* Sector
* ──────────────────────────────────────────────────────────────────────────

gen sector_broad = ""
replace sector_broad = "Agriculture/Forestry/Fishing" if inrange(sector, 1, 2)
replace sector_broad = "Water/Waste Management" if sector == 3 | sector == 26
replace sector_broad = "Mining" if sector == 4
replace sector_broad = "Manufacturing" if inrange(sector, 5, 13)
replace sector_broad = "Construction" if inlist(sector, 14, 15)
replace sector_broad = "Wholesale/Retail" if inrange(sector, 16, 18)
replace sector_broad = "Transportation/Storage" if inlist(sector, 19, 21)
replace sector_broad = "Information/Communication" if sector == 20
replace sector_broad = "Finance/Insurance" if inlist(sector, 22, 23)
replace sector_broad = "Accommodation/Food" if sector == 24
replace sector_broad = "Other Services" if inlist(sector, 25, 30, 31)

label var sector_broad "Industry Sector (Broad)"

* ──────────────────────────────────────────────────────────────────────────
* Health
* ──────────────────────────────────────────────────────────────────────────

gen health_excellent = (health_general == 1) if !missing(health_general)
label var health_excellent "Excellent Health"

gen health_good = inrange(health_general, 1, 2) if !missing(health_general)
label var health_good "Excellent/Very Good Health"

gen health_fair_poor = inrange(health_general, 4, 5) if !missing(health_general)
label var health_fair_poor "Fair/Poor Health"

label define health_lbl 1 "Excellent" 2 "Very Good" 3 "Good" 4 "Fair" 5 "Poor"
label values health_general health_lbl
label var health_general "General Health"

* Health limits work
gen health_limits = (health_limit_work == 1) if !missing(health_limit_work)
label var health_limits "Health Limits Work"

* ──────────────────────────────────────────────────────────────────────────
* Income
* ──────────────────────────────────────────────────────────────────────────

* Log transformations
gen log_hh_income = ln(fimnnet_dv) if fimnnet_dv > 0
label var log_hh_income "Log Household Net Income"

gen log_pay = ln(pay_monthly) if pay_monthly > 0
label var log_pay "Log Monthly Pay"

* Income quintiles (within wave)
bysort wave: xtile income_quintile = fimnnet_dv if fimnnet_dv > 0, nquantiles(5)
label var income_quintile "Income Quintile (Within Wave)"

* ──────────────────────────────────────────────────────────────────────────
* Benefits
* ──────────────────────────────────────────────────────────────────────────

* Any disability benefit
gen has_disability_benefit = (benefit_pip == 1 | benefit_dla == 1)
label var has_disability_benefit "Receiving Disability Benefit (PIP/DLA)"

* Any incapacity benefit
gen has_incapacity_benefit = (benefit_esa == 1 | ///
    (benefit_universal_credit == 1 & lt_sick == 1))
label var has_incapacity_benefit "Receiving Incapacity Benefit (ESA/UC)"

* Any disability or incapacity
gen has_disability_incap = (has_disability_benefit == 1 | ///
    has_incapacity_benefit == 1)
label var has_disability_incap "Receiving Disability/Incapacity Benefit"

* Count of benefits
gen n_benefits = 0
foreach var in benefit_income_support benefit_jsa benefit_child ///
    benefit_pip benefit_dla benefit_esa benefit_universal_credit {
    replace n_benefits = n_benefits + 1 if `var' == 1
}
label var n_benefits "Number of Benefits Received"

* ──────────────────────────────────────────────────────────────────────────
* Wellbeing
* ──────────────────────────────────────────────────────────────────────────

* Standardize wellbeing (within wave)
bysort wave: egen wellbeing_mean = mean(wellbeing)
bysort wave: egen wellbeing_sd = sd(wellbeing)
gen wellbeing_std = (wellbeing - wellbeing_mean) / wellbeing_sd
drop wellbeing_mean wellbeing_sd
label var wellbeing_std "Wellbeing (Standardized Within Wave)"

* Life satisfaction categories
gen life_sat_high = (life_satisfaction >= 6) if !missing(life_satisfaction)
label var life_sat_high "High Life Satisfaction (6-7)"

* ══════════════════════════════════════════════════════════════════════════
* PART 4: Panel Structure Variables
* ══════════════════════════════════════════════════════════════════════════

di as txt _n "══════════════════════════════════════════════════════════════"
di as txt "PART 4: Panel Structure Analysis"
di as txt "══════════════════════════════════════════════════════════════"

* Count waves per person
bysort pidp: egen wave_count = count(wave)
label var wave_count "Number of Waves Appeared"

* Identify consecutive waves
sort pidp wave
bysort pidp: gen consecutive = (wave == wave[_n-1] + 1) if _n > 1
replace consecutive = 0 if consecutive == .
label var consecutive "Consecutive Wave"

* Calculate streaks of consecutive waves
gen streak = 1 if consecutive == 0
bysort pidp (wave): replace streak = streak[_n-1] + 1 if _n > 1 & consecutive == 1
bysort pidp: egen max_streak = max(streak)
label var max_streak "Maximum Consecutive Waves"

* Panel balance summary
preserve
    bysort pidp: keep if _n == 1
    di as txt _n "Wave count distribution:"
    tab wave_count

    di as txt _n "Maximum streak distribution:"
    tab max_streak
restore

di as res _n "Final dataset: " _N " observations, " `: di %9.0fc _N/14' " individuals (average)"

* ══════════════════════════════════════════════════════════════════════════
* PART 5: Set Panel Structure and Save
* ══════════════════════════════════════════════════════════════════════════

di as txt _n "══════════════════════════════════════════════════════════════"
di as txt "PART 5: Setting Panel Structure and Saving"
di as txt "══════════════════════════════════════════════════════════════"

* Set as panel
xtset pidp wave
di as txt "Panel set: pidp (individual) × wave"

* Reorder key variables
order pidp wave wave_str year age_dv female ethnic_minority education_cat ///
    employed employment_status lt_sick sector_broad ///
    health_general health_good health_limits ///
    fimnnet_dv log_hh_income pay_monthly log_pay income_quintile ///
    has_disability_benefit has_incapacity_benefit n_benefits ///
    wellbeing wellbeing_std life_satisfaction ///
    gor_dv region_london_se wave_count max_streak

* Label dataset
label data "UKHLS Cleaned Panel Data - Waves a-n (2009-2022)"

* Save main file
compress
save "$UKHLS_OUTPUT/ukhls_clean.dta", replace

di as res _n "✓ Saved: $UKHLS_OUTPUT/ukhls_clean.dta"
di as res "  Size: " `: di %9.0fc _N' " observations"
di as res "  Variables: " `: word count `: colnames e(b)''

* ══════════════════════════════════════════════════════════════════════════
* PART 6: Create Analysis Subsets
* ══════════════════════════════════════════════════════════════════════════

di as txt _n "══════════════════════════════════════════════════════════════"
di as txt "PART 6: Creating Analysis Subsets"
di as txt "══════════════════════════════════════════════════════════════"

* Working age only (18-65)
preserve
    keep if inrange(age_dv, 18, 65)
    save "$UKHLS_OUTPUT/ukhls_clean_workingage.dta", replace
    di as res "✓ Working age subset: " _N " observations"
restore

* At least 2 consecutive waves
preserve
    keep if max_streak >= 2
    save "$UKHLS_OUTPUT/ukhls_clean_2consec.dta", replace
    di as res "✓ 2+ consecutive waves: " _N " observations"
restore

* Balanced panel (all 14 waves)
preserve
    keep if wave_count == 14
    save "$UKHLS_OUTPUT/ukhls_clean_balanced.dta", replace
    di as res "✓ Balanced panel (14 waves): " _N " observations"
restore

* ══════════════════════════════════════════════════════════════════════════
* Summary
* ══════════════════════════════════════════════════════════════════════════

di as txt _n "══════════════════════════════════════════════════════════════"
di as res "DATA PREPARATION COMPLETE"
di as txt "══════════════════════════════════════════════════════════════"

use "$UKHLS_OUTPUT/ukhls_clean.dta", clear

di as txt _n "Dataset Summary:"
di as txt "  Total observations:     " `: di %12.0fc _N'
di as txt "  Unique individuals:     " `: di %12.0fc _N/14' " (average)"
di as txt "  Waves:                  14 (a-n, 2009-2022)"
di as txt "  Year range:             " r(min) "-" r(max)

di as txt _n "Key Variables:"
di as txt "  Demographics:  age, gender, ethnicity, education, region"
di as txt "  Employment:    employed, lt_sick, sector"
di as txt "  Health:        health_general, health_limits"
di as txt "  Income:        hh_income, pay, income_quintile"
di as txt "  Benefits:      disability, incapacity, # benefits"
di as txt "  Wellbeing:     wellbeing (standardized), life satisfaction"
di as txt "  Panel:         wave_count, max_streak, consecutive"

di as txt _n "Files created:"
di as txt "  1. $UKHLS_OUTPUT/ukhls_clean.dta               (full panel)"
di as txt "  2. $UKHLS_OUTPUT/ukhls_clean_workingage.dta    (18-65 only)"
di as txt "  3. $UKHLS_OUTPUT/ukhls_clean_2consec.dta       (2+ consecutive waves)"
di as txt "  4. $UKHLS_OUTPUT/ukhls_clean_balanced.dta      (balanced panel)"

di as txt _n "Ready for datamirror testing!"
di as txt "══════════════════════════════════════════════════════════════"
