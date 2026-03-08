module TageTable#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type tage_update_t = logic,
    parameter int unsigned INDEXWIDTH = 6,
    parameter int unsigned TAGWIDTH = 8,
    parameter int unsigned NR_ENTRIES = 32,
    parameter int unsigned NR_TABLE = 1
)(
    input logic clk_i,
    input logic rst_ni,
    input logic flush_bp_i,
    input logic debug_mode_i,
    input logic [CVA6Cfg.VLEN-1:0] vpc_i,
    input tage_update_t tage_update_i,

    input logic tage_allocation_i,
    input logic [INDEXWIDTH - 1  : 0] tage_resolve_index_i,
    input logic [TAGWIDTH    -1  : 0] tage_resolve_tag_i,

    input logic [INDEXWIDTH - 1  : 0] tage_folded_index_i,
    input logic [TAGWIDTH    -1  : 0] tage_folded_tag_i,

    output logic [INDEXWIDTH - 1  : 0] tage_predict_index_o,
    output logic [TAGWIDTH    -1  : 0] tage_predict_tag_o,

    output logic allocable_o,

    output ariane_pkg::tage_table_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0] tage_prediction_o

);

  localparam OFFSET = (CVA6Cfg.RVC == 1'b1) ? 1 : 2;
  localparam NR_ROWS = NR_ENTRIES / CVA6Cfg.INSTR_PER_FETCH;
  localparam ROW_ADDR_BITS = $clog2(CVA6Cfg.INSTR_PER_FETCH);
  localparam ROW_INDEX_BITS = CVA6Cfg.RVC == 1'b1 ? $clog2(CVA6Cfg.INSTR_PER_FETCH) : 1;
  
  localparam PREDICT_INDEX_BITS = $clog2(NR_ROWS) + OFFSET + ROW_ADDR_BITS; // INDEX
  localparam PREDICT_TAG_BITS   = TAGWIDTH + PREDICT_INDEX_BITS;


  localparam type TableEntry = struct packed {
    logic valid;
    logic [1:0] saturation_counter;
    logic [TAGWIDTH-1:0] tag;
    logic [1:0] useful;
  };
  TableEntry TageTable_d [NR_ROWS-1:0][CVA6Cfg.INSTR_PER_FETCH-1:0];
  TableEntry TageTable_q [NR_ROWS-1:0][CVA6Cfg.INSTR_PER_FETCH-1:0];

  // folded Index + PC 연산 
  logic [INDEXWIDTH     -1:0] index, update_index;
  logic [TAGWIDTH       -1:0] tag, update_tag;
  logic [ROW_INDEX_BITS -1:0] update_row;
  
  // Index Hashing Function : PC-bits ^ folded_index
  assign index = vpc_i[PREDICT_INDEX_BITS-1:ROW_ADDR_BITS+OFFSET] ^ tage_folded_index_i;
  // Tag Hashing Function : PC-bits (except above bits) ^ folded_tag
  assign tag   = vpc_i[PREDICT_TAG_BITS-1:PREDICT_INDEX_BITS] ^ tage_folded_tag_i;



  assign update_index =  tage_resolve_index_i;
  assign update_tag   =  tage_resolve_tag_i;

  // Predict INDEX, TAG will be stored in CheckPoint Queue.
  assign tage_predict_index_o = index;
  assign tage_predict_tag_o   = tag;

  if(CVA6Cfg.RVC) begin 
    assign update_row = tage_update_i.pc[ROW_ADDR_BITS+OFFSET-1:OFFSET];
  end else begin
    assign update_row = 0;
  end

  logic [1:0] saturation_counter;
  logic [1:0] useful;
  logic full;
  logic replacement;

  for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
    assign tage_prediction_o[i].valid      = (TageTable_q[index][i].valid) && (TageTable_q[index][i].tag == tag); 
    assign tage_prediction_o[i].taken      = (TageTable_q[index][i].saturation_counter[1] == 1'b1);
    assign tage_prediction_o[i].confidence = (TageTable_q[index][i].saturation_counter == 2'b11 || TageTable_q[index][i].saturation_counter == 2'b00);
  end


  // Table Allocatable Setup
  // Allocatable -> Not FULL or Having 0-bits Useful in entry.
  always_comb begin
    full = 1;
    for(int i = 0; i< CVA6Cfg.INSTR_PER_FETCH; i++) begin
      for(int j = 0; j < NR_ROWS; j++) begin
        if(!TageTable_q[j][i].valid) begin
          full = 0;
        end
      end
    end
  end

  always_comb begin
    replacement = 0;
    for(int i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
      for(int j = 0; j < NR_ROWS; j++) begin
          if(TageTable_q[j][i].valid) begin
            if(TageTable_q[j][i].useful == 2'b00) begin
              replacement = 1;
            end
          end
      end
    end
  end
  assign allocable_o = !full || replacement;

  always_comb begin : update_table
    TageTable_d = TageTable_q;
    saturation_counter = TageTable_q[update_index][update_row].saturation_counter;
    useful = TageTable_q[update_index][update_row].useful;

    if((CVA6Cfg.DebugEn && !debug_mode_i) || (!CVA6Cfg.DebugEn)) begin
        if(tage_update_i.valid && (TageTable_q[update_index][update_row].valid  &&
            (TageTable_q[update_index][update_row].tag == update_tag))) begin
                       
            // Useful Update
            if(useful == 2'b00) begin
              if(!tage_update_i.miss) begin
                TageTable_d[update_index][update_row].useful = useful + 1;
              end            
            end else if(useful == 2'b11)begin
              if(tage_update_i.miss) begin
                TageTable_d[update_index][update_row].useful = useful - 1;
              end
            end else begin
                if(tage_update_i.miss) begin
                  TageTable_d[update_index][update_row].useful = useful- 1;
                end else begin
                  TageTable_d[update_index][update_row].useful = useful + 1;
                end            
            end

            // Saturation counter Update
            if(saturation_counter == 2'b11) begin
                if(!tage_update_i.taken) 
                    TageTable_d[update_index][update_row].saturation_counter = saturation_counter - 1;
            end
            else if(saturation_counter == 2'b00) begin
                if(tage_update_i.taken) 
                    TageTable_d[update_index][update_row].saturation_counter = saturation_counter + 1;
            end else begin
                if(tage_update_i.taken)
                    TageTable_d[update_index][update_row].saturation_counter = saturation_counter + 1;
                else TageTable_d[update_index][update_row].saturation_counter = saturation_counter - 1;   
            end
        end else if(tage_allocation_i) begin 
            if(TageTable_d[update_index][update_row].valid && (TageTable_d[update_index][update_row].tag == update_tag))  begin
                  // Alloc
              $fatal(0,"[%0t][Table-%d] Allocation Error",$time, NR_TABLE);
            end
            if(!TageTable_d[update_index][update_row].valid) begin : AllocationEntry

                // Initialization                
                TageTable_d[update_index][update_row].valid  = 1;
                TageTable_d[update_index][update_row].tag    = update_tag;
                TageTable_d[update_index][update_row].useful = 2'b01;
                
                // Saturation counter setup
                if(tage_update_i.taken) begin
                  TageTable_d[update_index][update_row].saturation_counter = 2'b10;
                end else TageTable_d[update_index][update_row].saturation_counter = 2'b01;

            end else begin : ReplacementEntry
              if(TageTable_d[update_index][update_row].useful == 2'b00) begin
                // Table entry replacement

                TageTable_d[update_index][update_row].valid = 1;
                TageTable_d[update_index][update_row].tag = update_tag;
                TageTable_d[update_index][update_row].useful = 2'b01;
                
                if(tage_update_i.taken) begin
                  TageTable_d[update_index][update_row].saturation_counter = 2'b10;
                end else TageTable_d[update_index][update_row].saturation_counter = 2'b01;
              end else begin
                // If replacement is impossible, then do for decreasing useful bits.                
                TageTable_d[update_index][update_row].useful = useful - 1;
              end
            end
        end 
    end
  end : update_table

  always_ff @(posedge clk_i or negedge rst_ni) begin :update_TageTable
    if(!rst_ni) begin
      for(int unsigned i = 0; i < NR_ROWS; i++) begin
        for(int j = 0; j < CVA6Cfg.INSTR_PER_FETCH; j++) begin
          TageTable_q[i][j] = '0;
        end
      end
    end else begin
      if(flush_bp_i) begin
        for(int i = 0; i < NR_ROWS; i++) begin
          for(int j = 0; j < CVA6Cfg.INSTR_PER_FETCH; j++) begin
            TageTable_q[i][j].valid              <= '0;
            TageTable_q[i][j].saturation_counter <= '0;
            TageTable_q[i][j].tag                <= '0;
            TageTable_q[i][j].useful             <= '0;
          end
        end 
      end else begin
        TageTable_q <= TageTable_d;
      end
    end
  end 

endmodule
