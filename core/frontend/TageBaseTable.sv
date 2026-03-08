
module TageBaseTable #(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type tage_update_t = logic,
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
    // Update bht with resolved address - EXECUTE
    input tage_update_t tage_update_i,
    input logic tage_allocation_i,
    // Prediction from bht - FRONTEND
    output ariane_pkg::tage_table_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0] tage_prediction_o
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
      tagebase_d[NR_ROWS-1:0][CVA6Cfg.INSTR_PER_FETCH-1:0], 
      tagebase_q[NR_ROWS-1:0][CVA6Cfg.INSTR_PER_FETCH-1:0]; 

  logic [$clog2(NR_ROWS)-1:0] index, update_pc;
  logic [ROW_INDEX_BITS-1:0] update_row_index, update_row_index_q, check_update_row_index;


  // TAGE Base table does not have hashing function or Tag bits. It is same to BHT.
  assign index     = vpc_i           [PREDICTION_BITS-1:             ROW_ADDR_BITS+OFFSET];           
  assign update_pc = tage_update_i.pc[PREDICTION_BITS-1:  ROW_ADDR_BITS+OFFSET]; 

  if (CVA6Cfg.RVC) begin : gen_update_row_index
    assign update_row_index = tage_update_i.pc[ROW_ADDR_BITS+OFFSET-1:OFFSET]; 
  end else begin
    assign update_row_index = '0;                                      
  end

  if (!CVA6Cfg.FpgaEn) begin : gen_asic_bht  // ASIC TARGET

    logic [1:0] saturation_counter; // 2-bit saturation counter
    // prediction assignment
    for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_bht_output
      assign tage_prediction_o[i].valid =  tagebase_q[index][i].valid;
      assign tage_prediction_o[i].taken = (tagebase_q[index][i].saturation_counter[1] == 1'b1);
      assign tage_prediction_o[i].confidence = (tagebase_q[index][i].saturation_counter == 2'b11 || tagebase_q[index][i].saturation_counter == 2'b00);
    end

    always_comb begin : update_tage
      saturation_counter = 0;
      tagebase_d = tagebase_q;

      if(tage_allocation_i) begin
        saturation_counter = tagebase_q[update_pc][update_row_index].saturation_counter;

        if((CVA6Cfg.DebugEn && !debug_mode_i) || (!CVA6Cfg.DebugEn)) begin
            if(!tagebase_q[update_pc][update_row_index].valid) begin
                tagebase_d[update_pc][update_row_index].valid  = 1'b1;
                if(tage_update_i.taken) begin
                    tagebase_d[update_pc][update_row_index].saturation_counter = 2'b01;
                end else begin
                    tagebase_d[update_pc][update_row_index].saturation_counter = 2'b00;
                end
            end else begin
              // Allocation Error
                $fatal(2, "ERORRO  | Tage Base Table Error (Table Indexing Error)");
            end 
        end
      end else begin
        if((tage_update_i.valid && CVA6Cfg.DebugEn && !debug_mode_i) || (tage_update_i.valid && !CVA6Cfg.DebugEn))  begin

            saturation_counter = tagebase_d[update_pc][update_row_index].saturation_counter;

            // Saturation Counter Update
            if(saturation_counter == 2'b11) begin
                if(!tage_update_i.taken) begin
                    tagebase_d[update_pc][update_row_index].saturation_counter = saturation_counter - 1;
                end
            end else if(saturation_counter == 2'b00) begin
                if(tage_update_i.taken)  begin
                    tagebase_d[update_pc][update_row_index].saturation_counter = saturation_counter + 1;
                end
            end else begin
                if (tage_update_i.taken) begin
                    tagebase_d[update_pc][update_row_index].saturation_counter = saturation_counter + 1;
                  end
                else  begin
                  tagebase_d[update_pc][update_row_index].saturation_counter = saturation_counter - 1;
                end
            end
        end
      end
    end : update_tage

    always_ff @(posedge clk_i or negedge rst_ni) begin : tage_q_update
      if (!rst_ni) begin
        for (int unsigned i = 0; i < NR_ROWS; i++) begin
          for (int j = 0; j < CVA6Cfg.INSTR_PER_FETCH; j++) begin
            tagebase_q[i][j].valid <= '0;
            tagebase_q[i][j].saturation_counter <= 2'b00;
          end
        end
      end else begin
        // evict all entries
        if (flush_bp_i) begin
          for (int i = 0; i < NR_ROWS; i++) begin
            for (int j = 0; j < CVA6Cfg.INSTR_PER_FETCH; j++) begin
              tagebase_q[i][j].valid <= 1'b0;
              tagebase_q[i][j].saturation_counter <= 2'b10;
            end
          end
        end else begin
          tagebase_q <= tagebase_d;
        end
      end
    end : tage_q_update
  end 
endmodule

