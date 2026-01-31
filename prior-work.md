# Prior Work: Data Center Power Modeling

Published research on estimating server and data center power consumption from performance counters.

## Foundational: CPU-Linear Models

**Fan, Weber & Barroso (2007)** — *"Power Provisioning for a Warehouse-Sized Computer"* (Google)
- Landmark paper showing server power is well-approximated by a linear function of CPU utilization:
  `P(u) = P_idle + (P_peak - P_idle) * u`
- Measured across thousands of Google servers. CPU utilization explained ~70-90% of power variance depending on workload. Still the baseline model most others build on.

**Economou, Rivoire, Kozyrakis & Ranganathan (2006)** — *"Full-System Power Analysis and Modeling for Server Environments"* (HP Labs)
- Decomposed power by subsystem: CPU, memory, disk, NICs. Used per-component performance counters (not just aggregate CPU%). Adding disk I/O and memory bandwidth counters improved accuracy to within 5% of measured wall power on HP ProLiant servers.

## Multi-Resource Models

**Rivoire, Ranganathan & Kozyrakis (2008)** — *"A Comparison of High-Level Full-System Power Models"*
- Systematic comparison of model complexity vs. accuracy. A model using 4 counters (CPU utilization, disk I/O rate, memory bandwidth, network throughput) matched within ~5% of wall-power on diverse workloads. Additional counters gave diminishing returns.

**Kansal, Zhao, Liu, Kothari & Bhattacharya (2010)** — *"Virtual Machine Power Metering and Provisioning"* (Microsoft Research)
- **Joulemeter** — used performance counters to estimate per-VM power without hardware power meters:
  `P = B_cpu * CPU% + B_disk * DiskIOPS + B_net * NetBps + B_mem * MemBW + P_base`
- Coefficients (B) calibrated per server model against a wall-power meter. Achieved ~5W accuracy on typical servers.

## Survey / Taxonomy

**Dayarathna, Wen & Fan (2016)** — *"Data Center Energy Consumption Modeling: A Survey"* (IEEE Communications Surveys & Tutorials)
- Comprehensive survey categorizing models into:
  - **Additive component models** — sum subsystem contributions (CPU + disk + memory + NIC + fans + PSU loss)
  - **Regression models** — fit coefficients to perf counter inputs
  - **Thermal-aware models** — account for cooling overhead
  - **Workload-aware models** — model specific application patterns

## Industry / Operational Models

**SPECpower_ssj2008** — Industry-standard benchmark for server energy efficiency. Publishes power-performance curves at 10% utilization increments. The underlying data confirms the near-linear CPU-power relationship across hundreds of server models from all major vendors.

**The Green Grid (PUE)** — Power Usage Effectiveness framework. While PUE itself is a facility-level metric (total facility power / IT equipment power), the IT equipment power models underneath use the same perf-counter approach.

**Pelley, Meisner, Wenisch & VanGilder (2009)** — *"Understanding and Abstracting Total Data Center Power"*
- Extended the model from individual servers to full racks and facilities, accounting for PSU efficiency curves, fan power (scales as cube of airflow), and cooling.

## ML-Based Models

**Ardalani, O'Neil & Padala (2015)** — *"Cross-Architecture Workload Characterization"* (VMware)
- Used hardware performance counters as ML features to predict power across different CPU architectures without per-model calibration.

**Wu, Chen et al. (2022-2024)** — Various papers from hyperscalers using gradient-boosted trees / neural networks over performance counter telemetry to predict rack-level power. The features are the same perf counters but the model is nonlinear.

## Common Features Across Models

All published models use some subset of the same performance counters:

| Counter | Why it matters |
|---------|---------------|
| CPU % | Dominant power consumer, ~60-70% of dynamic server power |
| Disk I/O rate | Spindle motors + head seeks (HDD) or controller activity (SSD) |
| Memory bandwidth | DRAM refresh + read/write current |
| Network bytes/sec | NIC PHY + DMA + interrupt processing |
| CPU frequency | Directly proportional to dynamic power (P ~ f * V^2) |

The Fan et al. (2007) linear model remains hard to beat in practice. Adding disk/memory/network counters gives marginal improvement (~2-5% error reduction) because on most server workloads those subsystems are either correlated with CPU activity or contribute a small fraction of total power.
