`timescale 1ns / 1ps
`default_nettype none

module tb_top_module;

    localparam AXI_HP_BIT = 64;
    localparam DATA_WIDTH = 16;
    localparam ROW_WIDTH  = 10;
    localparam ADDR_WIDTH = 14;
    localparam CLK_PERIOD = 10;
    
    reg clk = 0;
    reg reset;

    // AXI input - image
    reg  [AXI_HP_BIT-1:0] S_AXIS_TDATA_0;
    reg                   S_AXIS_TVALID_0;
    reg                   S_AXIS_TLAST_0;
    wire                  S_AXIS_TREADY_0;

    // AXI output - image
    wire [AXI_HP_BIT-1:0] M_AXIS_TDATA_0;
    wire                  M_AXIS_TVALID_0;
    wire                  M_AXIS_TLAST_0;
    reg                   M_AXIS_TREADY_0;

    // AXI input - weight
    reg  [AXI_HP_BIT-1:0] S_AXIS_TDATA_1;
    reg                   S_AXIS_TVALID_1;
    reg                   S_AXIS_TLAST_1;
    wire                  S_AXIS_TREADY_1;

    // AXI output - weight
    wire [AXI_HP_BIT-1:0] M_AXIS_TDATA_1;
    wire                  M_AXIS_TVALID_1;
    wire                  M_AXIS_TLAST_1;
    reg                   M_AXIS_TREADY_1;

    // MMIO BRAM
    wire  [31:0]          bram_addrb;
    wire                  bram_enb;
    wire  [63:0]          bram_dinb; // unused
    wire  [7:0]           bram_web;  // unused
    wire  [63:0]          bram_doutb;

    reg   [63:0]          bram_dummy_mem [0:1023]; // Fake BRAM
    reg   [63:0]          doutb_reg;
    reg   [31:0]          bram_addrb_reg;
    
    wire [DATA_WIDTH*6*6-1:0] in6_im2col_data;
    wire input_valid;
    
    wire [AXI_HP_BIT-1:0] C1_wr_data;
    // Clock generation
    always #(CLK_PERIOD/2) clk = ~clk;

    assign bram_doutb = doutb_reg;

    top_module #(
        .AXI_HP_BIT(AXI_HP_BIT),
        .DATA_WIDTH(DATA_WIDTH),
        .ROW_WIDTH(ROW_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
        .clk(clk),
        .reset(reset),

        .S_AXIS_TDATA_0(S_AXIS_TDATA_0),
        .S_AXIS_TVALID_0(S_AXIS_TVALID_0),
        .S_AXIS_TLAST_0(S_AXIS_TLAST_0),
        .S_AXIS_TREADY_0(S_AXIS_TREADY_0),

        .M_AXIS_TDATA_0(M_AXIS_TDATA_0),
        .M_AXIS_TVALID_0(M_AXIS_TVALID_0),
        .M_AXIS_TLAST_0(M_AXIS_TLAST_0),
        .M_AXIS_TREADY_0(M_AXIS_TREADY_0),

        .S_AXIS_TDATA_1(S_AXIS_TDATA_1),
        .S_AXIS_TVALID_1(S_AXIS_TVALID_1),
        .S_AXIS_TLAST_1(S_AXIS_TLAST_1),
        .S_AXIS_TREADY_1(S_AXIS_TREADY_1),

        .M_AXIS_TDATA_1(M_AXIS_TDATA_1),
        .M_AXIS_TVALID_1(M_AXIS_TVALID_1),
        .M_AXIS_TLAST_1(M_AXIS_TLAST_1),
        .M_AXIS_TREADY_1(M_AXIS_TREADY_1),

        .bram_addrb(bram_addrb),
        .bram_dinb(bram_dinb),
        .bram_doutb(bram_doutb),
        .bram_enb(bram_enb),
        .bram_web(bram_web)
//        .C_wr_data(C1_wr_data)
//        .in6_im2col_data(in6_im2col_data),
//        .im2col_valid_in(input_valid)
    );

    localparam INPUT_DATA = 15360;
    localparam WEIGHT_DATA = 8640;

    reg [15:0] input_data [0:INPUT_DATA - 1];  // 100       ?    4 ?  = 400           6400
    reg [15:0] weight_data [0:WEIGHT_DATA - 1];  // 100       ?    4 ?  = 400           6400
    
    wire signed [15:0] meissa_data [0:3];
    
    assign meissa_data [0] = C1_wr_data [15:0];
    assign meissa_data [1] = C1_wr_data [31:16];
    assign meissa_data [2] = C1_wr_data [47:32];
    assign meissa_data [3] = C1_wr_data [63:48];
 
    reg [31:0] B_count;     
    
    integer i, j, k, l;

//    initial begin
//        for (j = 0; j < INPUT_DATA; j = j + 1) begin
//            input_data[j] = (j % 40) - 20; // -160 ~ +159
//        end
//    end

    initial begin
        for (j = 0; j < INPUT_DATA; j = j + 1) begin
            input_data[j] = j % 640 ; 
        end
    end
       
    initial begin
        for (i = 0; i < WEIGHT_DATA; i = i + 1)
            weight_data[i] = i % 20;  //              ??   
        end

    integer i, j;

    initial begin
        reset = 0;
        S_AXIS_TDATA_0 = 0;
        S_AXIS_TVALID_0 = 0;
        S_AXIS_TLAST_0 = 0;
        M_AXIS_TREADY_0 = 0;

        S_AXIS_TDATA_1 = 0;
        S_AXIS_TVALID_1 = 0;
        S_AXIS_TLAST_1 = 0;
        M_AXIS_TREADY_1 = 0;

        doutb_reg = 0;
        

        // Initialize fake BRAM memory
//        for (i = 0; i < 1024; i = i + 1)
//            bram_dummy_mem[i] = 64'h2000_0000 + i;


        //CONVOLUTION
        bram_dummy_mem[0][63:61] = 3'b001;  // opcode
        bram_dummy_mem[0][60:51] = 10'd640; // in_row
        bram_dummy_mem[0][50:41] = 10'd8;  // in_col
        bram_dummy_mem[0][40:38] = 3'd3;    // kernel
        bram_dummy_mem[0][37:36] = 2'd2;    // stride
        bram_dummy_mem[0][35:34] = 2'd2;    // padding
        bram_dummy_mem[0][33:32] = 2'd1;    // slice_count (tile count)
        bram_dummy_mem[0][31:20] = 12'd20;    // input channel
        bram_dummy_mem[0][19:8] = 12'd40;    // output channel
        bram_dummy_mem[0][7:0] = 26'b0;    // 
                       
        //CONVOLUTION(KERNEL1)
//        bram_dummy_mem[0][63:61] = 3'b000;  // opcode
//        bram_dummy_mem[0][60:51] = 10'd10; // in_row
//        bram_dummy_mem[0][50:41] = 10'd10;  // in_col
//        bram_dummy_mem[0][40:38] = 3'd1;    // kernel
//        bram_dummy_mem[0][37:36] = 2'd1;    // stride
//        bram_dummy_mem[0][35:34] = 2'd0;    // padding
//        bram_dummy_mem[0][33:32] = 2'd0;    // slice_count (tile count)
//        bram_dummy_mem[0][31:20] = 12'd20;    // input channel
//        bram_dummy_mem[0][19:8] = 12'd20;    // output channel
//        bram_dummy_mem[0][7:0] = 8'b0;    // 
                       
                       
        #(CLK_PERIOD * 5);
        reset = 1;

        // Wait 5 cycles
        #(CLK_PERIOD * 5);
        
        // === SETTING INPUT DATA ===
        @(posedge clk);
        for (i = 0; i < INPUT_DATA/4; i = i + 1) begin
            @(posedge clk);
            
            S_AXIS_TDATA_0  <= {
                input_data[i*4 + 3],
                input_data[i*4 + 2],
                input_data[i*4 + 1],
                input_data[i*4 + 0]
            };  //    64  ?   packing
        
            S_AXIS_TVALID_0 <= 1;
            S_AXIS_TLAST_0  <= (i == INPUT_DATA/4 - 1);  //        ?  TLAST     
        
            while (!S_AXIS_TREADY_0) @(posedge clk);
        end

        @(posedge clk);
        S_AXIS_TVALID_0 <= 0;
        S_AXIS_TLAST_0  <= 0;

        // === SETTING WEIGHT DATA ===
        @(posedge clk);
        for (i = 0; i < WEIGHT_DATA/4; i = i + 1) begin
            @(posedge clk);
            
            S_AXIS_TDATA_1  <= {
                weight_data[i*4 + 3],
                weight_data[i*4 + 2],
                weight_data[i*4 + 1],
                weight_data[i*4 + 0]
            };  //    64  ?   packing
        
            S_AXIS_TVALID_1 <= 1;
            S_AXIS_TLAST_1  <= (i == WEIGHT_DATA/4 - 1);  //        ?  TLAST     
        
            while (!S_AXIS_TREADY_0) @(posedge clk);
        end

        @(posedge clk);
        S_AXIS_TVALID_1 <= 0;
        S_AXIS_TLAST_1  <= 0;

        // === Start output streaming ===
        #(CLK_PERIOD * 100);
        M_AXIS_TREADY_0 = 1;
        M_AXIS_TREADY_1 = 1;
        
        #(CLK_PERIOD * 10000);
        $finish;
    end

//     === Simulate BRAM read with 1-clock delay ===
    always @(posedge clk) begin
        if (bram_enb)
            bram_addrb_reg <= bram_addrb;

        doutb_reg <= bram_dummy_mem[bram_addrb_reg];
//        if (bram_enb)
//            $display("[BRAM] READ @ %0d = %h", bram_addrb, bram_dummy_mem[bram_addrb]);
    end

always @(posedge clk) begin
    if (input_valid) begin
        $display("=== in6_im2col_data (6x6 matrix) ===");
        $display("%d %d %d %d %d %d",
                 in6_im2col_data[0*16 +: 16],  in6_im2col_data[1*16 +: 16],
                 in6_im2col_data[2*16 +: 16],  in6_im2col_data[3*16 +: 16],
                 in6_im2col_data[4*16 +: 16],  in6_im2col_data[5*16 +: 16]);
        $display("%d %d %d %d %d %d",
                 in6_im2col_data[6*16 +: 16],  in6_im2col_data[7*16 +: 16],
                 in6_im2col_data[8*16 +: 16],  in6_im2col_data[9*16 +: 16],
                 in6_im2col_data[10*16 +: 16], in6_im2col_data[11*16 +: 16]);
        $display("%d %d %d %d %d %d",
                 in6_im2col_data[12*16 +: 16], in6_im2col_data[13*16 +: 16],
                 in6_im2col_data[14*16 +: 16], in6_im2col_data[15*16 +: 16],
                 in6_im2col_data[16*16 +: 16], in6_im2col_data[17*16 +: 16]);
        $display("%d %d %d %d %d %d",
                 in6_im2col_data[18*16 +: 16], in6_im2col_data[19*16 +: 16],
                 in6_im2col_data[20*16 +: 16], in6_im2col_data[21*16 +: 16],
                 in6_im2col_data[22*16 +: 16], in6_im2col_data[23*16 +: 16]);
        $display("%d %d %d %d %d %d",
                 in6_im2col_data[24*16 +: 16], in6_im2col_data[25*16 +: 16],
                 in6_im2col_data[26*16 +: 16], in6_im2col_data[27*16 +: 16],
                 in6_im2col_data[28*16 +: 16], in6_im2col_data[29*16 +: 16]);
        $display("%d %d %d %d %d %d",
                 in6_im2col_data[30*16 +: 16], in6_im2col_data[31*16 +: 16],
                 in6_im2col_data[32*16 +: 16], in6_im2col_data[33*16 +: 16],
                 in6_im2col_data[34*16 +: 16], in6_im2col_data[35*16 +: 16]);
        $display("====================================");
    end
end



endmodule
