module GShareTable #(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type gshare_update_t = logic,
    parameter type gshare_prediction_t = logic,
    parameter int unsigned NR_ENTRIES = 32,
    parameter int unsigned NR_TABLE = 1
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Branch prediction flush request - zero
    input logic flush_bp_i,
    // Debug mode state - CSR
    input logic debug_mode_i,
    // Virtual PC - CACHE
    input logic [CVA6Cfg.VLEN-1:0] vpc_i,
    input logic [CVA6Cfg.GSHAREWIDTH-1:0] gshare_i,
    // Update bht with resolved address - EXECUTE
    input gshare_update_t gshare_update_i,
    // Prediction from bht - FRONTEND
    output gshare_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0] gshare_prediction_o
);

  // the last bit is always zero, we don't need it for indexing
  localparam OFFSET = CVA6Cfg.RVC == 1'b1 ? 1 : 2;                                   
  // re-shape the branch history table
  localparam NR_ROWS = NR_ENTRIES / CVA6Cfg.INSTR_PER_FETCH;                           
  // number of bits needed to index the row
  localparam ROW_ADDR_BITS = $clog2(CVA6Cfg.INSTR_PER_FETCH);                           
  localparam ROW_INDEX_BITS = CVA6Cfg.RVC == 1'b1 ? $clog2(CVA6Cfg.INSTR_PER_FETCH) : 1; 
  // number of bits we should use for prediction
  localparam PREDICTION_BITS = $clog2(NR_ROWS) + OFFSET + ROW_ADDR_BITS;                

  struct packed {
    logic       valid;
    logic [1:0] saturation_counter;
  }
      gsharebase_d[NR_ROWS-1:0][CVA6Cfg.INSTR_PER_FETCH-1:0],
      gsharebase_q[NR_ROWS-1:0][CVA6Cfg.INSTR_PER_FETCH-1:0]; 

  logic [$clog2(NR_ROWS)-1:0] index, update_pc;
  logic [ROW_INDEX_BITS-1:0] update_row_index, update_row_index_q, check_update_row_index;


  // GSHARE INDEX Hashing 
  assign index     = vpc_i           [PREDICTION_BITS-1:             ROW_ADDR_BITS+OFFSET] ^ gshare_i; 
  assign update_pc = gshare_update_i.index;

  if (CVA6Cfg.RVC) begin : gen_update_row_index
    assign update_row_index = gshare_update_i.pc[ROW_ADDR_BITS+OFFSET-1:OFFSET]; 
  end else begin
    assign update_row_index = '0;                               
  end

  if (!CVA6Cfg.FpgaEn) begin : gen_asic_Gshare  // ASIC TARGET

    logic [1:0] saturation_counter; // 2-bit saturation counter
    // prediction assignment
    for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_bht_output
      assign gshare_prediction_o[i].valid =  gsharebase_q[index][i].valid;
      assign gshare_prediction_o[i].taken = (gsharebase_q[index][i].saturation_counter[1] == 1'b1);
      assign gshare_prediction_o[i].index = index;
    end

    always_comb begin : update_gshare
      saturation_counter = 0;
      gsharebase_d = gsharebase_q;

        
      saturation_counter = gsharebase_d[update_pc][update_row_index].saturation_counter;
      if((gshare_update_i.valid && CVA6Cfg.DebugEn && !debug_mode_i) || (gshare_update_i.valid && !CVA6Cfg.DebugEn))  begin
            gsharebase_d[update_pc][update_row_index].valid = 1;
            saturation_counter = gsharebase_d[update_pc][update_row_index].saturation_counter;

            // Saturation Counter Update
            if(saturation_counter == 2'b11) begin 
                if(!gshare_update_i.taken) begin
                    gsharebase_d[update_pc][update_row_index].saturation_counter = saturation_counter - 1;
                end
            end else if(saturation_counter == 2'b00) begin
                if(gshare_update_i.taken)  begin
                    gsharebase_d[update_pc][update_row_index].saturation_counter = saturation_counter + 1;
                end
            end else begin
                if (gshare_update_i.taken) begin
                    gsharebase_d[update_pc][update_row_index].saturation_counter = saturation_counter + 1;
                  end
                else  begin
                  gsharebase_d[update_pc][update_row_index].saturation_counter = saturation_counter - 1;
                end
            end
        end
    end : update_gshare

    always_ff @(posedge clk_i or negedge rst_ni) begin : gshare_q_update
      if (!rst_ni) begin
        for (int unsigned i = 0; i < NR_ROWS; i++) begin
          for (int j = 0; j < CVA6Cfg.INSTR_PER_FETCH; j++) begin
            gsharebase_q[i][j].valid = '0;
            gsharebase_q[i][j].saturation_counter = 2'b00;
          end
        end
      end else begin
        // evict all entries
        if (flush_bp_i) begin
          for (int i = 0; i < NR_ROWS; i++) begin
            for (int j = 0; j < CVA6Cfg.INSTR_PER_FETCH; j++) begin
              gsharebase_q[i][j].valid <= 1'b0;
              gsharebase_q[i][j].saturation_counter <= 2'b10;
            end
          end
        end else begin
          gsharebase_q <= gsharebase_d;
        end
      end
    end : gshare_q_update
  end: gen_asic_Gshare

endmodule

