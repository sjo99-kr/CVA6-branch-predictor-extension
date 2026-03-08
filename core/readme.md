
# 🚀 TAGE Branch Predictor for CVA6

This document describes the **architecture and functional behavior of the TAGE branch predictor integrated into the CVA6 core**.  
The explanation focuses on the **prediction stage (fetch time)** and the **resolution stage (execute time)**.

---

## 🧠 TAGE Predictor Architecture

<p align="center">
<img width="1231" height="652" alt="image" src="https://github.com/user-attachments/assets/7be3d6bb-aac4-4bbe-9cd1-72cde7e4df21" >
</p>

The **TAGE (TAgged GEometric history length) predictor** improves branch prediction accuracy by using **multiple predictor tables with different global history lengths**.

Each table captures correlations at **different history depths**, allowing the predictor to learn both **short-term and long-term branch behavior**.

The architecture implemented in this project consists of:

| Component | Description |
|----------|-------------|
| **BHT (Base Predictor)** | A simple PC-indexed predictor using a **2-bit saturating counter**, serving as the fallback prediction source when no tagged table provides a valid match. |
| **TAGE Tables (T1–T4)** | Multiple tagged predictor tables indexed using a combination of the **program counter (PC)** and **folded global history**, each table using a different history length. |
| **Global History Register (GHR)** | Records the outcomes of recent branches and is used to compute indices and tags for the TAGE tables. It is implemented as a **circular shift register**. |
| **Folded Index and Tag Registers** | Compressed representations of the global history used to generate **table indices and tags**. These folded histories are implemented using **circular shift registers**. |
| **Table Allocation & Useful Bit Controller** | Manages entry allocation in TAGE tables and updates the **useful bits (u-bits)** based on prediction correctness to control entry replacement. |
| **Checkpoint Queue** | Stores the indices and tags of all TAGE tables for speculative branch instructions. The stored information is used to update the predictor state when the branch is resolved. |
| **Prediction Selector** | Selects the final prediction using the **alternative prediction policy**, choosing between the provider table and an alternative prediction when the provider confidence is low. |

### 📦 Table Entry Structure

#### Table 0 (Base Predictor)
- **2-bit Saturating Counter**  
  Incremented when the branch is **taken** and decremented when the branch is **not taken**.
  
- **Valid Bit**  
  Indicates whether the entry contains a valid prediction.  
  If the entry is not valid, the predictor falls back to **static branch prediction**.
  
#### Table 1–3 (Tagged TAGE Tables)
- **2-bit Saturating Counter**  
  Incremented when the branch is **taken** and decremented when the branch is **not taken**.

- **Valid Bit**  
  Indicates whether the predictor entry is valid.  
  If the entry is not valid, the predictor falls back to **static branch prediction**.

- **Tag**  
  Stores the tag used to verify whether the table entry corresponds to the current branch PC.

- **Useful Bit (u-bit)**  
  Indicates whether the entry has been useful for correct predictions.  
  If the useful bit is **0**, the entry becomes a candidate for **replacement**.


---

### 📦 Table Index and Tag Hashing Functions

| Parameter | Description |
|-----------|-------------|
| `NR_ENTRY` | Number of entries in the predictor table |
| `OFFSET` | Instruction alignment offset for PC indexing |
| `TABLE_N_TAG_WIDTH` | Tag width for table *N* |
| `Table_N_Folded_Index` | Folded global history used for index hashing |
| `Table_N_Folded_Tag` | Folded global history used for tag generation |

The TAGE predictor generates **table indices and tags** using a combination of the **program counter (PC)** and **folded global history**.

**Table_Index = PC ⊕ FoldedHistory (Folded Index)**

**Table_Tag   = PC ⊕ FoldedHistory (Folded Tag)**

---

### 🔮 Prediction Selection

The final branch prediction is determined through a **two-stage selection process**.

#### 1️⃣ Champion Detection

The predictor first checks whether a **champion prediction** exists.  
A champion indicates that the prediction confidence is sufficiently high.

If a champion is detected, the prediction from that table can be selected as the **final prediction**, even if the table has **lower priority (shorter history length)**.


#### 2️⃣ Table Priority Selection

If no champion prediction exists, the predictor selects the prediction from the **highest-priority table**.

Since TAGE tables are organized by **increasing history length**, tables with **longer history** have higher priority.

Therefore, the final prediction is taken from the **highest-level table with a valid prediction**.

---

## 📦 Checkpoint Queue 
<img width="1212" height="614" alt="image" src="https://github.com/user-attachments/assets/b98e6da8-6c6d-4740-9297-1535eecb6a47" />

The **Checkpoint Queue** is implemented as a **circular queue**, indexed by the **Branch Instruction ID (Branch ID)**.  
Each entry stores the necessary information required to **update the TAGE tables when a speculative branch is resolved**.

### Checkpoint Queue Entry Components

#### TAGE Table Information (Table 1–3)

Each checkpoint entry stores the following information for every tagged TAGE table:

- **Folded Index / Tag**  
  Folded history values used for computing the **predicted index and tag**.

- **Predicted Index / Tag**  
  The actual **index and tag values** used when predicting the branch instruction.

#### Metadata

- **TAGE Table Valid**  
  Valid signals from all **TAGE tables (Table 1–3)** indicating whether each table produced a valid prediction.

- **TAGE Table Prediction**  
  Prediction results (**Taken / Not Taken**) from all **TAGE tables (Table 1–3)**.  

---

