# Examples

Self-contained demonstrations of the datamirror workflow.

## Files

### `hello_world.do`
Five-minute round trip on Stata's built-in `auto.dta`: fit a regression, checkpoint it, extract metadata, rebuild a synthetic dataset, re-fit the regression, verify the coefficient comes back. The expected outcome is `Max Δβ/SE = 0.000` for OLS (closed-form Newton pins exactly up to floating-point noise).

The committed `hello_world.log` shows a reference run. If your run diverges substantively, open an issue with your log attached.

```stata
. do examples/hello_world.do
```

### `prepare_ukhls_simple.do` / `prepare_ukhls_data.do`
Optional preparation scripts for the UKHLS integration test in `stata/tests/dofiles/ukhls/`. UKHLS (UK Household Longitudinal Study) is a panel survey with registration-restricted download at [UK Data Service](https://www.understandingsociety.ac.uk/).

To run the UKHLS comprehensive test from a clone:

1. Download the full UKHLS Understanding Society data (requires free registration with UK Data Service).
2. Unzip the delivered waves (`a_indresp.dta` through `n_indresp.dta`) into any directory.
3. Point the preparation script at that directory (see the top-of-file header in each script for the one local variable to set).
4. The script produces `stata/tests/data/ukhls_clean.dta`, which the integration test checks for automatically.

The simpler script (`prepare_ukhls_simple.do`) produces a single-wave slice for quick development; the fuller script (`prepare_ukhls_data.do`) cleans the full 14-wave panel.

### `SERVER_STRUCTURE.md`
Recommended directory layout when running datamirror on a restricted-access server (separate input / checkpoint / log / export directories with appropriate permissions). Applies to register-data environments where the researcher extracts locally and transfers only the checkpoint directory off the secure host.

## What is not here

`hello_world.do` runs on Stata's built-in `auto.dta`; no external data is needed. Everything else is optional and assumes you have separately obtained UKHLS or your own analytical dataset.

Replication of four AEA papers using datamirror is in the sibling `replication/` directory, not here.
