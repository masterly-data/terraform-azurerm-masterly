<!-- customer-evidence:start 1.2.3 -->
### Customer evidence

What 1.2.3 was tested for before it reached the Stable ring, from its [customer summary](https://raw.githubusercontent.com/masterly-data/terraform-azurerm-masterly/main/customer-summary/1.2.3.json).

- **Rings:** Canary 2026-01-10, Beta 2026-01-17, Stable 2026-01-24
- **Gates passed:** `upgrade`, `perf`, `sec`
- **Upgrade verified from:** 1.2.2, 1.1.0

**Performance**, measured against 1.2.2, the previous Stable version:

| Profile | p50 (ms) | p95 (ms) | Throughput (requests/s) | Error rate |
|---|---|---|---|---|
| small | 120.5 | 340 | 52.0 | 0.001 |

**Security findings** the scan left, by severity: High 0, Medium 0, Low 2, Informational 5
<!-- customer-evidence:end 1.2.3 -->
