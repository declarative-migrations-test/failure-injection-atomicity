# Partial-failure contract

The current executor runs ordered statements sequentially. This test intentionally makes a late unique-constraint operation fail after an earlier table creation succeeds. CI must observe a non-zero apply, prove residual drift remains, repair the data, and then prove eventual convergence. It must never claim that an unsuccessful apply restored the original catalog unless that restoration is independently verified.
