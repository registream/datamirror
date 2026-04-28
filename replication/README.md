# datamirror — Published-paper replications

This tree validates `datamirror` against four published economics papers by
re-running each paper's analysis code against synthetic data produced from
`datamirror` checkpoints, and comparing the resulting coefficients to the
original estimates.

The fidelity target is `max(|Δβ| / SE) < 3` (see
[`docs/FIDELITY_METRIC.md`](../docs/FIDELITY_METRIC.md)): the synthetic
coefficient on every flagged regressor must fall within 3 standard errors of
the original coefficient.

## Headline results

See [`RESULTS.md`](RESULTS.md) for the full summary table; an extended
appendix with per-table breakdowns is in
[`RESULTS_APPENDIX.md`](RESULTS_APPENDIX.md).

## Replications

| Paper | Journal | openICPSR |
|-------|---------|-----------|
| Duflo, Hanna, Ryan (2012). *Incentives Work: Getting Teachers to Come to School.* | *AER* 102(4) | [112523](https://www.openicpsr.org/openicpsr/project/112523) |
| Dupas, Robinson (2013). *Savings Constraints and Microenterprise Development.* | *AEJ: Applied* 5(1) | [116380](https://www.openicpsr.org/openicpsr/project/116380) |
| Banerjee, Duflo, Glennerster, Kinnan (2015). *The Miracle of Microfinance?* | *AEJ: Applied* 7(1) | [113599](https://www.openicpsr.org/openicpsr/project/113599) |
| Autor, Dorn, Hanson (2019). *When Work Disappears.* | *AER: Insights* 1(2) | [116320](https://www.openicpsr.org/openicpsr/project/116320) |

## What ships in the public repo

Only the headline `RESULTS.md` and the per-paper appendix. The per-paper
validation artifacts — modified `.do` files, reference Stata logs, and the
synthetic checkpoints — are kept out of the public repo to keep clones
lightweight. Each replication can be regenerated locally from the upstream
openICPSR package linked above using the `datamirror` checkpoint workflow
documented in the package README.

## Fidelity metric

The pass criterion for a replication's checkpoint is

```
|beta_synthetic - beta_original| / SE_original  <  3
```

meaning the synthetic coefficient lies within 3 standard errors of the
original. See [`docs/FIDELITY_METRIC.md`](../docs/FIDELITY_METRIC.md) for the
derivation and rationale.
