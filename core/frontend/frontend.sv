// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Date: 08.02.2018
// Description: Ariane Instruction Fetch Frontend
//
// This module interfaces with the instruction cache, handles control
// change request from the back-end and does branch prediction.

module frontend
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type bp_resolve_t = logic,
    parameter type fetch_entry_t = logic,
    parameter type icache_dreq_t = logic,
    parameter type icache_drsp_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Next PC when reset - SUBSYSTEM
    input logic [CVA6Cfg.VLEN-1:0] boot_addr_i,
    // Flush branch prediction - zero
    input logic flush_bp_i,
    // Flush requested by FENCE, mis-predict and exception - CONTROLLER
    input logic flush_i,
    // Halt requested by WFI and Accelerate port - CONTROLLER
    input logic halt_i,
    // Halt frontend - CONTROLLER (in the case of fence_i to avoid fetching an old instruction)
    input logic halt_frontend_i,
    // Set COMMIT PC as next PC requested by FENCE, CSR side-effect and Accelerate port - CONTROLLER
    input logic set_pc_commit_i,
    // COMMIT PC - COMMIT
    input logic [CVA6Cfg.VLEN-1:0] pc_commit_i,
    // Exception event - COMMIT
    input logic ex_valid_i,
    // Mispredict event and next PC - EXECUTE
    input bp_resolve_t resolved_branch_i,
    // Return from exception event - CSR
    input logic eret_i,
    // Next PC when returning from exception - CSR
    input logic [CVA6Cfg.VLEN-1:0] epc_i,
    // Next PC when jumping into exception - CSR
    input logic [CVA6Cfg.VLEN-1:0] trap_vector_base_i,
    // Debug event - CSR
    input logic set_debug_pc_i,
    // Debug mode state - CSR
    input logic debug_mode_i,
    // Handshake between CACHE and FRONTEND (fetch) - CACHES
    output icache_dreq_t icache_dreq_o,
    // Handshake between CACHE and FRONTEND (fetch) - CACHES
    input icache_drsp_t icache_dreq_i,
    // Handshake's data between fetch and decode - ID_STAGE
    output fetch_entry_t [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_o,
    // Handshake's valid between fetch and decode - ID_STAGE
    output logic [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_valid_o,
    // Handshake's ready between fetch and decode - ID_STAGE
    input logic [CVA6Cfg.NrIssuePorts-1:0] fetch_entry_ready_i
);

  localparam type bht_update_t = struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] pc;     // update at PC
    logic                    taken;
  };

  // GSHARE Table Update Struct Type
  localparam type gshare_update_t = struct packed {
    logic                     valid;
    logic [CVA6Cfg.VLEN-1:0]  pc;
    logic                     taken;
    logic [CVA6Cfg.GSHAREWIDTH-1:0] index;
  };

  // TAGE Table Update Struct Type
  localparam type tage_update_t = struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] pc;
    logic                    taken;
    logic                    miss;
  };

  localparam type btb_prediction_t = struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] target_address;
  };

  localparam type btb_update_t = struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] pc;              // update at PC
    logic [CVA6Cfg.VLEN-1:0] target_address;
  };

  localparam type ras_t = struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] ra;
  };

  // Instruction Cache Registers, from I$
  logic                            [    CVA6Cfg.FETCH_WIDTH-1:0] icache_data_q; // FETHCH 
  logic                                                          icache_valid_q;
  ariane_pkg::frontend_exception_t                               icache_ex_valid_q;
  logic                            [           CVA6Cfg.VLEN-1:0] icache_vaddr_q;
  logic                            [          CVA6Cfg.GPLEN-1:0] icache_gpaddr_q;
  logic                            [                       31:0] icache_tinst_q;
  logic                                                          icache_gva_q;
  logic                                                          instr_queue_ready;
  logic                            [CVA6Cfg.INSTR_PER_FETCH-1:0] instr_queue_consumed;


  // GSHARE PREDICTION STRUCT TYPE
  localparam type gshare_prediction_t = struct packed {
      logic valid;
      logic taken;
      logic [$clog2(CVA6Cfg.GshareNrEntires / CVA6Cfg.INSTR_PER_FETCH)-1:0] index; 
  };

  // upper-most branch-prediction from last cycle
  btb_prediction_t                                               btb_q;
  bht_prediction_t                                               bht_q;
  gshare_prediction_t                                            gshare_q;

  // instruction fetch is ready
  logic                                                          if_ready;
  logic [CVA6Cfg.VLEN-1:0] npc_d, npc_q;  // next PC

  // indicates whether we come out of reset (then we need to load boot_addr_i)
  logic                                       npc_rst_load_q;

  logic                                       replay;
  logic [                   CVA6Cfg.VLEN-1:0] replay_addr;

  // shift amount
  logic [$clog2(CVA6Cfg.INSTR_PER_FETCH)-1:0] shamt;
  // address will always be 16 bit aligned, make this explicit here
  if (CVA6Cfg.RVC) begin : gen_shamt
    assign shamt = icache_dreq_i.vaddr[$clog2(CVA6Cfg.INSTR_PER_FETCH):1];
  end else begin
    assign shamt = 1'b0;
  end

  // -----------------------
  // Ctrl Flow Speculation
  // -----------------------
  // RVI ctrl flow prediction
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] rvi_return, rvi_call, rvi_branch, rvi_jalr, rvi_jump; // From Instruction Scan
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] rvi_imm;                            // Instruction Immediate 
  // RVC branching
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] rvc_branch, rvc_jump, rvc_jr, rvc_return, rvc_jalr, rvc_call;
  logic            [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] rvc_imm;
  // re-aligned instruction and address (coming from cache - combinationally)
  logic            [CVA6Cfg.INSTR_PER_FETCH-1:0][            31:0] instr;
  logic            [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] addr;
  logic            [CVA6Cfg.INSTR_PER_FETCH-1:0]                   instruction_valid;

  // BHT, BTB and RAS prediction 
  bht_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0]                   bht_prediction;
  btb_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0]                   btb_prediction;

  // GSHARE PREDICTION
  gshare_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0]                gshare_prediction;
  gshare_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0]                gshare_prediction_shifted;

  bht_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0]                   bht_prediction_shifted;
  btb_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0]                   btb_prediction_shifted;
  


  ras_t                                                            ras_predict;
  logic            [           CVA6Cfg.VLEN-1:0]                   vpc_btb;
  logic            [           CVA6Cfg.VLEN-1:0]                   vpc_bht;

  // TAGE PREDICTION
  logic            [           CVA6Cfg.VLEN-1:0]                   vpc_tage;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0]            vpc_tage_shifted;    // deprecated
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0]            vpc_tage_shifted_q;  // deprecated

  // GSHARE PREDICTION
  logic            [           CVA6Cfg.VLEN-1:0]                   vpc_gshare;

  // branch-predict update
  logic                                                            is_mispredict;
  logic ras_push, ras_pop;
  logic [           CVA6Cfg.VLEN-1:0] ras_update;

  // Instruction FIFO
  logic [           CVA6Cfg.VLEN-1:0] predict_address;
  cf_t  [CVA6Cfg.INSTR_PER_FETCH-1:0] cf_type;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] taken_rvi_cf;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] taken_rvc_cf;

  logic                               serving_unaligned;


  // TAGE PREDICTION
  // Signals for detecting branch instruction candidates and taken/not-taken results per instruction
    logic [CVA6Cfg.INSTR_PER_FETCH-1:0] GHRUpdate, GHRValue;

  // Signals indicating unconditional instructions in a fetch bundle (Both for TAGE and GSHARE PREDICTOR)
    logic [CVA6Cfg.INSTR_PER_FETCH-1:0] GHRJump;
    logic [CVA6Cfg.INSTR_PER_FETCH-1:0] GShareJump;
  
  // Index value for GHRUpdate, GHRValue, GHRJump.
    int ghr_index;
  
  // Struct type for the first TAGE Checkpoint table
  // Tage Index/Tage  -> Index and Tag value for updating.
  // Folded Index/Tag -> Rollback Folded Index and Tag.
    localparam type OneTageEntry = struct packed {
      logic [CVA6Cfg.OneTageIndexWidth -1:0] TageIndex;
      logic [CVA6Cfg.OneTageIndexWidth -1:0] foldedIndex;
      logic [CVA6Cfg.OneTageTagWidth   -1:0] TageTag;
      logic [CVA6Cfg.OneTageTagWidth   -1:0] foldedTag;
    };

  // Struct type for the second TAGE Checkpoint table
    localparam type TwoTageEntry = struct packed {
      logic [CVA6Cfg.TwoTageIndexWidth -1:0] TageIndex;
      logic [CVA6Cfg.TwoTageIndexWidth -1:0] foldedIndex;
      logic [CVA6Cfg.TwoTageTagWidth   -1:0] TageTag;
      logic [CVA6Cfg.TwoTageTagWidth   -1:0] foldedTag;
    };


  // Struct type for the third TAGE Checkpoint table
    localparam type ThreeTageEntry = struct packed {
      logic [CVA6Cfg.ThreeTageIndexWidth -1:0] TageIndex;
      logic [CVA6Cfg.ThreeTageIndexWidth -1:0] foldedIndex;
      logic [CVA6Cfg.ThreeTageTagWidth   -1:0] TageTag;
      logic [CVA6Cfg.ThreeTageTagWidth   -1:0] foldedTag;
    };

  // Struct type for the TAGE Checkpoint table containing entries from the first, second, and third tables
    localparam type TageCheckPointEntry = struct packed {
      OneTageEntry OneTage;
      TwoTageEntry TwoTage;
      ThreeTageEntry ThreeTage;
      logic [CVA6Cfg.TageTableWidth-1:0] pred;          // Prediction result of each table
      logic [CVA6Cfg.TageTableWidth-1:0] valid;         // Tag/Index Matching Success/Fail
      logic [$clog2(CVA6Cfg.BranchTidWidth)-1:0] bid;   // Branch ID for checkpoint entry
    };
    
  // Signals for TAGE update (backup of branch prediction results)
  // Update is required separately across all tables.
    tage_update_t [CVA6Cfg.TageTableWidth-1:0] tage_update;
    gshare_update_t gshare_update;

  // Checkpoint entry used for TAGE Checkpoint
    TageCheckPointEntry [CVA6Cfg.BranchTidWidth-1:0] TageCheckPointQueue_q;

  // Global Histroy Register (GHR) for TAGE Predictor.
    logic [CVA6Cfg.GHRWIDTH-1:0] GlobalHistoryRegister; 
  
  // Global History Register for GShare Predictor
    logic [CVA6Cfg.GSHAREWIDTH-1:0] GShareHistoryRegister, GShareHistoryRegister_q;

  // Signals for branchInCnt and BranchIDCnt, used for instructions with conditional branches
    logic [$clog2(CVA6Cfg.BranchTidWidth)-1:0] BranchIdCnt_q;           
    logic [CVA6Cfg.INSTR_PER_FETCH-1:0][$clog2(CVA6Cfg.BranchTidWidth)-1:0] BranchIdCnt_d;  // Each instr. has their own branch ID.

  // Signals used to select conditional branch instructions in the fetch batch that are actually executed.
  // The order of instr. in BranchCntValid follows  N'{N-1 Instr, N-2 Instr ...., second instr, first instr}
    logic [CVA6Cfg.INSTR_PER_FETCH-1:0] BranchCntValid;

  // Prediction signals from the base TAGE table
    tage_table_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0] BaseTageTablePrediction;
  // Signals for Unaligned case in Instr. fetch.
    tage_table_prediction_t BaseTageTablePrediction_q;

  // Prediction signals from the first TAGE table
    tage_table_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0] OneTageTablePrediction;
  // Signals for Unaligned case in Instr. fetch.
    tage_table_prediction_t OneTageTablePrediction_q;

  // Prediction signals from the second TAGE table
    tage_table_prediction_t  [CVA6Cfg.INSTR_PER_FETCH-1:0] TwoTageTablePrediction;
  // Signals for Unaligned case in Instr. fetch.
    tage_table_prediction_t TwoTageTablePrediction_q;

  // Prediction signals from the third TAGE table
    tage_table_prediction_t  [CVA6Cfg.INSTR_PER_FETCH-1:0] ThreeTageTablePrediction;
  // Signals for Unaligned case in Instr. fetch.
    tage_table_prediction_t ThreeTageTablePrediction_q;

  // Signals for folded index/tag, resolved index/tag (rollback), and prediction index/tag (checkpoint) in TAGE table 1
    logic [CVA6Cfg.OneTageIndexWidth  -1:0]   OneTageFoldedIndex, OneTageResolveIndex, OneTagePredictIndex, OneTagePredictIndex_q, OneTageResFoldedIndex;

    logic [CVA6Cfg.OneTageTagWidth    -1:0]   OneTageFoldedTag, OneTageResolveTag, OneTagePredictTag, OneTagePredictTag_q, OneTageResFoldedTag;

  // Signals for folded index/tag, resolved index/tag (rollback), and prediction index/tag (checkpoint) in TAGE table 2
    logic [CVA6Cfg.TwoTageIndexWidth  -1:0]   TwoTageFoldedIndex, TwoTageResolveIndex, TwoTagePredictIndex, TwoTagePredictIndex_q, TwoTageResFoldedIndex;
    logic [CVA6Cfg.TwoTageTagWidth    -1:0]   TwoTageFoldedTag, TwoTageResolveTag, TwoTagePredictTag, TwoTagePredictTag_q, TwoTageResFoldedTag;

  // Signals for folded index/tag, resolved index/tag (rollback), and prediction index/tag (checkpoint) in TAGE table 3
    logic [CVA6Cfg.ThreeTageIndexWidth-1:0]   ThreeTageFoldedIndex, ThreeTageResolveIndex, ThreeTagePredictIndex, ThreeTagePredictIndex_q, ThreeTageResFoldedIndex;
    logic [CVA6Cfg.ThreeTageTagWidth  -1:0]   ThreeTageFoldedTag, ThreeTageResolveTag, ThreeTagePredictTag, ThreeTagePredictTag_q, ThreeTageResFoldedTag;



  // Per-instruction speculative GHR values used for branch prediction within a fetch bundle.
    logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.GHRWIDTH-1:0] GHRegInstr;

  // Per-instruction speculative folded Index/tag values of first tage table used for branch prediction within a fetch bundle.
    logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.OneTageIndexWidth-1:0] OneTageFoldedIndexInstr;
    logic [CVA6Cfg.OneTageIndexWidth-1:0] OneTageFoldedIndexInstr_q;
    logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.OneTageTagWidth-1:0] OneTageFoldedTagInstr;
    logic [CVA6Cfg.OneTageTagWidth-1:0] OneTageFoldedTagInstr_q;

  // Per-instruction speculative folded Index/tag values of second tage table used for branch prediction within a fetch bundle.
    logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.TwoTageIndexWidth-1:0] TwoTageFoldedIndexInstr;
    logic [CVA6Cfg.TwoTageIndexWidth-1:0] TwoTageFoldedIndexInstr_q;
    logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.TwoTageTagWidth-1:0] TwoTageFoldedTagInstr;
    logic [CVA6Cfg.TwoTageTagWidth-1:0] TwoTageFoldedTagInstr_q
    ;
  // Per-instruction speculative folded Index/tag values of third tage table used for branch prediction within a fetch bundle.
    logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.ThreeTageIndexWidth-1:0] ThreeTageFoldedIndexInstr;
    logic [CVA6Cfg.ThreeTageIndexWidth-1:0] ThreeTageFoldedIndexInstr_q;
    logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.ThreeTageTagWidth-1:0] ThreeTageFoldedTagInstr;
    logic [CVA6Cfg.ThreeTageTagWidth-1:0] ThreeTageFoldedTagInstr_q;


  // Final prediction selected from multiple TAGE tables.
    tage_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0] tage_prediction, tage_prediction_shifted;

  // Signals for allocating an entry in the next TAGE table on misprediction
    logic [CVA6Cfg.TageTableWidth-1:0] TageAllocation; 

  // Per-instruction TAGE prediction results in a fetch: valid, taken, and champion (confidence for alternative prediction)
    logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.TageTableWidth-1:0] TageTableValid, TageTableTaken, TageTableChampion;



    
  
    
  // Offset for Compressed Instructions.
    localparam OFFSET = CVA6Cfg.RVC == 1'b1 ? 1 : 2;
  // If compressed instr., then Row Index bits => 1, else then 0.
    localparam ROW_INDEX_BITS = CVA6Cfg.RVC == 1'b1 ? $clog2(CVA6Cfg.INSTR_PER_FETCH) : 1;
    localparam ROW_ADDR_BITS = $clog2(CVA6Cfg.INSTR_PER_FETCH);
  
  // Indicates whether prior predictions are valid and should be used to update the TAGE tables.
    logic [CVA6Cfg.TageTableWidth-1:0] TageResolveValid;

  // Indicates whether prior predictions are miss and should be used to update the TAGE tables.
    logic [CVA6Cfg.TageTableWidth-1:0] TageTableMiss;

    always_comb begin : TageTableUpdateSetup
      for(int unsigned i = 0; i < CVA6Cfg.TageTableWidth; i++)begin
        tage_update[i].valid = TageResolveValid[i];
        tage_update[i].pc    = resolved_branch_i.pc;
        tage_update[i].taken = resolved_branch_i.is_taken;
        tage_update[i].miss  = TageTableMiss[i];
      end
    end : TageTableUpdateSetup

  // Re-align instructions
  instr_realign #(
      .CVA6Cfg(CVA6Cfg)
  ) i_instr_realign (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .flush_i            (icache_dreq_o.kill_s2),
      .valid_i            (icache_valid_q),
      .address_i          (icache_vaddr_q),
      .data_i             (icache_data_q),

      .serving_unaligned_o(serving_unaligned),
      .valid_o            (instruction_valid),
      .addr_o             (addr),
      .instr_o            (instr)
  );

  // --------------------
  // Branch Prediction
  // --------------------
  // select the right branch prediction result
  // in case we are serving an unaligned instruction in instr[0] we need to take
  // the prediction we saved from the previous fetch
  if (CVA6Cfg.RVC) begin : gen_btb_prediction_shifted
    assign bht_prediction_shifted[0]    = (serving_unaligned) ? bht_q : bht_prediction[addr[0][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]];
    assign btb_prediction_shifted[0]    = (serving_unaligned) ? btb_q : btb_prediction[addr[0][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]];
    assign gshare_prediction_shifted[0] = (serving_unaligned) ? gshare_q : gshare_prediction[addr[0][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]];

    // for all other predictions we can use the generated address to index
    // into the branch prediction data structures
    for (genvar i = 1; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_prediction_address
      assign bht_prediction_shifted[i] = bht_prediction[addr[i][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]];
      assign btb_prediction_shifted[i] = btb_prediction[addr[i][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]];
      assign gshare_prediction_shifted[i] = gshare_prediction[addr[i][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]];
    end
  end else begin
    assign bht_prediction_shifted[0]    = (serving_unaligned) ? bht_q : bht_prediction[addr[0][1]];
    assign btb_prediction_shifted[0]    = (serving_unaligned) ? btb_q : btb_prediction[addr[0][1]];
    assign gshare_prediction_shifted[0] = (serving_unaligned) ? gshare_q : gshare_prediction[addr[0][1]];
  end

  //  Remaps TAGE predictions to the correct instruction slot in the fetch bundle using PC bits, 
  //  ensuring each fetched instruction receives the appropriate prediction when multiple instructions are fetched.  
  if(CVA6Cfg.TageEn) begin : TagePredictionRemap
    if (CVA6Cfg.RVC) begin
      assign tage_prediction_shifted[0] = (serving_unaligned && is_branch[0]) ? tage_prediction[0] : tage_prediction[addr[0][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]]; 
      for(genvar i = 1; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
        assign tage_prediction_shifted[i] = tage_prediction[addr[i][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]];
      end
    end else begin
      assign tage_prediction_shifted[0] = tage_prediction[addr[0][1]];
    end
  end : TagePredictionRemap
  

  // Prior vpc_tage address used for updating and rolling back the TAGE table.
  // Required only for the base TAGE table, which performs prediction using the PC index without a tag.
  // This one can be deprecated, we can use addr[i], instead of vpc_tage_shifted/vpc_tage_shifted_q
  always_comb begin : RollbackTageAddress
    for(int p = 0; p < CVA6Cfg.INSTR_PER_FETCH; p++) begin
      vpc_tage_shifted[p] = vpc_tage_shifted_q[p];
      if(|BranchCntValid) begin
        if(serving_unaligned && p == 0) begin
          vpc_tage_shifted[0] = vpc_tage - 2;
        end else begin
          vpc_tage_shifted[p] = vpc_tage; 
        end
      end
    end
  end : RollbackTageAddress
  

  // for the return address stack it doesn't matter as we have the
  // address of the call/return already
  logic bp_valid;

  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] is_branch;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] is_call;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] is_jump;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] is_return;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0] is_jalr;

  for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : SetupControlFlow
    // branch history table -> BHT
    assign is_branch[i] = instruction_valid[i] & (rvi_branch[i] | rvc_branch[i]);
    // function calls -> RAS
    assign is_call[i] = instruction_valid[i] & (rvi_call[i] | rvc_call[i]);
    // function return -> RAS
    assign is_return[i] = instruction_valid[i] & (rvi_return[i] | rvc_return[i]);
    // unconditional jumps with known target -> immediately resolved
    assign is_jump[i] = instruction_valid[i] & (rvi_jump[i] | rvc_jump[i]);
    // unconditional jumps with unknown target -> BTB
    assign is_jalr[i] = instruction_valid[i] & ~is_return[i] & (rvi_jalr[i] | rvc_jalr[i] | rvc_jr[i]);
  end : SetupControlFlow


  always_comb begin : TakenOrNotTakenSetup
    taken_rvi_cf = '0;
    taken_rvc_cf = '0;
    predict_address = '0;

    // Initialization for TAGE/GSHARE-related signals.
    GHRUpdate   = '0;
    GHRValue    = '0;
    GHRJump     = '0;
    GShareJump  = '0;

    // Since the following loop processes instructions from last to first,
    // ghr_index indicates the instruction order in the fetch bundle.
    // So the order of GHRupdate, GHRValue, GHR Jump, if there are N numbers of Instr. in fetch bundle,
    //  N'{First instr, second instr, ..., N-1 instr, N instr.}
    ghr_index     = 0;
  
    for (int i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) cf_type[i] = ariane_pkg::NoCF;

    ras_push = 1'b0;
    ras_pop = 1'b0;
    ras_update = '0;
    
    // lower most prediction gets precedence
    for (int i = CVA6Cfg.INSTR_PER_FETCH - 1; i >= 0; i--) begin
      unique case ({
        is_branch[i], is_return[i], is_jump[i], is_jalr[i]
      })
        4'b0000:  begin 
          ghr_index = ghr_index + 1;  // regular instruction e.g.: no branch
        end
        // unconditional jump to register, we need the BTB to resolve this
        4'b0001: begin : UnconditionalJUMP_REG
          ras_pop  = 1'b0;
          ras_push = 1'b0;
          if (CVA6Cfg.BTBEntries != 0 && btb_prediction_shifted[i].valid) begin
            predict_address = btb_prediction_shifted[i].target_address;
            cf_type[i] = ariane_pkg::JumpR;
            // If UnconditioanlJump Reg, then check the order of instr. in GHRJump.
            GHRJump[ghr_index] = 1; 
            GShareJump[i] = 1;
          end
          ghr_index = ghr_index + 1;
        end : UnconditionalJUMP_REG

        // its an unconditional jump to an immediate
        4'b0010: begin : UnconditionalJUMP_IMME
          ras_pop = 1'b0;
          ras_push = 1'b0;
          taken_rvi_cf[i] = rvi_jump[i];
          taken_rvc_cf[i] = rvc_jump[i];
          cf_type[i] = ariane_pkg::Jump;
          // If UnconditioanlJump Reg, then check the order of instr. in GHRJump.
          GHRJump[ghr_index] = 1; 
          GShareJump[i] = 1;
          ghr_index = ghr_index + 1;
        end : UnconditionalJUMP_IMME

        // return
        4'b0100: begin : ReturnCase
          // make sure to only alter the RAS if we actually consumed the instruction
          ras_pop = ras_predict.valid & instr_queue_consumed[i];
          ras_push = 1'b0;
          predict_address = ras_predict.ra;
          cf_type[i] = ariane_pkg::Return;
          // If UnconditioanlJump Reg, then check the order of instr. in GHRJump.
          GHRJump[ghr_index] = 1; 
          GShareJump[i] = 1;
          ghr_index = ghr_index + 1;
        end : ReturnCase

        // branch prediction
        4'b1000: begin : BranchPrediction
          ras_pop  = 1'b0;
          ras_push = 1'b0;
          // If conditional instr., check the order of instruction.
          GHRUpdate[ghr_index] = 1'b1;
          // if we have a valid dynamic prediction use it
          if(!CVA6Cfg.TageEn && !CVA6Cfg.GShareEn) begin
            if (bht_prediction_shifted[i].valid) begin
              taken_rvi_cf[i] = rvi_branch[i] & bht_prediction_shifted[i].taken;
              taken_rvc_cf[i] = rvc_branch[i] & bht_prediction_shifted[i].taken;
   //           $display("[%0t][TageUnn]index: %d |  taken: %b",$time, i, bht_prediction_shifted[i].taken);
              // otherwise default to static prediction
            end else begin
              // set if immediate is negative - static prediction
              taken_rvi_cf[i] = rvi_branch[i] & rvi_imm[i][CVA6Cfg.VLEN-1];
              taken_rvc_cf[i] = rvc_branch[i] & rvc_imm[i][CVA6Cfg.VLEN-1];
         //     $display("[%0t][TageUn] index: %d  static::%b-%b",$time,i,taken_rvc_cf[i], taken_rvi_cf[i]);
            end
            if (taken_rvi_cf[i] || taken_rvc_cf[i]) begin
              cf_type[i] = ariane_pkg::Branch;
            end  
          // Tage Prediction Case.
          end else if(CVA6Cfg.TageEn) begin
   //         $display("[%0t][TageEn] index: %dshifted_valid: %b-%b | taken :%b-%b", $time, i, 
//            tage_prediction_shifted[0].valid, tage_prediction_shifted[1].valid,
  //          tage_prediction_shifted[0].taken, tage_prediction_shifted[1].taken);

 //           $display("[%0t][TageEn] index: %d  | valid: %b-%b | taken :%b-%b", $time, i,
 //           tage_prediction[0].valid, tage_prediction[1].valid,
//            tage_prediction[0].taken, tage_prediction[1].taken);

            if(tage_prediction_shifted[i].valid) begin
              taken_rvi_cf[i] = rvi_branch[i] & tage_prediction_shifted[i].taken;
              taken_rvc_cf[i] = rvc_branch[i] & tage_prediction_shifted[i].taken;
   //           $display("[%0t][TageEn]index: %d taken: %b",$time, i, tage_prediction_shifted[i].taken);
            end else begin
              taken_rvi_cf[i] = rvi_branch[i] & rvi_imm[i][CVA6Cfg.VLEN-1];
              taken_rvc_cf[i] = rvc_branch[i] & rvc_imm[i][CVA6Cfg.VLEN-1];
     //         $display("[%0t][TageEn]index: %d static::%b-%b",$time, i, taken_rvc_cf[i], taken_rvi_cf[i]);
            end

            if (taken_rvi_cf[i] || taken_rvc_cf[i]) begin
              cf_type[i] = ariane_pkg::Branch;
      
              // if the instr. is taken, then GHRValue is set to 1.
              GHRValue[ghr_index] = 1'b1;
            end  else begin
              // Else then GHRValue is set to 0.
              GHRValue[ghr_index] = 1'b0;
            end
            // Update ghr_index for reflecting the order of instruction.
            ghr_index = ghr_index + 1;
          end else if(CVA6Cfg.GShareEn) begin : GSharePrediction
            if(gshare_prediction_shifted[i].valid) begin
              taken_rvi_cf[i] = rvi_branch[i] & gshare_prediction_shifted[i].taken;
              taken_rvc_cf[i] = rvc_branch[i] & gshare_prediction_shifted[i].taken;              
            end else begin
              taken_rvi_cf[i] = rvi_branch[i] & rvi_imm[i][CVA6Cfg.VLEN-1];
              taken_rvc_cf[i] = rvc_branch[i] & rvc_imm[i][CVA6Cfg.VLEN-1];
     //         $display("[%0t][TageEn]index: %d static::%b-%b",$time, i, taken_rvc_cf[i], taken_rvi_cf[i]);
            end
            if (taken_rvi_cf[i] || taken_rvc_cf[i]) begin
              cf_type[i] = ariane_pkg::Branch;
            end
          end else $error("Unexecuted preddictor");
        end : BranchPrediction
        default:  $error("Decoded more than one control flow"); 
        // default:
      endcase
      // if this instruction, in addition, is a call, save the resulting address
      // but only if we actually consumed the address
      if (is_call[i]) begin
        ras_push   = instr_queue_consumed[i];
        ras_update = addr[i] + (rvc_call[i] ? 2 : 4);
      end
      // calculate the jump target address
      if (taken_rvc_cf[i] || taken_rvi_cf[i]) begin
        predict_address = addr[i] + (taken_rvc_cf[i] ? rvc_imm[i] : rvi_imm[i]);
      end
    end
    
    if(CVA6Cfg.TageEn) begin
      // Initialization for Branch Id count & The validation of branch for Instructions..
      for(int p = 0; p < CVA6Cfg.INSTR_PER_FETCH; p++) begin
        BranchIdCnt_d[p]   = BranchIdCnt_q;
        BranchCntValid[p] = 0;
      end
      
      //   This case cond' is optimized for RISC-V 32bit Instr. only has 16-bit instr. and 32-bit instr. types.
      case ({GHRUpdate, GHRValue})         // (First Instr., Second Instr., ..) (Taken of First Instr, Taken of Second Instr, ...)
        4'b0100 : begin                    // Second Instr is cond. branch, first is not.
            BranchIdCnt_d[0] = BranchIdCnt_q;
            BranchIdCnt_d[1] = BranchIdCnt_q;
            if(GHRJump[1])                 // If first instr is jump, then this instr. is ignored.
              BranchCntValid   = 2'b00;
            else BranchCntValid   = 2'b10; // If not, then the second istr. is valid. 
        end 
        4'b0101 : begin // (low, high) (not taken, taken)
            BranchIdCnt_d[0] = BranchIdCnt_q;
            BranchIdCnt_d[1] = BranchIdCnt_q;
            //BranchCntValid  = 2'b01;
            if(GHRJump[1]) 
              BranchCntValid   = 2'b00;
            else BranchCntValid   = 2'b10;
        end
        4'b1010 : begin   // (low, high), (taken , not taken-> ignore)
            BranchIdCnt_d[0] = BranchIdCnt_q;
            BranchIdCnt_d[1] = BranchIdCnt_q;          
  //          BranchCntValid  = 2'b10;
            BranchCntValid  = 2'b01;
        end
        4'b1000 : begin // (low, high), (nottaken, no )
            BranchIdCnt_d[0] = BranchIdCnt_q;
            BranchIdCnt_d[1] = BranchIdCnt_q;          
    //        BranchCntValid  = 2'b10;
            BranchCntValid   = 2'b01;
        end
        4'b1100 : begin // (low, high), (nottaken, not tkane)
            BranchIdCnt_d[0] = BranchIdCnt_q;
            BranchIdCnt_d[1] = BranchIdCnt_q + 1;
            BranchCntValid  = 2'b11;            
        end
        4'b1110 : begin //// (low, high), (taken, not taken )
            BranchIdCnt_d[0] = BranchIdCnt_q;
            BranchIdCnt_d[1] = BranchIdCnt_q;
            BranchCntValid  = 2'b01;            
        end
        4'b1101 : begin //// (low, high), (not taken, taken )
            BranchIdCnt_d[0] = BranchIdCnt_q;
            BranchIdCnt_d[1] = BranchIdCnt_q + 1;
            BranchCntValid  = 2'b11;            
        end
        4'b1111 : begin //// (low, high), (taken, ignore )
            BranchIdCnt_d[0] = BranchIdCnt_q;
            BranchIdCnt_d[1] = BranchIdCnt_q;
            BranchCntValid  = 2'b01;            
        end
        default : begin
            BranchCntValid = 2'b00;
        end
      endcase
    end
  end : TakenOrNotTakenSetup

  // or reduce struct
  always_comb begin
    bp_valid = 1'b0;
    // BP cannot be valid if we have a return instruction and the RAS is not giving a valid address
    // Check that we encountered a control flow and that for a return the RAS
    // contains a valid prediction.
    for (int a = 0; a < CVA6Cfg.INSTR_PER_FETCH; a++)
    bp_valid |= ((cf_type[a] != NoCF & cf_type[a] != Return) | ((cf_type[a] == Return) & ras_predict.valid));
  end
  assign is_mispredict = resolved_branch_i.valid & resolved_branch_i.is_mispredict;

  // Cache interface
  // Gate ICache requests and NPC updates during fence.i
  assign icache_dreq_o.req = instr_queue_ready & ~halt_frontend_i;
  assign if_ready = icache_dreq_i.ready & instr_queue_ready & ~halt_frontend_i;

  // We need to flush the cache pipeline if:
  // 1. We mispredicted
  // 2. Want to flush the whole processor front-end
  // 3. Need to replay an instruction because the fetch-fifo was full
  assign icache_dreq_o.kill_s1 = is_mispredict | flush_i | replay;

  // if we have a valid branch-prediction we need to only kill the last cache request
  // also if we killed the first stage we also need to kill the second stage (inclusive flush)
  assign icache_dreq_o.kill_s2 = icache_dreq_o.kill_s1 | bp_valid;

  // Update Control Flow Predictions
  bht_update_t bht_update;
  btb_update_t btb_update;



  // assert on branch, deassert when resolved
  logic speculative_q, speculative_d;
  assign speculative_d = (speculative_q && !resolved_branch_i.valid || |is_branch || |is_return || |is_jalr) && !flush_i;
  assign icache_dreq_o.spec = speculative_d;

  assign bht_update.valid = resolved_branch_i.valid & (resolved_branch_i.cf_type == ariane_pkg::Branch);
  assign bht_update.pc    = resolved_branch_i.pc;
  assign bht_update.taken = resolved_branch_i.is_taken;


  // GSAHRE UPDATE SETUP
  assign gshare_update.valid = resolved_branch_i.valid & (resolved_branch_i.cf_type == ariane_pkg::Branch);
  assign gshare_update.pc    = resolved_branch_i.pc;
  assign gshare_update.taken = resolved_branch_i.is_taken;
  assign gshare_update.index = resolved_branch_i.gshare_index;

  // only update mispredicted branches e.g. no returns from the RAS
  assign btb_update.valid           = resolved_branch_i.valid & resolved_branch_i.is_mispredict & (resolved_branch_i.cf_type == ariane_pkg::JumpR);
  assign btb_update.pc              = resolved_branch_i.pc;
  assign btb_update.target_address  = resolved_branch_i.target_address;




  // -------------------
  // Next PC
  // -------------------
  // next PC (NPC) can come from (in order of precedence):
  // 0. Default assignment/replay instruction
  // 1. Branch Predict taken
  // 2. Control flow change request (misprediction)
  // 3. Return from environment call
  // 4. Exception/Interrupt
  // 5. Pipeline Flush because of CSR side effects
  // Mis-predict handling is a little bit different
  // select PC a.k.a PC Gen
  always_comb begin : npc_select
    automatic logic [CVA6Cfg.VLEN-1:0] fetch_address;
    // check whether we come out of reset
    // this is a workaround. some tools have issues
    // having boot_addr_i in the asynchronous
    // reset assignment to npc_q, even though
    // boot_addr_i will be assigned a constant
    // on the top-level.
    if (npc_rst_load_q) begin
      npc_d         = boot_addr_i;
      fetch_address = boot_addr_i;
    end else begin
      fetch_address = npc_q;
      // keep stable by default
      npc_d         = npc_q;
    end
    // 0. Branch Prediction
    if (bp_valid) begin
      fetch_address = predict_address;
      npc_d = predict_address;
    end
    // 1. Default assignment
    if (if_ready) begin
      npc_d = {
        fetch_address[CVA6Cfg.VLEN-1:CVA6Cfg.FETCH_ALIGN_BITS] + 1, {CVA6Cfg.FETCH_ALIGN_BITS{1'b0}}
      };
      
    end
    // 2. Replay instruction fetch
    if (replay) begin
      npc_d = replay_addr;
    //  $display("[%0t] replay",$time);
    end
    // 3. Control flow change request
    if (is_mispredict) begin
      npc_d = resolved_branch_i.target_address;
 //     $display("[%0t] miss",$time);
    end
    // 4. Return from environment call
    if (eret_i) begin
      npc_d = epc_i;
  //    $display("[%0t] return",$time);
    end
    // 5. Exception/Interrupt
    if (ex_valid_i) begin
      npc_d = trap_vector_base_i;
   //   $display("[%0t] execption",$time);
    end

    // 6. Pipeline Flush because of CSR side effects
    // On a pipeline flush start fetching from the next address
    // of the instruction in the commit stage
    // we either came here from a flush request of a CSR instruction or AMO,
    // so as CSR or AMO instructions do not exist in a compressed form
    // we can unconditionally do PC + 4 here
    // or if the commit stage is halted, just take the current pc of the
    // instruction in the commit stage
    // TODO(zarubaf) This adder can at least be merged with the one in the csr_regfile stage
    if (set_pc_commit_i) begin
      npc_d = pc_commit_i + (halt_i ? '0 : {{CVA6Cfg.VLEN - 3{1'b0}}, 3'b100});
    end
    // 7. Debug
    // enter debug on a hard-coded base-address
    if (CVA6Cfg.DebugEn && set_debug_pc_i)
      npc_d = CVA6Cfg.DmBaseAddress[CVA6Cfg.VLEN-1:0] + CVA6Cfg.HaltAddress[CVA6Cfg.VLEN-1:0];
    icache_dreq_o.vaddr = fetch_address;
  end : npc_select

  logic [CVA6Cfg.FETCH_WIDTH-1:0] icache_data;
  // re-align the cache line
  assign icache_data = icache_dreq_i.data >> {shamt, 4'b0};

  always_ff @(posedge clk_i or negedge rst_ni) begin : MainControlBlock
    if (!rst_ni) begin
      npc_rst_load_q    <= 1'b1;
      npc_q             <= '0;
      speculative_q     <= '0;
      icache_data_q     <= '0;
      icache_valid_q    <= 1'b0;
      icache_vaddr_q    <= 'b0;
      icache_gpaddr_q   <= 'b0;
      icache_tinst_q    <= 'b0;
      icache_gva_q      <= 1'b0;
      icache_ex_valid_q <= ariane_pkg::FE_NONE;
      btb_q             <= '0;
      bht_q             <= '0;

      // GSHARE PREDICTION
      gshare_q          <= '0;

      // TAGE PREDICTION
      vpc_tage_shifted_q <= '0;

      BaseTageTablePrediction_q <= '0;
      OneTageTablePrediction_q <= '0;
      TwoTageTablePrediction_q <= '0;
      ThreeTageTablePrediction_q <= '0;

      OneTageFoldedIndexInstr_q <= 0;
      OneTageFoldedTagInstr_q <= 0;
      TwoTageFoldedIndexInstr_q <= 0;
      TwoTageFoldedTagInstr_q <= 0;
      ThreeTageFoldedIndexInstr_q <= 0;
      ThreeTageFoldedTagInstr_q <= 0;

    end else begin
      npc_rst_load_q <= 1'b0;
      npc_q          <= npc_d;
      speculative_q  <= speculative_d;
      icache_valid_q <= icache_dreq_i.valid;
      if (icache_dreq_i.valid) begin
        icache_data_q  <= icache_data;
        icache_vaddr_q <= icache_dreq_i.vaddr;
        if (CVA6Cfg.RVH) begin
          icache_gpaddr_q <= icache_dreq_i.ex.tval2[CVA6Cfg.GPLEN-1:0];
          icache_tinst_q  <= icache_dreq_i.ex.tinst;
          icache_gva_q    <= icache_dreq_i.ex.gva;
        end else begin
          icache_gpaddr_q <= 'b0;
          icache_tinst_q  <= 'b0;
          icache_gva_q    <= 1'b0;
        end

        // Map the only three exceptions which can occur in the frontend to a two bit enum
        if (CVA6Cfg.MmuPresent && icache_dreq_i.ex.cause == riscv::INSTR_GUEST_PAGE_FAULT) begin
          icache_ex_valid_q <= ariane_pkg::FE_INSTR_GUEST_PAGE_FAULT;
        end else if (CVA6Cfg.MmuPresent && icache_dreq_i.ex.cause == riscv::INSTR_PAGE_FAULT) begin
          icache_ex_valid_q <= ariane_pkg::FE_INSTR_PAGE_FAULT;
        end else if (icache_dreq_i.ex.cause == riscv::INSTR_ACCESS_FAULT) begin
          icache_ex_valid_q <= ariane_pkg::FE_INSTR_ACCESS_FAULT;
        end else begin
          icache_ex_valid_q <= ariane_pkg::FE_NONE;
        end
        // save the uppermost prediction
        btb_q    <= btb_prediction[CVA6Cfg.INSTR_PER_FETCH-1];
        bht_q    <= bht_prediction[CVA6Cfg.INSTR_PER_FETCH-1];
        gshare_q <= gshare_prediction[CVA6Cfg.INSTR_PER_FETCH-1];

        BaseTageTablePrediction_q  <= BaseTageTablePrediction[CVA6Cfg.INSTR_PER_FETCH-1];
        OneTageTablePrediction_q   <= OneTageTablePrediction[CVA6Cfg.INSTR_PER_FETCH-1];
        TwoTageTablePrediction_q   <= TwoTageTablePrediction[CVA6Cfg.INSTR_PER_FETCH-1];
        ThreeTageTablePrediction_q <= ThreeTageTablePrediction[CVA6Cfg.INSTR_PER_FETCH-1];
        
        OneTagePredictIndex_q <= OneTagePredictIndex;
        OneTagePredictTag_q   <= OneTagePredictTag;
        TwoTagePredictIndex_q <= TwoTagePredictIndex;
        TwoTagePredictTag_q   <= TwoTagePredictTag;
        ThreeTagePredictIndex_q <= ThreeTagePredictIndex;
        ThreeTagePredictTag_q   <= ThreeTagePredictTag;

        OneTageFoldedIndexInstr_q <= OneTageFoldedIndexInstr[CVA6Cfg.INSTR_PER_FETCH-1];
        TwoTageFoldedIndexInstr_q <= TwoTageFoldedIndexInstr[CVA6Cfg.INSTR_PER_FETCH-1];
        ThreeTageFoldedIndexInstr_q <= ThreeTageFoldedIndexInstr[CVA6Cfg.INSTR_PER_FETCH-1];

        OneTageFoldedTagInstr_q <= OneTageFoldedTagInstr[CVA6Cfg.INSTR_PER_FETCH-1];
        TwoTageFoldedTagInstr_q <= TwoTageFoldedTagInstr[CVA6Cfg.INSTR_PER_FETCH-1];
        ThreeTageFoldedTagInstr_q <= ThreeTageFoldedTagInstr[CVA6Cfg.INSTR_PER_FETCH-1];;
      end
    end
  end : MainControlBlock

  if (CVA6Cfg.RASDepth == 0) begin
    assign ras_predict = '0;
  end else begin : ras_gen
    ras #(
        .CVA6Cfg(CVA6Cfg),
        .ras_t  (ras_t),
        .DEPTH  (CVA6Cfg.RASDepth)
    ) i_ras (
        .clk_i,
        .rst_ni,
        .flush_bp_i(flush_bp_i),
        .push_i(ras_push),
        .pop_i(ras_pop),
        .data_i(ras_update),
        .data_o(ras_predict)
    );
  end

  //For FPGA, BTB is implemented in read synchronous BRAM
  //while for ASIC, BTB is implemented in D flip-flop
  //and can be read at the same cycle.
  //Same for BHT
  assign vpc_btb    = (CVA6Cfg.FpgaEn) ? icache_dreq_i.vaddr : icache_vaddr_q;
  assign vpc_bht    = (CVA6Cfg.FpgaEn && CVA6Cfg.FpgaAlteraEn && icache_dreq_i.valid) ? icache_dreq_i.vaddr : icache_vaddr_q;
  assign vpc_tage   = (CVA6Cfg.FpgaEn && CVA6Cfg.FpgaAlteraEn && icache_dreq_i.valid) ? icache_dreq_i.vaddr : icache_vaddr_q;
  assign vpc_gshare = (CVA6Cfg.FpgaEn && CVA6Cfg.FpgaAlteraEn && icache_dreq_i.valid) ? icache_dreq_i.vaddr : icache_vaddr_q; 


  // GSHARE PREDICTION
  if(CVA6Cfg.GShareEn) begin
    // Update flag for GShare History Register.
    logic GShareRegUpdateSkip; 
    // GSHARE TABLE DEFINE
    GShareTable #(
      .CVA6Cfg              (CVA6Cfg),
      .gshare_update_t      (gshare_update_t),
      .gshare_prediction_t  (gshare_prediction_t),
      .NR_ENTRIES           (CVA6Cfg.GshareNrEntires),
      .NR_TABLE             (0)
    ) GShareTableInstance (
      .clk_i                (clk_i),
      .rst_ni               (rst_ni),
      .flush_bp_i           (flush_bp_i),
      .debug_mode_i,
      .vpc_i                (vpc_gshare),
      .gshare_i             (GShareHistoryRegister_q),
      .gshare_update_i      (gshare_update),
      .gshare_prediction_o  (gshare_prediction)
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin : GShareRegisterUpdate
      if(!rst_ni) begin
        GShareHistoryRegister_q <= '0;
      end else begin
        if(|is_branch) begin
          if( !ex_valid_i && !eret_i && !is_mispredict && !replay) begin  
            // GSHARE HISTROY REGISTER IS ONLY UPDATED WHEN THE BRANCH INSTRUCTION IS VALID TO GO INSTR. QUEUE.
            GShareHistoryRegister_q <= GShareHistoryRegister;
          end
        end else if(resolved_branch_i.is_mispredict && (resolved_branch_i.cf_type == ariane_pkg::Branch)) begin
           // IF RESOLVED BRANCH IS_MISPREDICT -> ROLLBACK GHR.
            GShareHistoryRegister_q <= GShareHistoryRegister;
        end
      end
    end : GShareRegisterUpdate

    
    always_comb begin : GShareRegisterSetup
      GShareHistoryRegister = GShareHistoryRegister_q;
      GShareRegUpdateSkip = 0;
      // Mispredict Update // 
      // Rollback GShare History Register based on "gshare_resolve"
      if(resolved_branch_i.is_mispredict && (resolved_branch_i.cf_type == ariane_pkg::Branch)) begin
        if(resolved_branch_i.is_taken)begin
          GShareHistoryRegister = {resolved_branch_i.gshare_resolve[CVA6Cfg.GSHAREWIDTH-2:0], 1'b1};
        end else begin
          GShareHistoryRegister = {resolved_branch_i.gshare_resolve[CVA6Cfg.GSHAREWIDTH-2:0], 1'b0};
        end
      end
      else begin 
       if(|is_branch && !ex_valid_i && !eret_i && !is_mispredict && !replay) begin
        // Speculative Update for GShareHistory Register
        for(int i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
          if(i==0) begin
            if((is_branch[i] == 1)) begin
                if(cf_type[i] == ariane_pkg::Branch)begin
                  GShareHistoryRegister = {GShareHistoryRegister[CVA6Cfg.GSHAREWIDTH-2:0], 1'b1};
                end else begin
                  GShareHistoryRegister = {GShareHistoryRegister[CVA6Cfg.GSHAREWIDTH-2:0], 1'b0};
                end
            end
          end else begin
              // If jump or branch-taken occurs prior instructions, then skip updating GShare register in this instr.
              for(int j = 0; j < i; j++) begin
                if((is_branch[j] == 1) && cf_type[i] == ariane_pkg::Branch) begin
                  GShareRegUpdateSkip = 1;
                end
                if(GShareJump[j]) begin
                  GShareRegUpdateSkip = 1;
                end
              end
              if(GShareRegUpdateSkip == 0) begin
                if((is_branch[i] == 1)) begin
                  if(cf_type[i] == ariane_pkg::Branch) begin
                    GShareHistoryRegister = {GShareHistoryRegister[CVA6Cfg.GSHAREWIDTH-2:0], 1'b1};
                  end else begin
                    GShareHistoryRegister = {GShareHistoryRegister[CVA6Cfg.GSHAREWIDTH-2:0], 1'b0};
                  end
                end
              end
          end
        end 
       end
      end
    end : GShareRegisterSetup
  end 




  // TAGE PREDICTION
  if(CVA6Cfg.TageEn) begin
  // TAGE Table Allocation Signal
  logic [CVA6Cfg.TageTableWidth-1:0] TageAllocable;
  // TAGE BASE TABLE, Entry has 1. 2-bit counter, 2. Valid bit (No useful / tag bits)
  TageBaseTable #(
    .CVA6Cfg        (CVA6Cfg),
    .tage_update_t  (tage_update_t),
    .NR_ENTRIES     (CVA6Cfg.BaseTageNrEntries),
    .NR_TABLE       (0)
  ) TageTable0(
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .flush_bp_i         (flush_bp_i),
    .debug_mode_i,
    .vpc_i              (vpc_tage),
    .tage_update_i      (tage_update[0]),
    .tage_allocation_i  (TageAllocation[0]),
    .tage_prediction_o  (BaseTageTablePrediction)
  );
  // TAGE FISRT TABLE, Entry has 1. 2-bit counter, 2. tag bits, 3. useful bits 4. Valid bit
  TageTable #(
    .CVA6Cfg        (CVA6Cfg),
    .tage_update_t  (tage_update_t),
    .INDEXWIDTH     (CVA6Cfg.OneTageIndexWidth),
    .TAGWIDTH       (CVA6Cfg.OneTageTagWidth),
    .NR_ENTRIES     (CVA6Cfg.OneTageNrEntries),
    .NR_TABLE       (1)
  )TageTable1(
    .clk_i                (clk_i),
    .rst_ni               (rst_ni),
    .flush_bp_i           (flush_bp_i),
    .debug_mode_i,
    .vpc_i                (vpc_tage),
    .tage_update_i        (tage_update[1]),
    .tage_allocation_i    (TageAllocation[1]),
    .tage_resolve_index_i (OneTageResolveIndex),
    .tage_resolve_tag_i   (OneTageResolveTag),
    .tage_folded_index_i  (OneTageFoldedIndex),
    .tage_folded_tag_i    (OneTageFoldedTag),
    .allocable_o          (TageAllocable[1]),
    .tage_predict_index_o (OneTagePredictIndex),
    .tage_predict_tag_o   (OneTagePredictTag),
    .tage_prediction_o    (OneTageTablePrediction)
  );

  // TAGE SECOND TABLE, Entry has 1. 2-bit counter, 2. tag bits, 3. useful bits 4. Valid bit
  TageTable #(
    .CVA6Cfg        (CVA6Cfg),
    .tage_update_t  (tage_update_t),
    .INDEXWIDTH     (CVA6Cfg.TwoTageIndexWidth),
    .TAGWIDTH       (CVA6Cfg.TwoTageTagWidth),
    .NR_ENTRIES     (CVA6Cfg.TwoTageNrEntries),
    .NR_TABLE       (2)
  )TageTable2(
    .clk_i                (clk_i),
    .rst_ni               (rst_ni),
    .flush_bp_i           (flush_bp_i),
    .debug_mode_i,
    .vpc_i                (vpc_tage),
    .tage_update_i        (tage_update[2]),
    .tage_allocation_i    (TageAllocation[2]),
    .tage_resolve_index_i (TwoTageResolveIndex),
    .tage_resolve_tag_i   (TwoTageResolveTag),
    .tage_folded_index_i  (TwoTageFoldedIndex),
    .tage_folded_tag_i    (TwoTageFoldedTag),
    .allocable_o          (TageAllocable[2]),    
    .tage_predict_index_o (TwoTagePredictIndex),
    .tage_predict_tag_o   (TwoTagePredictTag),
    .tage_prediction_o    (TwoTageTablePrediction)
  );

  // TAGE SECOND TABLE, Entry has 1. 2-bit counter, 2. tag bits, 3. useful bits 4. Valid bit
  TageTable #(
    .CVA6Cfg        (CVA6Cfg),
    .tage_update_t  (tage_update_t),
    .INDEXWIDTH     (CVA6Cfg.ThreeTageIndexWidth),
    .TAGWIDTH       (CVA6Cfg.ThreeTageTagWidth),
    .NR_ENTRIES     (CVA6Cfg.ThreeTageNrEntries),
    .NR_TABLE       (3)
  )TageTable3(
    .clk_i                (clk_i),
    .rst_ni               (rst_ni),
    .flush_bp_i           (flush_bp_i),
    .debug_mode_i,
    .vpc_i                (vpc_tage),
    .tage_update_i        (tage_update[3]),
    .tage_allocation_i    (TageAllocation[3]),
    .tage_resolve_index_i (ThreeTageResolveIndex),
    .tage_resolve_tag_i   (ThreeTageResolveTag),
    .tage_folded_index_i  (ThreeTageFoldedIndex),
    .tage_folded_tag_i    (ThreeTageFoldedTag),
    .allocable_o          (TageAllocable[3]),  
    .tage_predict_index_o (ThreeTagePredictIndex),
    .tage_predict_tag_o   (ThreeTagePredictTag),
    .tage_prediction_o    (ThreeTageTablePrediction)
  );


    int target [CVA6Cfg.INSTR_PER_FETCH-1:0] = '{default:0}; // debugging, finding which table prediction is selected.

    always_comb begin : TAGECheckpointUpdating
      for (int i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
          TageTableValid[i]      = '0;
          TageTableTaken[i]      = '0;
          TageTableChampion[i]   = '0;
          tage_prediction[i]     = '0;

          if(i==0) begin
            // If unaligned and that unaligned instr is branch instr., then we need to utilize prior table prediction for that instruction.
            TageTableValid[i]      = (serving_unaligned && is_branch[0]) ? {ThreeTageTablePrediction_q.valid, TwoTageTablePrediction_q.valid, OneTageTablePrediction_q.valid, BaseTageTablePrediction_q.valid} 
                      : {ThreeTageTablePrediction[i].valid, TwoTageTablePrediction[i].valid, OneTageTablePrediction[i].valid, BaseTageTablePrediction[i].valid};

            TageTableTaken[i]      = (serving_unaligned && is_branch[0]) ? {ThreeTageTablePrediction_q.taken, TwoTageTablePrediction_q.taken, OneTageTablePrediction_q.taken, BaseTageTablePrediction_q.taken}
                      : {ThreeTageTablePrediction[i].taken, TwoTageTablePrediction[i].taken, OneTageTablePrediction[i].taken, BaseTageTablePrediction[i].taken};

            TageTableChampion[i]   = (serving_unaligned && is_branch[0]) ? {ThreeTageTablePrediction_q.confidence, TwoTageTablePrediction_q.confidence, OneTageTablePrediction_q.confidence, BaseTageTablePrediction_q.confidence}
                      : {ThreeTageTablePrediction[i].confidence, TwoTageTablePrediction[i].confidence, OneTageTablePrediction[i].confidence, BaseTageTablePrediction[i].confidence};
          end else begin
            TageTableValid[i]    =  {ThreeTageTablePrediction[i].valid, TwoTageTablePrediction[i].valid, OneTageTablePrediction[i].valid, BaseTageTablePrediction[i].valid};
            TageTableTaken[i]    =  {ThreeTageTablePrediction[i].taken, TwoTageTablePrediction[i].taken, OneTageTablePrediction[i].taken, BaseTageTablePrediction[i].taken};
            TageTableChampion[i] =  {ThreeTageTablePrediction[i].confidence, TwoTageTablePrediction[i].confidence, OneTageTablePrediction[i].confidence, BaseTageTablePrediction[i].confidence};
          end


          // Selection of predictions across multiple TAGE tables
          // Alternative prediction selection If there is strong confidence in specific TAGE table.
          // Priority 1: Select entry marked as Champion
          if((|(TageTableChampion[i] & TageTableValid[i]))) begin
            for(int j = 0; j < CVA6Cfg.TageTableWidth; j++) begin
              if(TageTableValid[i][j]) begin
                tage_prediction[i].valid = TageTableValid[i][j];
                tage_prediction[i].taken = TageTableTaken[i][j];
                target[i] = j;
              end
            end
          // Priority 2: Fallback to the highest valid entry index
          end else begin 
            for(int j = 0; j < CVA6Cfg.TageTableWidth; j++) begin
              if(TageTableValid[i][j]) begin
                tage_prediction[i].valid = TageTableValid[i][j];
                tage_prediction[i].taken = TageTableTaken[i][j];
                target[i] = j;
              end
            end
          end
      end
    end : TAGECheckpointUpdating

    always_comb begin : ResolveLogic
      // Rollback process based on TageCheckpoint Queue for updating TAGE Tables
      // 1) Allocataion 주기 + ResolveTag, ResolveIndex 찾기
      TageResolveValid      = '0;
      TageAllocation        = '0;
      TageTableMiss         = '0;

      OneTageResolveIndex   = '0;
      TwoTageResolveIndex   = '0;
      ThreeTageResolveIndex = '0;

      OneTageResolveTag     = '0;
      TwoTageResolveTag     = '0;
      ThreeTageResolveTag   = '0;

      // Finding target Index and Tag for updating "TAGE Table" based on TAGE checkpoint queue.
      OneTageResolveIndex   = TageCheckPointQueue_q[resolved_branch_i.bid].OneTage.TageIndex;
      TwoTageResolveIndex   = TageCheckPointQueue_q[resolved_branch_i.bid].TwoTage.TageIndex;
      ThreeTageResolveIndex = TageCheckPointQueue_q[resolved_branch_i.bid].ThreeTage.TageIndex;

      OneTageResolveTag     = TageCheckPointQueue_q[resolved_branch_i.bid].OneTage.TageTag;
      TwoTageResolveTag     = TageCheckPointQueue_q[resolved_branch_i.bid].TwoTage.TageTag;
      ThreeTageResolveTag   = TageCheckPointQueue_q[resolved_branch_i.bid].ThreeTage.TageTag;

      // Finding folded Index and Tag for updating "TAGE Folded Index/Tag" based on TAGE checkpoint queue.
      OneTageResFoldedIndex = TageCheckPointQueue_q[resolved_branch_i.bid].OneTage.foldedIndex;
      OneTageResFoldedTag   = TageCheckPointQueue_q[resolved_branch_i.bid].OneTage.foldedTag;

      TwoTageResFoldedIndex = TageCheckPointQueue_q[resolved_branch_i.bid].TwoTage.foldedIndex;
      TwoTageResFoldedTag   = TageCheckPointQueue_q[resolved_branch_i.bid].TwoTage.foldedTag;

      ThreeTageResFoldedIndex = TageCheckPointQueue_q[resolved_branch_i.bid].ThreeTage.foldedIndex;
      ThreeTageResFoldedTag   = TageCheckPointQueue_q[resolved_branch_i.bid].ThreeTage.foldedTag;


      
      // TAGE Update & Allocation Logic
      // 1. Identify table misses: Check if the prediction from a valid table was correct.
      // 2. Determine allocation: If a misprediction occurs, select a table to allocate a new entry.
      // 3. Fallback allocation: Allocate to the base table if no other tables are available.
      if(resolved_branch_i.valid && (resolved_branch_i.cf_type == ariane_pkg::Branch)) begin
        TageResolveValid = TageCheckPointQueue_q[resolved_branch_i.bid].valid;  
        for(int i = CVA6Cfg.TageTableWidth-1; i >= 0; i--) begin
          // Trigger a 'Miss' signal if the provider table's prediction was incorrect
          if(TageResolveValid[i]) begin
            if(TageCheckPointQueue_q[resolved_branch_i.bid].pred[i] != resolved_branch_i.is_taken) begin
              TageTableMiss[i] = 1;
            end
          end
          // Allocation Policy: On a misprediction, find an available table for a new entry  
          if(resolved_branch_i.is_mispredict && !TageResolveValid[i]) begin
            if(TageAllocable[i]) begin
              TageAllocation[i] = 1;
            end
          end 
        end
        // Base Table Allocation: Ensure at least the base table is updated if no entries match
        if(!TageResolveValid[0] && TageAllocation == '0) begin
            TageAllocation[0] = 1;
        end
      end 
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : TAGETableManagement
      if(!rst_ni) begin
        BranchIdCnt_q <= '0;
        for(int unsigned i = 0; i < CVA6Cfg.BranchTidWidth; i++) begin
          TageCheckPointQueue_q[i] <= '0;
        end
      end else begin
        if(flush_bp_i) begin
          BranchIdCnt_q <= '0;
          for(int unsigned i = 0; i < CVA6Cfg.BranchTidWidth; i++) begin
            TageCheckPointQueue_q[i] <= '0;
          end
        end else begin
          if(|BranchCntValid && !(resolved_branch_i.is_mispredict)) begin 
            // If Instr.s in fetch bundle are valid for branch and go into Instr. Queue, then update TageCheckPointQueue.
              BranchIdCnt_q <= BranchIdCnt_d[CVA6Cfg.INSTR_PER_FETCH-1] + 1; // Update Branch ID Count Register.
              vpc_tage_shifted_q[0] <= vpc_tage_shifted[0];                  // Deprecated
              vpc_tage_shifted_q[1] <= vpc_tage_shifted[1];                  // Deprecated
              for(int i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
                if(serving_unaligned && is_branch[0]) begin
                  if(BranchCntValid[i]) begin
                    // Case for Unaligned and prior instr is branch case.
                    if(i == 0) begin
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].OneTage.TageIndex     <= OneTagePredictIndex_q;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].OneTage.TageTag       <= OneTagePredictTag_q;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].OneTage.foldedIndex   <= OneTageFoldedIndexInstr_q;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].OneTage.foldedTag     <= OneTageFoldedTagInstr_q;

                      TageCheckPointQueue_q[BranchIdCnt_d[i]].TwoTage.TageIndex     <= TwoTagePredictIndex_q;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].TwoTage.TageTag       <= TwoTagePredictTag_q;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].TwoTage.foldedIndex   <= TwoTageFoldedIndexInstr_q;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].TwoTage.foldedTag     <= TwoTageFoldedTagInstr_q;

                      TageCheckPointQueue_q[BranchIdCnt_d[i]].ThreeTage.TageIndex   <= ThreeTagePredictIndex_q; 
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].ThreeTage.TageTag     <= ThreeTagePredictTag_q;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].ThreeTage.foldedIndex <= ThreeTageFoldedIndexInstr_q;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].ThreeTage.foldedTag   <= ThreeTageFoldedTagInstr_q;

                      TageCheckPointQueue_q[BranchIdCnt_d[i]].pred                  <= TageTableTaken[i];
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].valid                 <= TageTableValid[i];
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].bid                   <= BranchIdCnt_d[i];
                    end else begin
                      // if i > 0, then it uses current checkpoint-related values based on current PC.
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].OneTage.TageIndex     <= OneTagePredictIndex;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].OneTage.TageTag       <= OneTagePredictTag;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].OneTage.foldedIndex   <= OneTageFoldedIndex;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].OneTage.foldedTag     <= OneTageFoldedTag;

                      TageCheckPointQueue_q[BranchIdCnt_d[i]].TwoTage.TageIndex     <= TwoTagePredictIndex;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].TwoTage.TageTag       <= TwoTagePredictTag;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].TwoTage.foldedIndex   <= TwoTageFoldedIndex;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].TwoTage.foldedTag     <= TwoTageFoldedTag;

                      TageCheckPointQueue_q[BranchIdCnt_d[i]].ThreeTage.TageIndex   <= ThreeTagePredictIndex; 
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].ThreeTage.TageTag     <= ThreeTagePredictTag;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].ThreeTage.foldedIndex <= ThreeTageFoldedIndex;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].ThreeTage.foldedTag   <= ThreeTageFoldedTag;

                      TageCheckPointQueue_q[BranchIdCnt_d[i]].pred                  <= {ThreeTageTablePrediction[addr[i][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]].taken, 
                                                                                          TwoTageTablePrediction[addr[i][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]].taken, 
                                                                                          OneTageTablePrediction[addr[i][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]].taken, 
                                                                                          BaseTageTablePrediction[addr[i][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]].taken};
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].valid                 <= {ThreeTageTablePrediction[addr[i][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]].valid, 
                                                                                          TwoTageTablePrediction[addr[i][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]].valid, 
                                                                                          OneTageTablePrediction[addr[i][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]].valid, 
                                                                                          BaseTageTablePrediction[addr[i][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]].valid};
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].bid                   <= BranchIdCnt_d[i];                    
                    end
                  end
                end else begin
                  if(serving_unaligned && !is_branch[0]) begin
                    if(BranchCntValid[i]) begin
                      // if unaligned but prior instr is not branch, then we can utilize current prediction-related values.
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].OneTage.TageIndex     <= OneTagePredictIndex;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].OneTage.TageTag       <= OneTagePredictTag;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].OneTage.foldedIndex   <= OneTageFoldedIndex;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].OneTage.foldedTag     <= OneTageFoldedTag;

                      TageCheckPointQueue_q[BranchIdCnt_d[i]].TwoTage.TageIndex     <= TwoTagePredictIndex;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].TwoTage.TageTag       <= TwoTagePredictTag;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].TwoTage.foldedIndex   <= TwoTageFoldedIndex;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].TwoTage.foldedTag     <= TwoTageFoldedTag;

                      TageCheckPointQueue_q[BranchIdCnt_d[i]].ThreeTage.TageIndex   <= ThreeTagePredictIndex; 
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].ThreeTage.TageTag     <= ThreeTagePredictTag;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].ThreeTage.foldedIndex <= ThreeTageFoldedIndex;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].ThreeTage.foldedTag   <= ThreeTageFoldedTag;

                      TageCheckPointQueue_q[BranchIdCnt_d[i]].pred                  <= TageTableTaken[addr[i][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]];
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].valid                 <= TageTableValid[addr[i][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]];
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].bid                   <= BranchIdCnt_d[i];
                    end                    
                  end else begin
                    if(BranchCntValid[i]) begin
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].OneTage.TageIndex     <= OneTagePredictIndex;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].OneTage.TageTag       <= OneTagePredictTag;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].OneTage.foldedIndex   <= OneTageFoldedIndex;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].OneTage.foldedTag     <= OneTageFoldedTag;

                      TageCheckPointQueue_q[BranchIdCnt_d[i]].TwoTage.TageIndex     <= TwoTagePredictIndex;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].TwoTage.TageTag       <= TwoTagePredictTag;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].TwoTage.foldedIndex   <= TwoTageFoldedIndex;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].TwoTage.foldedTag     <= TwoTageFoldedTag;

                      TageCheckPointQueue_q[BranchIdCnt_d[i]].ThreeTage.TageIndex   <= ThreeTagePredictIndex; 
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].ThreeTage.TageTag     <= ThreeTagePredictTag;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].ThreeTage.foldedIndex <= ThreeTageFoldedIndex;
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].ThreeTage.foldedTag   <= ThreeTageFoldedTag;

                      TageCheckPointQueue_q[BranchIdCnt_d[i]].pred                  <= TageTableTaken[addr[i][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]];
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].valid                 <= TageTableValid[addr[i][$clog2(CVA6Cfg.INSTR_PER_FETCH):1]];
                      TageCheckPointQueue_q[BranchIdCnt_d[i]].bid                   <= BranchIdCnt_d[i];
                    end
                  end
                end
              end
          end
        end
      end
    end : TAGETableManagement




    
    // Manages speculative updates and recovery for Global History Registers (GHR) 
    // and folded Tag/Index logic during branch resolution.
    always_ff @(posedge clk_i or negedge rst_ni) begin : GHRIndexTagUpdate
      if(!rst_ni) begin
        GlobalHistoryRegister <= '0;
        
        OneTageFoldedIndex    <= '0;
        TwoTageFoldedIndex    <= '0;
        ThreeTageFoldedIndex  <= '0;

        OneTageFoldedTag      <= '0;
        TwoTageFoldedTag      <= '0;
        ThreeTageFoldedTag    <= '0;
      end else begin
        if(is_mispredict && (resolved_branch_i.cf_type == ariane_pkg::Branch)) begin : RollBack
            // Resolve branch prediction phase
            GlobalHistoryRegister   <= {resolved_branch_i.ghr_resolve[CVA6Cfg.GHRWIDTH-2:0], resolved_branch_i.ghr_value};

            OneTageFoldedIndex      <= {OneTageResFoldedIndex[CVA6Cfg.OneTageIndexWidth-2:0], 
              resolved_branch_i.ghr_resolve[CVA6Cfg.OneTageIndexWidth-1] ^ OneTageResFoldedIndex[CVA6Cfg.OneTageIndexWidth-1] ^ resolved_branch_i.ghr_value};

            TwoTageFoldedIndex      <= {TwoTageResFoldedIndex[CVA6Cfg.TwoTageIndexWidth-2:0], 
              resolved_branch_i.ghr_resolve[CVA6Cfg.TwoTageIndexWidth-1] ^ TwoTageResFoldedIndex[CVA6Cfg.TwoTageIndexWidth-1] ^ resolved_branch_i.ghr_value};

            ThreeTageFoldedIndex    <= {ThreeTageResFoldedIndex[CVA6Cfg.ThreeTageIndexWidth-2:0], 
              resolved_branch_i.ghr_resolve[CVA6Cfg.ThreeTageIndexWidth-1] ^ ThreeTageResFoldedIndex[CVA6Cfg.ThreeTageIndexWidth-1] ^ resolved_branch_i.ghr_value};


            OneTageFoldedTag        <= {OneTageResFoldedTag[CVA6Cfg.OneTageTagWidth-3:0], 
                                           resolved_branch_i.ghr_resolve[CVA6Cfg.OneTageTagWidth-1] ^ OneTageResFoldedTag[CVA6Cfg.OneTageTagWidth-1] ^ resolved_branch_i.ghr_value, 
                                           OneTageResFoldedTag[CVA6Cfg.OneTageTagWidth-2]};

            TwoTageFoldedTag        <= {TwoTageResFoldedTag[CVA6Cfg.TwoTageTagWidth-4:0], 
                                            resolved_branch_i.ghr_resolve[CVA6Cfg.TwoTageTagWidth-1] ^ TwoTageResFoldedTag[CVA6Cfg.TwoTageTagWidth-1] ^ resolved_branch_i.ghr_value, 
                                            TwoTageResFoldedTag[CVA6Cfg.TwoTageTagWidth-2:CVA6Cfg.TwoTageTagWidth-3]};

            ThreeTageFoldedTag      <= {ThreeTageResFoldedTag[CVA6Cfg.ThreeTageTagWidth-5:0], 
                                            resolved_branch_i.ghr_resolve[CVA6Cfg.ThreeTageTagWidth-1] ^ ThreeTageResFoldedTag[CVA6Cfg.ThreeTageTagWidth-1] ^ resolved_branch_i.ghr_value , 
                                            ThreeTageResFoldedTag[CVA6Cfg.ThreeTageTagWidth-2:CVA6Cfg.ThreeTageTagWidth-4]};
        end else begin
          if(|BranchCntValid)begin
            // Speculative Update
            GlobalHistoryRegister <= GHRegInstr[CVA6Cfg.INSTR_PER_FETCH-1];

            OneTageFoldedIndex    <= OneTageFoldedIndexInstr[CVA6Cfg.INSTR_PER_FETCH-1];
            TwoTageFoldedIndex    <= TwoTageFoldedIndexInstr[CVA6Cfg.INSTR_PER_FETCH-1];
            ThreeTageFoldedIndex  <= ThreeTageFoldedIndexInstr[CVA6Cfg.INSTR_PER_FETCH-1];
            
            OneTageFoldedTag      <= OneTageFoldedTagInstr[CVA6Cfg.INSTR_PER_FETCH-1];
            TwoTageFoldedTag      <= TwoTageFoldedTagInstr[CVA6Cfg.INSTR_PER_FETCH-1];
            ThreeTageFoldedTag    <= ThreeTageFoldedTagInstr[CVA6Cfg.INSTR_PER_FETCH-1];
          end
        end
      end
    end : GHRIndexTagUpdate

    always_comb begin
      for(int i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
          if(i==0) begin
            GHRegInstr[i] = GlobalHistoryRegister;

            OneTageFoldedIndexInstr[i] = OneTageFoldedIndex;
            TwoTageFoldedIndexInstr[i] = TwoTageFoldedIndex;
            ThreeTageFoldedIndexInstr[i] = ThreeTageFoldedIndex;

            OneTageFoldedTagInstr[i] = OneTageFoldedTag;
            TwoTageFoldedTagInstr[i] = TwoTageFoldedTag;
            ThreeTageFoldedTagInstr[i] = ThreeTageFoldedTag;

            if(BranchCntValid[i]) begin
              if(cf_type[i] == ariane_pkg::Branch) begin  // taken
                GHRegInstr[i] =  {GHRegInstr[i][CVA6Cfg.GHRWIDTH-2:0], 1'b1};
                // Circular shift register-based update for folded index
                OneTageFoldedIndexInstr[i] = {OneTageFoldedIndexInstr[i][CVA6Cfg.OneTageIndexWidth-2:0], 
                          OneTageFoldedIndexInstr[i][CVA6Cfg.OneTageIndexWidth-1] ^ 1'b1 ^ GHRegInstr[i][CVA6Cfg.OneTageIndexWidth]};

                TwoTageFoldedIndexInstr[i] = {TwoTageFoldedIndexInstr[i][CVA6Cfg.TwoTageIndexWidth-2:0],
                          TwoTageFoldedIndexInstr[i][CVA6Cfg.TwoTageIndexWidth-1] ^ 1'b1 ^ GHRegInstr[i][CVA6Cfg.TwoTageIndexWidth]};

                ThreeTageFoldedIndexInstr[i] = {ThreeTageFoldedIndexInstr[i][CVA6Cfg.ThreeTageIndexWidth-2:0],
                          ThreeTageFoldedIndexInstr[i][CVA6Cfg.ThreeTageIndexWidth-1] ^ 1'b1 ^ GHRegInstr[i][CVA6Cfg.ThreeTageIndexWidth]};
                // Circular shift register-based update for folded tag
                OneTageFoldedTagInstr[i] = {OneTageFoldedTagInstr[i][CVA6Cfg.OneTageTagWidth-3:0], 
                      OneTageFoldedTagInstr[i][CVA6Cfg.OneTageTagWidth-1] ^ 1'b1 ^ GHRegInstr[i][CVA6Cfg.OneTageTagWidth+CVA6Cfg.OneTageIndexWidth],
                      OneTageFoldedTagInstr[i][CVA6Cfg.OneTageTagWidth-2]};

                TwoTageFoldedTagInstr[i] = {TwoTageFoldedTagInstr[i][CVA6Cfg.TwoTageTagWidth-4:0], 
                      TwoTageFoldedTagInstr[i][CVA6Cfg.TwoTageTagWidth-1] ^ 1'b1 ^ GHRegInstr[i][CVA6Cfg.TwoTageTagWidth+CVA6Cfg.TwoTageIndexWidth],
                      TwoTageFoldedTagInstr[i][CVA6Cfg.TwoTageTagWidth-2: CVA6Cfg.TwoTageTagWidth-3]};

                ThreeTageFoldedTagInstr[i] = {ThreeTageFoldedTagInstr[i][CVA6Cfg.ThreeTageTagWidth-5:0], 
                      ThreeTageFoldedTagInstr[i][CVA6Cfg.ThreeTageTagWidth-1] ^ 1'b1 ^ GHRegInstr[i][CVA6Cfg.ThreeTageTagWidth+CVA6Cfg.ThreeTageIndexWidth],
                      ThreeTageFoldedTagInstr[i][CVA6Cfg.ThreeTageTagWidth-2: CVA6Cfg.ThreeTageTagWidth-4]};
              end else begin      // Not taken
                GHRegInstr[i] =  {GHRegInstr[i][CVA6Cfg.GHRWIDTH-2:0], 1'b0};
                // Circular shift register-based update for folded index
                OneTageFoldedIndexInstr[i] = {OneTageFoldedIndexInstr[i][CVA6Cfg.OneTageIndexWidth-2:0], 
                          OneTageFoldedIndexInstr[i][CVA6Cfg.OneTageIndexWidth-1] ^ 1'b0 ^ GHRegInstr[i][CVA6Cfg.OneTageIndexWidth]};

                TwoTageFoldedIndexInstr[i] = {TwoTageFoldedIndexInstr[i][CVA6Cfg.TwoTageIndexWidth-2:0],
                          TwoTageFoldedIndexInstr[i][CVA6Cfg.TwoTageIndexWidth-1] ^ 1'b0 ^ GHRegInstr[i][CVA6Cfg.TwoTageIndexWidth]};

                ThreeTageFoldedIndexInstr[i] = {ThreeTageFoldedIndexInstr[i][CVA6Cfg.ThreeTageIndexWidth-2:0],
                          ThreeTageFoldedIndexInstr[i][CVA6Cfg.ThreeTageIndexWidth-1] ^ 1'b0 ^ GHRegInstr[i][CVA6Cfg.ThreeTageIndexWidth]};
                // Circular shift register-based update for folded tag
                OneTageFoldedTagInstr[i] = {OneTageFoldedTagInstr[i][CVA6Cfg.OneTageTagWidth-3:0], 
                      OneTageFoldedTagInstr[i][CVA6Cfg.OneTageTagWidth-1] ^ 1'b0 ^ GHRegInstr[i][CVA6Cfg.OneTageTagWidth+CVA6Cfg.OneTageIndexWidth],
                      OneTageFoldedTagInstr[i][CVA6Cfg.OneTageTagWidth-2]};

                TwoTageFoldedTagInstr[i] = {TwoTageFoldedTagInstr[i][CVA6Cfg.TwoTageTagWidth-4:0], 
                      TwoTageFoldedTagInstr[i][CVA6Cfg.TwoTageTagWidth-1] ^ 1'b0 ^ GHRegInstr[i][CVA6Cfg.TwoTageTagWidth + CVA6Cfg.TwoTageIndexWidth],
                      TwoTageFoldedTagInstr[i][CVA6Cfg.TwoTageTagWidth-2: CVA6Cfg.TwoTageTagWidth-3]};

                ThreeTageFoldedTagInstr[i] = {ThreeTageFoldedTagInstr[i][CVA6Cfg.ThreeTageTagWidth-5:0], 
                      ThreeTageFoldedTagInstr[i][CVA6Cfg.ThreeTageTagWidth-1] ^ 1'b0 ^ GHRegInstr[i][CVA6Cfg.ThreeTageTagWidth+CVA6Cfg.ThreeTageIndexWidth],
                      ThreeTageFoldedTagInstr[i][CVA6Cfg.ThreeTageTagWidth-2: CVA6Cfg.ThreeTageTagWidth-4]};
              end
            end 
          end else begin
            // Speculative Update
            GHRegInstr[i] = GHRegInstr[i-1];
            OneTageFoldedIndexInstr[i] = OneTageFoldedIndexInstr[i-1];
            TwoTageFoldedIndexInstr[i] = TwoTageFoldedIndexInstr[i-1];
            ThreeTageFoldedIndexInstr[i] = ThreeTageFoldedIndexInstr[i-1];

            OneTageFoldedTagInstr[i] = OneTageFoldedTagInstr[i-1];
            TwoTageFoldedTagInstr[i] = TwoTageFoldedTagInstr[i-1];
            ThreeTageFoldedTagInstr[i] = ThreeTageFoldedTagInstr[i-1];

            if(BranchCntValid[i]) begin
              if(cf_type[i] == ariane_pkg::Branch) begin // taken
                GHRegInstr[i] =  {GHRegInstr[i][CVA6Cfg.GHRWIDTH-2:0], 1'b1};
                // Circular shift register-based update for folded index
                OneTageFoldedIndexInstr[i] = {OneTageFoldedIndexInstr[i][CVA6Cfg.OneTageIndexWidth-2:0], 
                          OneTageFoldedIndexInstr[i][CVA6Cfg.OneTageIndexWidth-1] ^ 1'b1 ^ GHRegInstr[i][CVA6Cfg.OneTageIndexWidth]};
                TwoTageFoldedIndexInstr[i] = {TwoTageFoldedIndexInstr[i][CVA6Cfg.TwoTageIndexWidth-2:0],
                          TwoTageFoldedIndexInstr[i][CVA6Cfg.TwoTageIndexWidth-1] ^ 1'b1 ^ GHRegInstr[i][CVA6Cfg.TwoTageIndexWidth]};
                ThreeTageFoldedIndexInstr[i] = {ThreeTageFoldedIndexInstr[i][CVA6Cfg.ThreeTageIndexWidth-2:0],
                          ThreeTageFoldedIndexInstr[i][CVA6Cfg.ThreeTageIndexWidth-1] ^ 1'b1 ^ GHRegInstr[i][CVA6Cfg.ThreeTageIndexWidth]};
                // Circular shift register-based update for folded tag
                OneTageFoldedTagInstr[i] = {OneTageFoldedTagInstr[i][CVA6Cfg.OneTageTagWidth-3:0], 
                      OneTageFoldedTagInstr[i][CVA6Cfg.OneTageTagWidth-1] ^ 1'b1 ^ GHRegInstr[i][CVA6Cfg.OneTageTagWidth+CVA6Cfg.OneTageIndexWidth],
                      OneTageFoldedTagInstr[i][CVA6Cfg.OneTageTagWidth-2]};
                TwoTageFoldedTagInstr[i] = {TwoTageFoldedTagInstr[i][CVA6Cfg.TwoTageTagWidth-4:0], 
                      TwoTageFoldedTagInstr[i][CVA6Cfg.TwoTageTagWidth-1] ^ 1'b1 ^ GHRegInstr[i][CVA6Cfg.TwoTageTagWidth + CVA6Cfg.TwoTageIndexWidth],
                      TwoTageFoldedTagInstr[i][CVA6Cfg.TwoTageTagWidth-2: CVA6Cfg.TwoTageTagWidth-3]};
                ThreeTageFoldedTagInstr[i] = {ThreeTageFoldedTagInstr[i][CVA6Cfg.ThreeTageTagWidth-5:0], 
                      ThreeTageFoldedTagInstr[i][CVA6Cfg.ThreeTageTagWidth-1] ^ 1'b1 ^ GHRegInstr[i][CVA6Cfg.ThreeTageTagWidth+CVA6Cfg.ThreeTageIndexWidth],
                      ThreeTageFoldedTagInstr[i][CVA6Cfg.ThreeTageTagWidth-2: CVA6Cfg.ThreeTageTagWidth-4]};
              end else begin  // Not taken
                GHRegInstr[i] =  {GHRegInstr[i][CVA6Cfg.GHRWIDTH-2:0], 1'b0};
                // Circular shift register-based update for folded index
                OneTageFoldedIndexInstr[i] = {OneTageFoldedIndexInstr[i][CVA6Cfg.OneTageIndexWidth-2:0], 
                          OneTageFoldedIndexInstr[i][CVA6Cfg.OneTageIndexWidth-1] ^ 1'b0 ^ GHRegInstr[i][CVA6Cfg.OneTageIndexWidth]};
                TwoTageFoldedIndexInstr[i] = {TwoTageFoldedIndexInstr[i][CVA6Cfg.TwoTageIndexWidth-2:0],
                          TwoTageFoldedIndexInstr[i][CVA6Cfg.TwoTageIndexWidth-1] ^ 1'b0 ^ GHRegInstr[i][CVA6Cfg.TwoTageIndexWidth]};
                ThreeTageFoldedIndexInstr[i] = {ThreeTageFoldedIndexInstr[i][CVA6Cfg.ThreeTageIndexWidth-2:0],
                          ThreeTageFoldedIndexInstr[i][CVA6Cfg.ThreeTageIndexWidth-1] ^ 1'b0 ^ GHRegInstr[i][CVA6Cfg.ThreeTageIndexWidth]};
                // Circular shift register-based update for folded tag
                OneTageFoldedTagInstr[i] = {OneTageFoldedTagInstr[i][CVA6Cfg.OneTageTagWidth-3:0], 
                      OneTageFoldedTagInstr[i][CVA6Cfg.OneTageTagWidth-1] ^ 1'b0 ^ GHRegInstr[i][CVA6Cfg.OneTageIndexWidth+CVA6Cfg.OneTageTagWidth],
                      OneTageFoldedTagInstr[i][CVA6Cfg.OneTageTagWidth-2]};
                TwoTageFoldedTagInstr[i] = {TwoTageFoldedTagInstr[i][CVA6Cfg.TwoTageTagWidth-4:0], 
                      TwoTageFoldedTagInstr[i][CVA6Cfg.TwoTageTagWidth-1] ^ 1'b0 ^ GHRegInstr[i][CVA6Cfg.TwoTageIndexWidth+CVA6Cfg.TwoTageTagWidth],
                      TwoTageFoldedTagInstr[i][CVA6Cfg.TwoTageTagWidth-2: CVA6Cfg.TwoTageTagWidth-3]};
                ThreeTageFoldedTagInstr[i] = {ThreeTageFoldedTagInstr[i][CVA6Cfg.ThreeTageTagWidth-5:0], 
                      ThreeTageFoldedTagInstr[i][CVA6Cfg.ThreeTageTagWidth-1] ^ 1'b0 ^ GHRegInstr[i][CVA6Cfg.ThreeTageIndexWidth+CVA6Cfg.ThreeTageTagWidth],
                      ThreeTageFoldedTagInstr[i][CVA6Cfg.ThreeTageTagWidth-2: CVA6Cfg.ThreeTageTagWidth-4]};
              end
            end
          end
      end
    end
  end


  // Debugging
  integer num_hit  = 0;
  integer num_miss = 0;
  always_ff@(posedge clk_i or negedge rst_ni) begin
    if(resolved_branch_i.valid && (resolved_branch_i.cf_type == ariane_pkg::Branch)) begin
      `ifdef VERILATOR
      
         if(resolved_branch_i.is_mispredict)begin
            num_miss = num_miss + 1;
            if(CVA6Cfg.TageEn) begin
              $display("[%0t][frontend][Recv] PC: %0b | BranchIdCnt : %d | Valid : %b  | Taken : %b (MISS) | Num_miss: %d", 
                  $time, resolved_branch_i.pc , resolved_branch_i.bid, TageResolveValid ,resolved_branch_i.is_taken, num_miss);
            end
            if(CVA6Cfg.GShareEn) begin
              $display("[%0t][frontend][Recv] PC: %0b | Index: %0b | Taken : %b (MISS) | GSHARE Curr: %0b | Resolve : %0b | Num_miss: %d", $time,
                resolved_branch_i.pc, resolved_branch_i.gshare_index, resolved_branch_i.is_taken, GShareHistoryRegister_q, resolved_branch_i.gshare_resolve, num_miss);
            end
            else if(!CVA6Cfg.GShareEn && !CVA6Cfg.TageEn)begin
              $display("[%0t] Num_miss: %d", $time, num_miss);
            end

          end else begin
            num_hit = num_hit + 1;
            if(CVA6Cfg.TageEn) begin
            $display("[%0t][frontend][Recv] PC: %0b  | BranchIdCnt : %d | Valid : %b |  Taken : %b (HIT) | Num_hit : %d", 
                  $time,  resolved_branch_i.pc, resolved_branch_i.bid, TageResolveValid, resolved_branch_i.is_taken, num_hit);
            end
            if(CVA6Cfg.GShareEn) begin
              $display("[%0t][frontend][Recv] PC: %0b | Index: %0b | Taken : %b (HIT) | GSHARE Curr: %0b | Resolve : %0b | Num_hit: %d", $time,
                resolved_branch_i.pc, resolved_branch_i.gshare_index, resolved_branch_i.is_taken, GShareHistoryRegister_q, resolved_branch_i.gshare_resolve, num_hit);
            end
            else if(!CVA6Cfg.GShareEn && !CVA6Cfg.TageEn) begin
              $display("[%0t] Num_hit: %d", $time, num_hit);
            end
         end
   `endif
    end
  end 

  if (CVA6Cfg.BTBEntries == 0) begin
    assign btb_prediction = '0;
  end else begin : btb_gen
    btb #(
        .CVA6Cfg   (CVA6Cfg),
        .btb_update_t(btb_update_t),
        .btb_prediction_t(btb_prediction_t),
        .NR_ENTRIES(CVA6Cfg.BTBEntries)
    ) i_btb (
        .clk_i,
        .rst_ni,
        .flush_bp_i      (flush_bp_i),
        .debug_mode_i,
        .vpc_i           (vpc_btb),
        .btb_update_i    (btb_update),
        .btb_prediction_o(btb_prediction)
    );
  end

  if (CVA6Cfg.BHTEntries == 0) begin
    assign bht_prediction = '0;
  end else if (!CVA6Cfg.TageEn && CVA6Cfg.BPType == config_pkg::BHT) begin : bht_gen
    bht #(
        .CVA6Cfg   (CVA6Cfg),
        .bht_update_t(bht_update_t),
        .NR_ENTRIES(CVA6Cfg.BHTEntries)
    ) i_bht (
        .clk_i,
        .rst_ni,
        .flush_bp_i      (flush_bp_i),
        .debug_mode_i,
        .vpc_i           (vpc_bht),
        .bht_update_i    (bht_update),
        .bht_prediction_o(bht_prediction)
    );
  end else if (CVA6Cfg.BPType == config_pkg::PH_BHT) begin : bht2lvl_gen
    bht2lvl #(
        .CVA6Cfg     (CVA6Cfg),
        .bht_update_t(bht_update_t)
    ) i_bht (
        .clk_i,
        .rst_ni,
        .flush_i         (flush_bp_i),
        .vpc_i           (icache_vaddr_q),
        .bht_update_i    (bht_update),
        .bht_prediction_o(bht_prediction)
    );
  end

  // we need to inspect up to CVA6Cfg.INSTR_PER_FETCH instructions for branches
  // and jumps
  for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_instr_scan
    instr_scan #(
        .CVA6Cfg(CVA6Cfg)
    ) i_instr_scan (
        .instr_i     (instr[i]),
        .rvi_return_o(rvi_return[i]),
        .rvi_call_o  (rvi_call[i]),
        .rvi_branch_o(rvi_branch[i]),
        .rvi_jalr_o  (rvi_jalr[i]),
        .rvi_jump_o  (rvi_jump[i]),
        .rvi_imm_o   (rvi_imm[i]),
        .rvc_branch_o(rvc_branch[i]),
        .rvc_jump_o  (rvc_jump[i]),
        .rvc_jr_o    (rvc_jr[i]),
        .rvc_return_o(rvc_return[i]),
        .rvc_jalr_o  (rvc_jalr[i]),
        .rvc_call_o  (rvc_call[i]),
        .rvc_imm_o   (rvc_imm[i])
    );
  end

  instr_queue #(
      .CVA6Cfg(CVA6Cfg),
      .fetch_entry_t(fetch_entry_t)
  ) i_instr_queue (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .flush_i            (flush_i),
      .instr_i            (instr),                 // from re-aligner
      .addr_i             (addr),                  // from re-aligner
      .GHRStatus_i        ({GHRegInstr[CVA6Cfg.INSTR_PER_FETCH-2:0],GlobalHistoryRegister}), // SeongwonJo 
      .GShareStatus_i     ({GShareHistoryRegister_q,GShareHistoryRegister_q}),
      .GShareUpdateIndex_i({gshare_prediction_shifted[1].index, gshare_prediction_shifted[0].index}),
      .branchId_i         (BranchIdCnt_d),
      .vpc_tage_shifted_i (vpc_tage_shifted),
      .exception_i        (icache_ex_valid_q),     // from I$
      .exception_addr_i   (icache_vaddr_q),
      .exception_gpaddr_i (icache_gpaddr_q),
      .exception_tinst_i  (icache_tinst_q),
      .exception_gva_i    (icache_gva_q),
      .predict_address_i  (predict_address),
      .cf_type_i          (cf_type),
      .valid_i            (instruction_valid),     // from re-aligner
      .consumed_o         (instr_queue_consumed),
      .ready_o            (instr_queue_ready),
      .replay_o           (replay),
      .replay_addr_o      (replay_addr),
      .fetch_entry_o      (fetch_entry_o),         // to back-end
      .fetch_entry_valid_o(fetch_entry_valid_o),   // to back-end
      .fetch_entry_ready_i(fetch_entry_ready_i)    // to back-end
  );

endmodule
