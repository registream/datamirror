# DataMirror Test Suite

## Overview

Comprehensive test suite for DataMirror with unit tests and integration tests using UKHLS panel data.

## Test Structure

```
tests/
├── README.md                    # This file
├── run_all_tests.do            # Master test runner
├── unit/                        # Unit tests (fast, synthetic data)
│   ├── test_discrete_numeric.do
│   └── test_minimal_numeric.do
└── ukhls/                       # Integration test (real panel data)
    └── test_ukhls_comprehensive.do
```

## Running Tests

### Run All Tests
```stata
do tests/run_all_tests.do
```

### Run Specific Test
```stata
do tests/unit/test_discrete_numeric.do
do tests/ukhls/test_ukhls_comprehensive.do
```

## Test Descriptions

### Unit Tests

**test_discrete_numeric.do**
- Tests discrete-support numeric variables
- Validates exact support preservation {1, 4, 10}
- Checks Likert scales, sparse ordinals, count variables
- Verifies no invented intermediate values

**test_minimal_numeric.do**
- Minimal test with numeric-only data (100 obs, 2 strata)
- Tests basic stratified rebuild
- Fast smoke test (~1 second)

**test_iv_basic.do**
- IV regression with instrumental variables
- Tests ivregress 2sls checkpoint and Layer 4
- Validates instrument validity preservation
- Tests endogenous variable + instrument adjustment (~2 seconds)

### UKHLS Integration Test

**test_ukhls_comprehensive.do**
- Complete end-to-end test with UKHLS panel data
- 533K observations, 14 waves, 21 variables
- Tests all 4 layers + stratification + discrete numerics
- 7 checkpoint models (OLS, factor variables, binary outcomes)
- Full workflow: init → checkpoint → extract → rebuild → check
- Validates coefficient matching (Δβ < 0.05)

## Test Data Requirements

### Unit Tests
- Generate synthetic test data (no external dependencies)

### UKHLS Test
- Requires `data/ukhls_clean.dta`
- 533,163 observations across 14 waves
- 21 variables (continuous, categorical, discrete)
- Prepare data: `do examples/prepare_ukhls_simple.do`

## Success Criteria

### Unit Tests
- All tests complete without errors
- Discrete support preserved exactly
- Synthetic data matches expected distributions

### UKHLS Test
- Extract completes successfully
- Rebuild generates 533K observations
- Wave distribution preserved exactly
- 7 checkpoint models converge (Δβ < 0.05)
- Stratified validation passes

## Test Output

Each test creates output in:
- `tests/output/test_name/` - Checkpoint files
- `tests/logs/test_name.log` - Test log

Output directories are git-ignored.

## Adding New Tests

1. Create test file in appropriate directory
2. Follow naming convention: `test_<feature>.do`
3. Add to `run_all_tests.do`
4. Document in this README

## Future: Replication Package Tests

Once core functionality is stable, add tests for 10 replication packages:

```
tests/
└── replications/                # Real replication packages
    ├── test_replic_01.do
    ├── test_replic_02.do
    └── ...
```

Each test will:
1. Load replication data
2. Run original analysis (extract checkpoints)
3. Generate synthetic data
4. Validate coefficient matching

## Continuous Integration

Tests can be run automatically:
```bash
stata -b do tests/run_all_tests.do
```

Exit code 0 = all tests passed
Exit code != 0 = test failure

---

*Last updated: 2025-01-21*
*Test coverage: 3 tests (2 unit, 1 integration)*
*Runtime: ~60 seconds (if UKHLS data available)*
tests/unit/test_nbreg_basic.do
