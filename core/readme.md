
# 🚀 TAGE Branch Predictor for CVA6

This document describes the **architecture and functional behavior of the TAGE branch predictor integrated into the CVA6 core**.  
The explanation focuses on the **prediction stage (fetch time)** and the **resolution stage (execute time)**.

---

# 🧠 TAGE Predictor Architecture

<p align="center">
<img width="1231" height="652" alt="image" src="https://github.com/user-attachments/assets/7be3d6bb-aac4-4bbe-9cd1-72cde7e4df21" >
</p>

The **TAGE (TAgged GEometric history length) predictor** improves branch prediction accuracy by using **multiple predictor tables with different global history lengths**.

Each table captures correlations at **different history depths**, allowing the predictor to learn both **short-term and long-term branch behavior**.

The architecture implemented in this project consists of:

| Component | Description |
|----------|-------------|
| **BHT (Base Predictor)** | A simple PC-indexed 2-bit saturating counter predictor used as the fallback prediction source. |
| **TAGE Tables (T1 ~ T4)** | Multiple tagged predictor tables indexed using hashed PC and folded global history. |
| **Global History Register (GHR)** | Stores recent branch outcomes and is used to compute table indices and tags. |
| **Folded History Registers** | Compress long global history into smaller widths suitable for indexing/tag generation. |
| **Prediction Selector** | Chooses the prediction from the longest matching table with a valid tag. |

The predictor searches **all tables in parallel** during the fetch stage.

---

# 🔮 Prediction Stage (Fetch)

During instruction fetch, the predictor performs the following steps:

### 1️⃣ Parallel Table Lookup

For an incoming **PC**, the predictor computes:

- **Index**
- **Tag**

for each TAGE table using:
