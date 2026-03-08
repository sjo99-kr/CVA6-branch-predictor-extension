# 🚀 CVA6 Branch Predictor Extension (GShare & TAGE)

This repository implements an enhanced Branch Prediction Unit for the **CVA6 (formerly Ariane)** open-source RISC-V core.

The project extends the **CVA6 frontend architecture** by integrating high-performance **GShare** and **TAGE (Tagged Geometric History Length)** branch predictors.

The predictors are evaluated using both **microbenchmarks** and **application benchmarks** to analyze their impact on branch prediction accuracy and overall CPU performance.

The goal is to improve processor performance by increasing **IPC (Instructions Per Cycle)** and reducing **branch misprediction penalties**.

---

## 🧩 Overview

This project extends the branch prediction unit of the **CVA6 open-source RISC-V processor** by implementing **GShare** and **TAGE** branch predictors.

The implementation focuses primarily on modifications to the **frontend stage of the processor pipeline**.

For details about the original architecture, refer to the official CVA6 repository.

Original CVA6 repository:  
https://github.com/openhwgroup/cva6

---

## ⚙️ Modified Components

The branch predictor implementation required modifications to several frontend and core pipeline components:

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

---

## 🔧 Branch Predictor Configuration

Branch predictor parameters can be configured by modifying the following files:

- `core/include/cv32a60x_config_pkg.sv`
- `core/include/cv32a65x_config_pkg.sv`

Currently, the implementation supports the **cv32a60x** and **cv32a65x** configurations.

Support for additional CVA6 configurations will be extended in future work.

---

# 📊 Evaluation

## 🧮 Hardware Cost Comparison

| Branch Predictor | Num. of Tables | Num. of Entries | Bits per Entry | Total Cost (Bytes) |
|-----------------|---------------|----------------|---------------|-------------------|
| Baseline (BHT) | 1 | 8192 | 2-bit counter + 1-bit valid | 3,072 B |
| GShare | 1 | 8192 | 2-bit counter + 1-bit valid | 3,072 B |
| TAGE | 4 | 64 / 256 / 512 / 1024 | 2-bit counter/useful + 1-bit valid + tag (0/4/6/8 bit) | 2,696 B |

**For detailed architectural specifications of the TAGE branch predictor, refer to the README.md in the core directory.**

---

## 🧪 Benchmark Methodology

Two types of benchmarks are used for evaluation.

### Microbenchmarks

Synthetic workloads designed to stress specific branch behavior patterns.

- **Aliasing**  
  Evaluates how different predictors handle destructive aliasing caused by multiple branches mapping to the same prediction entries.

- **Alternating Pattern**  
  Tests the ability of predictors to learn regular alternating branch patterns (taken/not-taken).

- **Correlated Branch**  
  Measures how well predictors capture inter-branch correlations using global history information.

- **Correlated Periodic**  
  Evaluates the effectiveness of predictors in recognizing long periodic branch patterns generated from multiple correlated conditions.

---

### Application Benchmarks

Real workloads with control-flow intensive behavior.

- **Binary Search**  
  Evaluates prediction accuracy for nested conditional branches commonly found in search algorithms.

- **N-Queens**  
  Generates complex branch behavior due to recursive backtracking and deep control-flow exploration.

- **QuickSort**  
  Tests predictor performance on recursive divide-and-conquer algorithms with data-dependent branching.

---

## 📈 Performance Results

### Normalized IPC

<img width="800" height="300" alt="image" src="https://github.com/user-attachments/assets/464c6a1a-0e8e-45d4-9b0d-cad695d0d82b" />

The figure shows the normalized IPC improvement of different branch predictors across microbenchmarks and application benchmarks.

GShare and TAGE significantly improve performance compared to the baseline BHT, particularly for structured branch patterns such as alternating and correlated branches.

The effectiveness of TAGE can vary depending on the hashing scheme and the number of tag/index bits, which influence the level of aliasing in prediction tables.

---

### Branch Miss Rate

<img width="800" height="300" alt="image" src="https://github.com/user-attachments/assets/c6102838-5a17-4ee3-90b9-823a10c411d2" />

The figure shows the branch miss rate across different predictors.

GShare and TAGE significantly outperform the baseline BHT for structured branch patterns, demonstrating the benefits of history-based branch prediction mechanisms.

The performance gap varies across applications due to differences in branch patterns and aliasing behavior within the predictor tables.
