# CVA6 RISC-V CPU [![Build Status](https://github.com/openhwgroup/cva6/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/openhwgroup/cva6/actions/workflows/ci.yml) [![CVA6 dashboard](https://riscv-ci.pages.thales-invia.fr/dashboard/badge_master.svg)](https://riscv-ci.pages.thales-invia.fr/dashboard/dashboard_cva6.html) [![Documentation Status](https://readthedocs.com/projects/openhw-group-cva6-user-manual/badge/?version=latest)](https://docs.openhwgroup.org/projects/cva6-user-manual/?badge=latest) [![GitHub release](https://img.shields.io/github/release/openhwgroup/cva6?include_prereleases=&sort=semver&color=blue)](https://github.com/openhwgroup/cva6/releases/)

# 🚀 CVA6 Branch Predictor Extension (GShare & TAGE)

This repository implements an enhanced Branch Prediction Unit for the CVA6 (formerly Ariane) open-source RISC-V core.

The project extends the CVA6 frontend architecture by integrating high-performance **GShare** and **TAGE (Tagged Geometric History Length)** branch predictors.

The predictors are evaluated using both microbenchmarks and application benchmarks to analyze their impact on branch prediction accuracy and overall CPU performance.

The goal is to improve processor performance by increasing **IPC (Instructions Per Cycle)** and reducing **branch misprediction penalties**.

## Overview

This project extends the branch prediction unit of the CVA6 open-source RISC-V processor by implementing **GShare** and **TAGE** branch predictors.

The implementation focuses primarily on modifications to the **frontend stage** of the processor pipeline.

For details about the original architecture, refer to the official CVA6 repository.

Original CVA6 repository:  
https://github.com/openhwgroup/cva6

---

## Modified Components

The branch predictor implementation required modifications to several frontend components:
- `core/cva6.sv`
- `core/branch_unit.sv`
- `core/include/ariane_pkg.sv`
- `core/include/build_config_pkg.sv`
- `core/include/config_pkg.sv`
- `core/frontend/frontend.sv`
- `core/frontend/instr_queue.sv`
- `core/frontend/GShareTable.sv`
- `core/frontend/TageBaseTable.sv`
- `core/frontend/TageTable.sv`

## Branch Predictor Configuration

Branch predictor parameters can be configured by modifying the following files:

- `core/include/cv32a60x_config_pkg.sv`
- `core/include/cv32a65x_config_pkg.sv`

Currently, the implementation supports the **cv32a60x** and **cv32a65x** configurations.

Support for additional CVA6 configurations will be extended in future work.

# Implemented Predictors

## Baseline BHT 
(Implemented in Original CVA6 core, https://github.com/openhwgroup/cva6)
- 2-bit saturating counter predictor
- Indexed using PC bits
- Serves as the baseline predictor

---

## GShare Predictor

GShare uses global branch history to improve prediction accuracy.

Key features:

- Global History Register (GHR)
- Index = PC XOR GHR
- Reduces aliasing compared to simple BHT

---

## TAGE Predictor

TAGE (Tagged Geometric History Length) is a state-of-the-art branch predictor.

Features:

- Base predictor
- Multiple tagged predictor tables
- Different history lengths
- Tag matching for accurate prediction

TAGE is able to capture **long branch correlations**, which improves prediction accuracy.

---

# Benchmark Methodology

Two types of benchmarks are used for evaluation.

## Microbenchmarks

Designed to stress specific branch patterns.

- **Aliasing**
- **Alternating Pattern**
- **Correlated Branch**
- **Correlated Periodic**
- **Periodic Pattern**

These tests highlight differences between branch predictors.

---

## Application Benchmarks

Real workloads with control-flow intensive behavior.

- **Binary Search**
- **N-Queens**
- **QuickSort**

These workloads show practical performance improvements.

---

# Evaluation Metrics

Two metrics are used.

## Branch Miss Rate

Percentage of branch mispredictions.

Lower miss rate indicates better prediction accuracy.

---

## IPC (Instructions Per Cycle)

IPC measures overall processor performance.

Branch mispredictions cause pipeline flushes, which reduce IPC.

Improved prediction accuracy leads to higher IPC.

---

# Results

## Normalized IPC

![IPC Results](results/ipc_results.png)

TAGE significantly improves performance for branch-heavy workloads such as **alternating and correlated patterns**.

---

## Branch Miss Rate

![Miss Rate](results/miss_rate_results.png)

TAGE achieves the lowest miss rate due to its ability to capture long branch history patterns.

---

# Repository Structure


