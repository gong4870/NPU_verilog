`default_nettype none

module conv_control #(
    parameter
        AXI_HP_BIT   = 64,
        ADDR_WIDTH   = 14,
        DATA_WIDTH   = 16,
        ROW_WIDTH    = 10,
        COLUMN_WIDTH = 9,
        MAC_WIDTH    = DATA_WIDTH + DATA_WIDTH,
        OUT_WIDTH    = MAC_WIDTH + 4
)(
    input  wire                                            clk,
    input  wire                                            reset,
    input  wire                                            sudo_reset,
   
    input  wire                                            conv_en,
    output reg                                             conv_done,
    output reg                                             conv_wait,
    input  wire                                            conv_go,
   
    //OPCODE DATA
    input wire  [9:0]                                      in_row,     // Է                  
    input wire  [9:0]                                      in_column,  // Է                  
    input wire  [2:0]                                      kernel,     //kernel      
    input wire  [1:0]                                      padding,    //padding  
    input wire  [1:0]                                      stride,     //stride  
    input wire  [1:0]                                      slice_cnt,  //BRAM         input      ° slice      ˷  ִ    ȣ
    input wire  [11:0]                                     input_channel,  //weight channel  
    input wire  [11:0]                                     output_channel,  //weight channel  
   
    //control im2col
    output reg                                             image_pause,      //stop im2col
    output reg                                             weight_pause,
    input wire                                             im2col_valid_in, //to know im2col data valid
    input wire                                             im2col_valid_we,
    output reg                                             in_rd_clear,
    output reg                                             we_rd_clear,  
   
    //delete im2col buffer
    output reg                                             im_valid_del,
    output reg                                             we_valid_del,    
   
    //start to bring data from slice
    output reg                                             image_read,
    output reg                                             weight_read,
   
    //data in
    input wire [DATA_WIDTH*COLUMN_WIDTH - 1:0]             image_data,
    input wire [DATA_WIDTH*COLUMN_WIDTH*ROW_WIDTH - 1:0]   weight_data,
    input wire                                             image_valid,
    input wire                                             weight_valid,
   
    //OUTPUT BRAM WRITE          
    output reg                                             out_wr_en,
    output reg [ADDR_WIDTH-1:0]                            out_wr_addr,
    output reg [AXI_HP_BIT-1:0]                            out_wr_data
   
    //to testbench
//    output wire [MAC_WIDTH*COLUMN_WIDTH*ROW_WIDTH - 1:0]   dataout,
//    output wire [OUT_WIDTH*ROW_WIDTH - 1:0]                result
);

    function signed [15:0] sat_q7_9;
        input signed [63:0] acc;  // buffer  
        reg   signed [63:0] scaled;
        begin
            // Q14.18    Q7.9   ȯ (>> 9)
            scaled = acc >>> 9;
   
            // saturation ó  
            if (scaled > 32767)
                sat_q7_9 = 16'sh7FFF;
            else if (scaled < -32768)
                sat_q7_9 = 16'sh8000;
            else
                sat_q7_9 = scaled[15:0];
        end
    endfunction

   
    localparam IDLE          = 0,
               LOAD_DATA     = 1,
//               WAIT_SLICE    = 2,
               WEIGHT_LOAD   = 3,
               IMAGE_LOAD    = 4,
               STORE         = 5,
               W_DONE        = 6,
               C_DONE        = 7,
               DONE          = 8;
   
    reg [3:0] state, n_state;
 
    reg [1:0]  pad;
   
    always @(*)begin  
        case(slice_cnt)
            2'b00: begin pad <= 0; end
            2'b01: begin pad <= 2; end
            2'b10: begin pad <= 0; end
            2'b11: begin pad <= 2; end
            default: begin pad <= 0; end
        endcase
    end  
   
   
    wire [ADDR_WIDTH - 1:0] row_slicing, col_slicing, total_slicing, weight_slicing;  //convolution slicing
    //to count convolution matrix slicing
    assign row_slicing = (in_row + 2*padding - kernel)/2 + 1;         //640 x 32  ---> 320
    assign col_slicing = (in_column + pad - kernel)/2 + 1;        //640 x 32      ---> 15 (first tile)
    assign total_slicing = row_slicing * col_slicing;               //  4800 one channel
             
    //LOAD DATA    
    reg [3:0] im_valid_count, we_valid_count;  //to gather 8 im2ol row
    //CALCULATE COUNT
    reg [4:0] cal_cnt;          //matrix calculate count
    reg [2:0] accul_cnt;        //to accul 6 kernel
    reg [15:0] in_channel_cnt;
    //ACCULMULATE BUFFER
    reg signed [63:0] buffer [0:99];   //to acculmulate
    reg [5:0] store_cnt;
    reg odd;
    reg [3:0] store_cut;
   
    reg [13:0] out_addr_count0, out_addr_count1, out_addr_count2, out_addr_count3,out_addr_count4;
    reg [13:0] out_addr_count5, out_addr_count6, out_addr_count7, out_addr_count8, out_addr_count9;
    reg [5:0] next_weight;
    reg [10:0] image_cnt, weight_cnt;
   
    wire [MAC_WIDTH*COLUMN_WIDTH*ROW_WIDTH - 1:0] dataout;
    wire [OUT_WIDTH*ROW_WIDTH - 1:0] result;
   
   
    always@(posedge clk or negedge reset)begin
        if(!reset)begin
            state <= IDLE;
        end
        else if(sudo_reset)begin
            state <= IDLE;
        end
        else
            state <= n_state;
    end
               
    always@(*)begin
        n_state = state;
   
        //related slice matrix
        image_read   = 0;
        weight_read  = 0;    
        image_pause  = 1;                                                                                    
        weight_pause = 1;
       
        out_wr_en    = 0;
       
        conv_wait    = 0;
        conv_done    = 0;
       
        case(state)
            IDLE: begin
                if(conv_en)begin
                    n_state = LOAD_DATA;
                end
            end
            LOAD_DATA: begin
                if(kernel == 6 || kernel == 3)begin
                    if(im_valid_count < 10) begin
                        image_pause = 0;
                    end else image_pause = 1;
                    if(we_valid_count < 10) begin
                        weight_pause = 0;
                    end else weight_pause = 1;                    
                    if(im_valid_count == 10 && we_valid_count == 10)begin
                        image_pause = 1;
                        weight_pause = 1;
                        n_state = WEIGHT_LOAD;
                    end
                end
            end

            WEIGHT_LOAD: begin
                weight_read = 1;
                n_state = IMAGE_LOAD;
            end
           
            IMAGE_LOAD: begin
                if(kernel == 6)begin
                    if(cal_cnt == 13)begin      //if 6*6 kernel
                        if(in_channel_cnt == input_channel)begin
                            n_state = STORE;
                        end
                        else if(accul_cnt == 4)begin
                            n_state = LOAD_DATA;    
                        end else begin
                            n_state = WEIGHT_LOAD;
                        end
                        image_read = 0;
                    end
                    else if(cal_cnt < 10)begin
                        image_read = 1;
                    end else begin
                        image_read = 0;
                    end
                end
                else if (kernel == 3)begin
                    if(cal_cnt == 11)begin      //if 6*6 kernel
                        if(in_channel_cnt == input_channel)begin
                            n_state = STORE;
                        end
                        else begin
                            n_state = WEIGHT_LOAD;
                        end
                        image_read = 0;
                    end
                    else if(cal_cnt < 10)begin
                        image_read = 1;
                    end else begin
                        image_read = 0;
                    end
                end
            end
           
            STORE: begin
                out_wr_en = 1;
                if(store_cnt == 30)begin
                    n_state = DONE;
                end
            end
           
            DONE:begin
                if(kernel == 6)begin
                    if(image_cnt == total_slicing/20 - 1 && weight_cnt == output_channel/10 - 1 && odd) begin
                        n_state = C_DONE;
                    end else if(store_cut == 1)begin
                        n_state = W_DONE;
                        conv_wait = 1;
                    end else
                    n_state = LOAD_DATA;
                end else if(kernel == 3)begin
                    if(image_cnt == total_slicing/20 - 1 && weight_cnt == output_channel/10 - 1 && odd) begin
                        n_state = C_DONE;
                    end else
                    n_state = LOAD_DATA;
                end
            end
           
            W_DONE:begin
                if(conv_go)begin
                    n_state = LOAD_DATA;
                end
            end
           
            C_DONE: begin
                conv_done = 1;
                n_state = IDLE;
            end
           
            default: n_state = IDLE;
        endcase
    end
   
    always@(posedge clk or negedge reset)begin
        if(!reset)begin
            im_valid_count    <= 0;
            we_valid_count    <= 0;
           
            cal_cnt           <= 0;
            buffer[ 0] <= 0; buffer[ 1] <= 0; buffer[ 2] <= 0; buffer[ 3] <= 0; buffer[ 4] <= 0; buffer[ 5] <= 0; buffer[ 6] <= 0; buffer[ 7] <= 0;
            buffer[ 8] <= 0; buffer[ 9] <= 0; buffer[10] <= 0; buffer[11] <= 0; buffer[12] <= 0; buffer[13] <= 0; buffer[14] <= 0; buffer[15] <= 0;
            buffer[16] <= 0; buffer[17] <= 0; buffer[18] <= 0; buffer[19] <= 0; buffer[20] <= 0; buffer[21] <= 0; buffer[22] <= 0; buffer[23] <= 0;
            buffer[24] <= 0; buffer[25] <= 0; buffer[26] <= 0; buffer[27] <= 0; buffer[28] <= 0; buffer[29] <= 0; buffer[30] <= 0; buffer[31] <= 0;
            buffer[32] <= 0; buffer[33] <= 0; buffer[34] <= 0; buffer[35] <= 0; buffer[36] <= 0; buffer[37] <= 0; buffer[38] <= 0; buffer[39] <= 0;
            buffer[40] <= 0; buffer[41] <= 0; buffer[42] <= 0; buffer[43] <= 0; buffer[44] <= 0; buffer[45] <= 0; buffer[46] <= 0; buffer[47] <= 0;
            buffer[48] <= 0; buffer[49] <= 0; buffer[50] <= 0; buffer[51] <= 0; buffer[52] <= 0; buffer[53] <= 0; buffer[54] <= 0; buffer[55] <= 0;
            buffer[56] <= 0; buffer[57] <= 0; buffer[58] <= 0; buffer[59] <= 0; buffer[60] <= 0; buffer[61] <= 0; buffer[62] <= 0; buffer[63] <= 0;
            buffer[64] <= 0; buffer[65] <= 0; buffer[66] <= 0; buffer[67] <= 0; buffer[68] <= 0; buffer[69] <= 0; buffer[70] <= 0; buffer[71] <= 0;
            buffer[72] <= 0; buffer[73] <= 0; buffer[74] <= 0; buffer[75] <= 0; buffer[76] <= 0; buffer[77] <= 0; buffer[78] <= 0; buffer[79] <= 0;
            buffer[80] <= 0; buffer[81] <= 0; buffer[82] <= 0; buffer[83] <= 0; buffer[84] <= 0; buffer[85] <= 0; buffer[86] <= 0; buffer[87] <= 0;
            buffer[88] <= 0; buffer[89] <= 0; buffer[90] <= 0; buffer[91] <= 0; buffer[92] <= 0; buffer[93] <= 0; buffer[94] <= 0; buffer[95] <= 0;
            buffer[96] <= 0; buffer[97] <= 0; buffer[98] <= 0; buffer[99] <= 0;
           
            accul_cnt         <= 0;
            in_channel_cnt    <= 0;
            im_valid_del      <= 0;
            we_valid_del      <= 0;
           
            store_cnt         <= 0;
            odd               <= 0;
            out_wr_addr       <= 0;
            out_wr_data       <= 0;
           
            out_addr_count0   <= 0;
            out_addr_count1   <= 0;
            out_addr_count2   <= 0;
            out_addr_count3   <= 0;
            out_addr_count4   <= 0;
            out_addr_count5   <= 0;
            out_addr_count6   <= 0;
            out_addr_count7   <= 0;
            out_addr_count8   <= 0;
            out_addr_count9   <= 0;
           
            next_weight       <= 0;
            image_cnt         <= 0;
            weight_cnt        <= 0;
           
            in_rd_clear       <= 0;
            we_rd_clear       <= 0;
            store_cut         <= 0;
        end
        else if(sudo_reset)begin
            im_valid_count    <= 0;
            we_valid_count    <= 0;
           
            cal_cnt           <= 0;
            buffer[ 0] <= 0; buffer[ 1] <= 0; buffer[ 2] <= 0; buffer[ 3] <= 0; buffer[ 4] <= 0; buffer[ 5] <= 0; buffer[ 6] <= 0; buffer[ 7] <= 0;
            buffer[ 8] <= 0; buffer[ 9] <= 0; buffer[10] <= 0; buffer[11] <= 0; buffer[12] <= 0; buffer[13] <= 0; buffer[14] <= 0; buffer[15] <= 0;
            buffer[16] <= 0; buffer[17] <= 0; buffer[18] <= 0; buffer[19] <= 0; buffer[20] <= 0; buffer[21] <= 0; buffer[22] <= 0; buffer[23] <= 0;
            buffer[24] <= 0; buffer[25] <= 0; buffer[26] <= 0; buffer[27] <= 0; buffer[28] <= 0; buffer[29] <= 0; buffer[30] <= 0; buffer[31] <= 0;
            buffer[32] <= 0; buffer[33] <= 0; buffer[34] <= 0; buffer[35] <= 0; buffer[36] <= 0; buffer[37] <= 0; buffer[38] <= 0; buffer[39] <= 0;
            buffer[40] <= 0; buffer[41] <= 0; buffer[42] <= 0; buffer[43] <= 0; buffer[44] <= 0; buffer[45] <= 0; buffer[46] <= 0; buffer[47] <= 0;
            buffer[48] <= 0; buffer[49] <= 0; buffer[50] <= 0; buffer[51] <= 0; buffer[52] <= 0; buffer[53] <= 0; buffer[54] <= 0; buffer[55] <= 0;
            buffer[56] <= 0; buffer[57] <= 0; buffer[58] <= 0; buffer[59] <= 0; buffer[60] <= 0; buffer[61] <= 0; buffer[62] <= 0; buffer[63] <= 0;
            buffer[64] <= 0; buffer[65] <= 0; buffer[66] <= 0; buffer[67] <= 0; buffer[68] <= 0; buffer[69] <= 0; buffer[70] <= 0; buffer[71] <= 0;
            buffer[72] <= 0; buffer[73] <= 0; buffer[74] <= 0; buffer[75] <= 0; buffer[76] <= 0; buffer[77] <= 0; buffer[78] <= 0; buffer[79] <= 0;
            buffer[80] <= 0; buffer[81] <= 0; buffer[82] <= 0; buffer[83] <= 0; buffer[84] <= 0; buffer[85] <= 0; buffer[86] <= 0; buffer[87] <= 0;
            buffer[88] <= 0; buffer[89] <= 0; buffer[90] <= 0; buffer[91] <= 0; buffer[92] <= 0; buffer[93] <= 0; buffer[94] <= 0; buffer[95] <= 0;
            buffer[96] <= 0; buffer[97] <= 0; buffer[98] <= 0; buffer[99] <= 0;
           
            accul_cnt         <= 0;
            in_channel_cnt    <= 0;
            im_valid_del      <= 0;
            we_valid_del      <= 0;
           
            store_cnt         <= 0;
            odd               <= 0;
            out_wr_addr       <= 0;
            out_wr_data       <= 0;
           
            out_addr_count0   <= 0;
            out_addr_count1   <= 0;
            out_addr_count2   <= 0;
            out_addr_count3   <= 0;
            out_addr_count4   <= 0;
            out_addr_count5   <= 0;
            out_addr_count6   <= 0;
            out_addr_count7   <= 0;
            out_addr_count8   <= 0;
            out_addr_count9   <= 0;
           
            next_weight       <= 0;
            image_cnt         <= 0;
            weight_cnt        <= 0;
           
            in_rd_clear       <= 0;
            we_rd_clear       <= 0;
            store_cut         <= 0;
        end
        else if(state == IDLE)begin
            im_valid_count    <= 0;
            we_valid_count    <= 0;
           
            cal_cnt           <= 0;
            buffer[ 0] <= 0; buffer[ 1] <= 0; buffer[ 2] <= 0; buffer[ 3] <= 0; buffer[ 4] <= 0; buffer[ 5] <= 0; buffer[ 6] <= 0; buffer[ 7] <= 0;
            buffer[ 8] <= 0; buffer[ 9] <= 0; buffer[10] <= 0; buffer[11] <= 0; buffer[12] <= 0; buffer[13] <= 0; buffer[14] <= 0; buffer[15] <= 0;
            buffer[16] <= 0; buffer[17] <= 0; buffer[18] <= 0; buffer[19] <= 0; buffer[20] <= 0; buffer[21] <= 0; buffer[22] <= 0; buffer[23] <= 0;
            buffer[24] <= 0; buffer[25] <= 0; buffer[26] <= 0; buffer[27] <= 0; buffer[28] <= 0; buffer[29] <= 0; buffer[30] <= 0; buffer[31] <= 0;
            buffer[32] <= 0; buffer[33] <= 0; buffer[34] <= 0; buffer[35] <= 0; buffer[36] <= 0; buffer[37] <= 0; buffer[38] <= 0; buffer[39] <= 0;
            buffer[40] <= 0; buffer[41] <= 0; buffer[42] <= 0; buffer[43] <= 0; buffer[44] <= 0; buffer[45] <= 0; buffer[46] <= 0; buffer[47] <= 0;
            buffer[48] <= 0; buffer[49] <= 0; buffer[50] <= 0; buffer[51] <= 0; buffer[52] <= 0; buffer[53] <= 0; buffer[54] <= 0; buffer[55] <= 0;
            buffer[56] <= 0; buffer[57] <= 0; buffer[58] <= 0; buffer[59] <= 0; buffer[60] <= 0; buffer[61] <= 0; buffer[62] <= 0; buffer[63] <= 0;
            buffer[64] <= 0; buffer[65] <= 0; buffer[66] <= 0; buffer[67] <= 0; buffer[68] <= 0; buffer[69] <= 0; buffer[70] <= 0; buffer[71] <= 0;
            buffer[72] <= 0; buffer[73] <= 0; buffer[74] <= 0; buffer[75] <= 0; buffer[76] <= 0; buffer[77] <= 0; buffer[78] <= 0; buffer[79] <= 0;
            buffer[80] <= 0; buffer[81] <= 0; buffer[82] <= 0; buffer[83] <= 0; buffer[84] <= 0; buffer[85] <= 0; buffer[86] <= 0; buffer[87] <= 0;
            buffer[88] <= 0; buffer[89] <= 0; buffer[90] <= 0; buffer[91] <= 0; buffer[92] <= 0; buffer[93] <= 0; buffer[94] <= 0; buffer[95] <= 0;
            buffer[96] <= 0; buffer[97] <= 0; buffer[98] <= 0; buffer[99] <= 0;
           
            accul_cnt         <= 0;
            in_channel_cnt    <= 0;
            im_valid_del      <= 0;
            we_valid_del      <= 0;
           
            store_cnt         <= 0;
            odd               <= 0;
            out_wr_addr       <= 0;
            out_wr_data       <= 0;
           
            out_addr_count0   <= 0;
            out_addr_count1   <= 0;
            out_addr_count2   <= 0;
            out_addr_count3   <= 0;
            out_addr_count4   <= 0;
            out_addr_count5   <= 0;
            out_addr_count6   <= 0;
            out_addr_count7   <= 0;
            out_addr_count8   <= 0;
            out_addr_count9   <= 0;
           
            next_weight       <= 0;
            image_cnt         <= 0;
            weight_cnt        <= 0;
           
            in_rd_clear       <= 0;
            we_rd_clear       <= 0;
            store_cut         <= 0;
        end
       
        else if(state == LOAD_DATA)begin
            accul_cnt         <= 0;
            im_valid_del      <= 0;
            we_valid_del      <= 0;
           
            in_rd_clear       <= 0;
            we_rd_clear       <= 0;
           
            if(im2col_valid_in ==1 && im_valid_count < 10)begin
                im_valid_count <= im_valid_count + 1;
            end
            if(im2col_valid_we ==1 && we_valid_count < 10)begin
                we_valid_count <= we_valid_count + 1;  
            end
        end
       
        else if(state == WEIGHT_LOAD)begin
            cal_cnt   <= 0;
            in_rd_clear       <= 0;
            we_rd_clear       <= 0;
        end
       
        else if(state == IMAGE_LOAD)begin
            in_rd_clear       <= 0;
            we_rd_clear       <= 0;
            if(cal_cnt < 3)begin
                cal_cnt <= cal_cnt + 1;
            end
            else if(cal_cnt < 4)begin       // image 0
                buffer[ 0] <= buffer[ 0] + {{28{result[ 35]}}, result[  35:  0]};  buffer[50] <= buffer[50] + {{28{result[215]}}, result[ 215:180]};   // W: 0  W: 5
                buffer[10] <= buffer[10] + {{28{result[ 71]}}, result[  71: 36]};  buffer[60] <= buffer[60] + {{28{result[251]}}, result[ 251:216]};   // W: 1  W: 6
                buffer[20] <= buffer[20] + {{28{result[107]}}, result[ 107: 72]};  buffer[70] <= buffer[70] + {{28{result[287]}}, result[ 287:252]};   // W: 2  W: 7
                buffer[30] <= buffer[30] + {{28{result[143]}}, result[ 143:108]};  buffer[80] <= buffer[80] + {{28{result[323]}}, result[ 323:288]};   // W: 3  W: 8
                buffer[40] <= buffer[40] + {{28{result[179]}}, result[ 179:144]};  buffer[90] <= buffer[90] + {{28{result[359]}}, result[ 359:324]};   // W: 4  W: 9
 
                cal_cnt <= cal_cnt + 1;
            end
            else if(cal_cnt < 5)begin       //image 1
                buffer[ 1] <= buffer[ 1] + {{28{result[ 35]}}, result[  35:  0]};  buffer[51] <= buffer[51] + {{28{result[215]}}, result[ 215:180]};   // W: 0  W: 5
                buffer[11] <= buffer[11] + {{28{result[ 71]}}, result[  71: 36]};  buffer[61] <= buffer[61] + {{28{result[251]}}, result[ 251:216]};   // W: 1  W: 6
                buffer[21] <= buffer[21] + {{28{result[107]}}, result[ 107: 72]};  buffer[71] <= buffer[71] + {{28{result[287]}}, result[ 287:252]};   // W: 2  W: 7
                buffer[31] <= buffer[31] + {{28{result[143]}}, result[ 143:108]};  buffer[81] <= buffer[81] + {{28{result[323]}}, result[ 323:288]};   // W: 3  W: 8
                buffer[41] <= buffer[41] + {{28{result[179]}}, result[ 179:144]};  buffer[91] <= buffer[91] + {{28{result[359]}}, result[ 359:324]};   // W: 4  W: 9
 
                cal_cnt <= cal_cnt + 1;
            end
            else if(cal_cnt < 6)begin       //image 2
                buffer[ 2] <= buffer[ 2] + {{28{result[ 35]}}, result[  35:  0]};  buffer[52] <= buffer[52] + {{28{result[215]}}, result[ 215:180]};   // W: 0  W: 5
                buffer[12] <= buffer[12] + {{28{result[ 71]}}, result[  71: 36]};  buffer[62] <= buffer[62] + {{28{result[251]}}, result[ 251:216]};   // W: 1  W: 6
                buffer[22] <= buffer[22] + {{28{result[107]}}, result[ 107: 72]};  buffer[72] <= buffer[72] + {{28{result[287]}}, result[ 287:252]};   // W: 2  W: 7
                buffer[32] <= buffer[32] + {{28{result[143]}}, result[ 143:108]};  buffer[82] <= buffer[82] + {{28{result[323]}}, result[ 323:288]};   // W: 3  W: 8
                buffer[42] <= buffer[42] + {{28{result[179]}}, result[ 179:144]};  buffer[92] <= buffer[92] + {{28{result[359]}}, result[ 359:324]};   // W: 4  W: 9
 
                cal_cnt <= cal_cnt + 1;
            end
            else if(cal_cnt < 7)begin       //image 3
                buffer[ 3] <= buffer[ 3] + {{28{result[ 35]}}, result[  35:  0]};  buffer[53] <= buffer[53] + {{28{result[215]}}, result[ 215:180]};   // W: 0  W: 5
                buffer[13] <= buffer[13] + {{28{result[ 71]}}, result[  71: 36]};  buffer[63] <= buffer[63] + {{28{result[251]}}, result[ 251:216]};   // W: 1  W: 6
                buffer[23] <= buffer[23] + {{28{result[107]}}, result[ 107: 72]};  buffer[73] <= buffer[73] + {{28{result[287]}}, result[ 287:252]};   // W: 2  W: 7
                buffer[33] <= buffer[33] + {{28{result[143]}}, result[ 143:108]};  buffer[83] <= buffer[83] + {{28{result[323]}}, result[ 323:288]};   // W: 3  W: 8
                buffer[43] <= buffer[43] + {{28{result[179]}}, result[ 179:144]};  buffer[93] <= buffer[93] + {{28{result[359]}}, result[ 359:324]};   // W: 4  W: 9
 
                cal_cnt <= cal_cnt + 1;
            end
            else if(cal_cnt < 8)begin       //image 4
                buffer[ 4] <= buffer[ 4] + {{28{result[ 35]}}, result[  35:  0]};  buffer[54] <= buffer[54] + {{28{result[215]}}, result[ 215:180]};   // W: 0  W: 5
                buffer[14] <= buffer[14] + {{28{result[ 71]}}, result[  71: 36]};  buffer[64] <= buffer[64] + {{28{result[251]}}, result[ 251:216]};   // W: 1  W: 6
                buffer[24] <= buffer[24] + {{28{result[107]}}, result[ 107: 72]};  buffer[74] <= buffer[74] + {{28{result[287]}}, result[ 287:252]};   // W: 2  W: 7
                buffer[34] <= buffer[34] + {{28{result[143]}}, result[ 143:108]};  buffer[84] <= buffer[84] + {{28{result[323]}}, result[ 323:288]};   // W: 3  W: 8
                buffer[44] <= buffer[44] + {{28{result[179]}}, result[ 179:144]};  buffer[94] <= buffer[94] + {{28{result[359]}}, result[ 359:324]};   // W: 4  W: 9
 
                cal_cnt <= cal_cnt + 1;
            end
            else if(cal_cnt < 9)begin       //image 5
                buffer[ 5] <= buffer[ 5] + {{28{result[ 35]}}, result[  35:  0]};  buffer[55] <= buffer[55] + {{28{result[215]}}, result[ 215:180]};   // W: 0  W: 5
                buffer[15] <= buffer[15] + {{28{result[ 71]}}, result[  71: 36]};  buffer[65] <= buffer[65] + {{28{result[251]}}, result[ 251:216]};   // W: 1  W: 6
                buffer[25] <= buffer[25] + {{28{result[107]}}, result[ 107: 72]};  buffer[75] <= buffer[75] + {{28{result[287]}}, result[ 287:252]};   // W: 2  W: 7
                buffer[35] <= buffer[35] + {{28{result[143]}}, result[ 143:108]};  buffer[85] <= buffer[85] + {{28{result[323]}}, result[ 323:288]};   // W: 3  W: 8
                buffer[45] <= buffer[45] + {{28{result[179]}}, result[ 179:144]};  buffer[95] <= buffer[95] + {{28{result[359]}}, result[ 359:324]};   // W: 4  W: 9
 
                cal_cnt <= cal_cnt + 1;
            end
            else if(cal_cnt < 10)begin       //image 6
                buffer[ 6] <= buffer[ 6] + {{28{result[ 35]}}, result[  35:  0]};  buffer[56] <= buffer[56] + {{28{result[215]}}, result[ 215:180]};   // W: 0  W: 5
                buffer[16] <= buffer[16] + {{28{result[ 71]}}, result[  71: 36]};  buffer[66] <= buffer[66] + {{28{result[251]}}, result[ 251:216]};   // W: 1  W: 6
                buffer[26] <= buffer[26] + {{28{result[107]}}, result[ 107: 72]};  buffer[76] <= buffer[76] + {{28{result[287]}}, result[ 287:252]};   // W: 2  W: 7
                buffer[36] <= buffer[36] + {{28{result[143]}}, result[ 143:108]};  buffer[86] <= buffer[86] + {{28{result[323]}}, result[ 323:288]};   // W: 3  W: 8
                buffer[46] <= buffer[46] + {{28{result[179]}}, result[ 179:144]};  buffer[96] <= buffer[96] + {{28{result[359]}}, result[ 359:324]};   // W: 4  W: 9
 
                cal_cnt <= cal_cnt + 1;
            end
            else if(cal_cnt < 11)begin       //image 7
                buffer[ 7] <= buffer[ 7] + {{28{result[ 35]}}, result[  35:  0]};  buffer[57] <= buffer[57] + {{28{result[215]}}, result[ 215:180]};   // W: 0  W: 5
                buffer[17] <= buffer[17] + {{28{result[ 71]}}, result[  71: 36]};  buffer[67] <= buffer[67] + {{28{result[251]}}, result[ 251:216]};   // W: 1  W: 6
                buffer[27] <= buffer[27] + {{28{result[107]}}, result[ 107: 72]};  buffer[77] <= buffer[77] + {{28{result[287]}}, result[ 287:252]};   // W: 2  W: 7
                buffer[37] <= buffer[37] + {{28{result[143]}}, result[ 143:108]};  buffer[87] <= buffer[87] + {{28{result[323]}}, result[ 323:288]};   // W: 3  W: 8
                buffer[47] <= buffer[47] + {{28{result[179]}}, result[ 179:144]};  buffer[97] <= buffer[97] + {{28{result[359]}}, result[ 359:324]};   // W: 4  W: 9
 
                cal_cnt <= cal_cnt + 1;
            end
            else if(cal_cnt < 12)begin       //image 8
                buffer[ 8] <= buffer[ 8] + {{28{result[ 35]}}, result[  35:  0]};  buffer[58] <= buffer[58] + {{28{result[215]}}, result[ 215:180]};   // W: 0  W: 5
                buffer[18] <= buffer[18] + {{28{result[ 71]}}, result[  71: 36]};  buffer[68] <= buffer[68] + {{28{result[251]}}, result[ 251:216]};   // W: 1  W: 6
                buffer[28] <= buffer[28] + {{28{result[107]}}, result[ 107: 72]};  buffer[78] <= buffer[78] + {{28{result[287]}}, result[ 287:252]};   // W: 2  W: 7
                buffer[38] <= buffer[38] + {{28{result[143]}}, result[ 143:108]};  buffer[88] <= buffer[88] + {{28{result[323]}}, result[ 323:288]};   // W: 3  W: 8
                buffer[48] <= buffer[48] + {{28{result[179]}}, result[ 179:144]};  buffer[98] <= buffer[98] + {{28{result[359]}}, result[ 359:324]};   // W: 4  W: 9
 
                cal_cnt <= cal_cnt + 1;
            end
            else if(cal_cnt < 13)begin       //image 9
                buffer[ 9] <= buffer[ 9] + {{28{result[ 35]}}, result[  35:  0]};  buffer[59] <= buffer[59] + {{28{result[215]}}, result[ 215:180]};   // W: 0  W: 5
                buffer[19] <= buffer[19] + {{28{result[ 71]}}, result[  71: 36]};  buffer[69] <= buffer[69] + {{28{result[251]}}, result[ 251:216]};   // W: 1  W: 6
                buffer[29] <= buffer[29] + {{28{result[107]}}, result[ 107: 72]};  buffer[79] <= buffer[79] + {{28{result[287]}}, result[ 287:252]};   // W: 2  W: 7
                buffer[39] <= buffer[39] + {{28{result[143]}}, result[ 143:108]};  buffer[89] <= buffer[89] + {{28{result[323]}}, result[ 323:288]};   // W: 3  W: 8
                buffer[49] <= buffer[49] + {{28{result[179]}}, result[ 179:144]};  buffer[99] <= buffer[99] + {{28{result[359]}}, result[ 359:324]};   // W: 4  W: 9
 
                cal_cnt <= cal_cnt + 1;
               
                if(kernel == 6)begin
                    cal_cnt     <= cal_cnt + 1;
                    accul_cnt   <= accul_cnt + 1;
                    if(accul_cnt == 3)begin
                        in_channel_cnt  <= in_channel_cnt + 1;
                        accul_cnt       <= accul_cnt + 1;
                        im_valid_del    <= 1;
                        we_valid_del    <= 1;
                        im_valid_count  <= 0;
                        we_valid_count  <= 0;
                    end
                end else if(kernel == 3)begin
                    cal_cnt         <= cal_cnt + 1;
                    in_channel_cnt  <= in_channel_cnt + 1;
                    im_valid_del    <= 1;
                    we_valid_del    <= 1;
                end
            end
        end
       
        else if(state == STORE)begin
            if(odd == 0)begin
                //weight 0 -- 4 feaure map
                if(store_cnt < 1)begin
                    out_wr_addr <= total_slicing*0 + total_slicing*next_weight*10/4 + 5*out_addr_count0;
                    out_wr_data <= {sat_q7_9(buffer[3]),sat_q7_9(buffer[2]),sat_q7_9(buffer[1]),sat_q7_9(buffer[0])};  
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 2)begin
                    out_wr_addr <= total_slicing*0 + total_slicing*next_weight*10/4 + 5*out_addr_count0 + 1;
                    out_wr_data <= {sat_q7_9(buffer[7]),sat_q7_9(buffer[6]),sat_q7_9(buffer[5]),sat_q7_9(buffer[4])};  
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 3)begin
                    out_wr_addr <= total_slicing*0 + total_slicing*next_weight*10/4 + 5*out_addr_count0 + 2;
                    out_wr_data[31:0] <= {sat_q7_9(buffer[9]),sat_q7_9(buffer[8])};  
                    store_cnt <= store_cnt + 1;
                end
                //weight 1 -- 4 feaure map
                else if(store_cnt < 4)begin
                    out_wr_addr <= total_slicing*1/4 + total_slicing*next_weight*10/4 + 5*out_addr_count1;
                    out_wr_data <= {sat_q7_9(buffer[13]),sat_q7_9(buffer[12]),sat_q7_9(buffer[11]),sat_q7_9(buffer[10])};
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 5)begin
                    out_wr_addr <= total_slicing*1/4 + total_slicing*next_weight*10/4 + 5*out_addr_count1 + 1;
                    out_wr_data <= {sat_q7_9(buffer[17]),sat_q7_9(buffer[16]),sat_q7_9(buffer[15]),sat_q7_9(buffer[14])};
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 6)begin
                    out_wr_addr <= total_slicing*1/4 + total_slicing*next_weight*10/4 + 5*out_addr_count1 + 2;
                    out_wr_data[31:0] <= {sat_q7_9(buffer[19]),sat_q7_9(buffer[18])};
                    store_cnt <= store_cnt + 1;
                end
                //weight 2 -- 4 feaure map
                else if(store_cnt < 7)begin
                    out_wr_addr <= total_slicing*2/4 + total_slicing*next_weight*10/4 + 5*out_addr_count2;
                    out_wr_data <= {sat_q7_9(buffer[23]),sat_q7_9(buffer[22]),sat_q7_9(buffer[21]),sat_q7_9(buffer[20])};
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 8)begin
                    out_wr_addr <= total_slicing*2/4 + total_slicing*next_weight*10/4 + 5*out_addr_count2 + 1;
                    out_wr_data <= {sat_q7_9(buffer[27]),sat_q7_9(buffer[26]),sat_q7_9(buffer[25]),sat_q7_9(buffer[24])};
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 9)begin
                    out_wr_addr <= total_slicing*2/4 + total_slicing*next_weight*10/4 + 5*out_addr_count2 + 2;
                    out_wr_data[31:0] <= {sat_q7_9(buffer[29]),sat_q7_9(buffer[28])};
                    store_cnt <= store_cnt + 1;
                end
                //weight 3 -- 4 feaure map
                else if(store_cnt < 10)begin
                    out_wr_addr <= total_slicing*3/4 + total_slicing*next_weight*10/4 + 5*out_addr_count3;
                    out_wr_data <= {sat_q7_9(buffer[33]),sat_q7_9(buffer[32]),sat_q7_9(buffer[31]),sat_q7_9(buffer[30])};
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 11)begin
                    out_wr_addr <= total_slicing*3/4 + total_slicing*next_weight*10/4 + 5*out_addr_count3 + 1;
                    out_wr_data <= {sat_q7_9(buffer[37]),sat_q7_9(buffer[36]),sat_q7_9(buffer[35]),sat_q7_9(buffer[34])};
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 12)begin
                    out_wr_addr <= total_slicing*3/4 + total_slicing*next_weight*10/4 + 5*out_addr_count3 + 2;
                    out_wr_data[31:0] <= {sat_q7_9(buffer[39]),sat_q7_9(buffer[38])};
                    store_cnt <= store_cnt + 1;
                end
                //weight 4 -- 4 feaure map
                else if(store_cnt < 13)begin
                    out_wr_addr <= total_slicing*4/4 + total_slicing*next_weight*10/4 + 5*out_addr_count4;
                    out_wr_data <= {sat_q7_9(buffer[43]),sat_q7_9(buffer[42]),sat_q7_9(buffer[41]),sat_q7_9(buffer[40])};
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 14)begin
                    out_wr_addr <= total_slicing*4/4 + total_slicing*next_weight*10/4 + 5*out_addr_count4 + 1;
                    out_wr_data <= {sat_q7_9(buffer[47]),sat_q7_9(buffer[46]),sat_q7_9(buffer[45]),sat_q7_9(buffer[44])};
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 15)begin
                    out_wr_addr <= total_slicing*4/4 + total_slicing*next_weight*10/4 + 5*out_addr_count4 + 2;
                    out_wr_data[31:0] <= {sat_q7_9(buffer[49]),sat_q7_9(buffer[48])};
                    store_cnt <= store_cnt + 1;
                end
                //weight 5 -- 4 feaure map
                else if(store_cnt < 16)begin
                    out_wr_addr <= total_slicing*5/4 + total_slicing*next_weight*10/4 + 5*out_addr_count5;
                    out_wr_data <= {sat_q7_9(buffer[53]),sat_q7_9(buffer[52]),sat_q7_9(buffer[51]),sat_q7_9(buffer[50])};
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 17)begin
                    out_wr_addr <= total_slicing*5/4 + total_slicing*next_weight*10/4 + 5*out_addr_count5 + 1;
                    out_wr_data <= {sat_q7_9(buffer[57]), sat_q7_9(buffer[56]),sat_q7_9(buffer[55]),sat_q7_9(buffer[54])};
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 18)begin
                    out_wr_addr <= total_slicing*5/4 + total_slicing*next_weight*10/4 + 5*out_addr_count5 + 2;
                    out_wr_data[31:0] <= {sat_q7_9(buffer[59]),sat_q7_9(buffer[58])};
                    store_cnt <= store_cnt + 1;
                end
                //weight 6 -- 4 feaure map
                else if(store_cnt < 19)begin
                    out_wr_addr <= total_slicing*6/4 + total_slicing*next_weight*10/4 + 5*out_addr_count6;
                    out_wr_data <= {sat_q7_9(buffer[63]),sat_q7_9(buffer[62]),sat_q7_9(buffer[61]),sat_q7_9(buffer[60])};
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 20)begin
                    out_wr_addr <= total_slicing*6/4 + total_slicing*next_weight*10/4 + 5*out_addr_count6 + 1;
                    out_wr_data <= {sat_q7_9(buffer[67]),sat_q7_9(buffer[66]),sat_q7_9(buffer[65]),sat_q7_9(buffer[64])};
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 21)begin
                    out_wr_addr <= total_slicing*6/4 + total_slicing*next_weight*10/4 + 5*out_addr_count6 + 2;
                    out_wr_data[31:0] <= {sat_q7_9(buffer[69]),sat_q7_9(buffer[68])};
                    store_cnt <= store_cnt + 1;
                end
                //weight 7 -- 4 feaure map
                else if(store_cnt < 22)begin
                    out_wr_addr <= total_slicing*7/4 + total_slicing*next_weight*10/4 + 5*out_addr_count7;
                    out_wr_data <= {sat_q7_9(buffer[73]),sat_q7_9(buffer[72]),sat_q7_9(buffer[71]),sat_q7_9(buffer[70])};
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 23)begin
                    out_wr_addr <= total_slicing*7/4 + total_slicing*next_weight*10/4 + 5*out_addr_count7 + 1;
                    out_wr_data <= {sat_q7_9(buffer[77]),sat_q7_9(buffer[76]),sat_q7_9(buffer[75]),sat_q7_9(buffer[74])};
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 24)begin
                    out_wr_addr <= total_slicing*7/4 + total_slicing*next_weight*10/4 + 5*out_addr_count7 + 2;
                    out_wr_data[31:0] <= {sat_q7_9(buffer[79]),sat_q7_9(buffer[78])};
                    store_cnt <= store_cnt + 1;
                end
                //weight 8 -- 4 feaure map
                else if(store_cnt < 25)begin
                    out_wr_addr <= total_slicing*8/4 + total_slicing*next_weight*10/4 + 5*out_addr_count8;
                    out_wr_data <= {sat_q7_9(buffer[83]),sat_q7_9(buffer[82]),sat_q7_9(buffer[81]),sat_q7_9(buffer[80])};
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 26)begin
                    out_wr_addr <= total_slicing*8/4 + total_slicing*next_weight*10/4 + 5*out_addr_count8 + 1;
                    out_wr_data <= {sat_q7_9(buffer[87]),sat_q7_9(buffer[86]),sat_q7_9(buffer[85]),sat_q7_9(buffer[84])};
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 27)begin
                    out_wr_addr <= total_slicing*8/4 + total_slicing*next_weight*10/4 + 5*out_addr_count8 + 2;
                    out_wr_data[31:0] <= {sat_q7_9(buffer[89]),sat_q7_9(buffer[88])};
                    store_cnt <= store_cnt + 1;
                end
                //weight 9 -- 4 feaure map
                else if(store_cnt < 28)begin
                    out_wr_addr <= total_slicing*9/4 + total_slicing*next_weight*10/4 + 5*out_addr_count9;
                    out_wr_data <= {sat_q7_9(buffer[93]),sat_q7_9(buffer[92]),sat_q7_9(buffer[91]),sat_q7_9(buffer[90])};
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 29)begin
                    out_wr_addr <= total_slicing*9/4 + total_slicing*next_weight*10/4 + 5*out_addr_count9 + 1;
                    out_wr_data <= {sat_q7_9(buffer[97]),sat_q7_9(buffer[96]),sat_q7_9(buffer[95]),sat_q7_9(buffer[94])};
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 30)begin
                    out_wr_addr <= total_slicing*9/4 + total_slicing*next_weight*10/4 + 5*out_addr_count9 + 2;
                    out_wr_data[31:0] <= {sat_q7_9(buffer[99]),sat_q7_9(buffer[98])};
                    store_cnt <= store_cnt + 1;
//                    odd       <= 1;
                end
            end
            else if(odd==1)begin
                //weight 0 -- 4 feaure map
                if(store_cnt < 1)begin
                    out_wr_addr <= total_slicing*0/4 + total_slicing*next_weight*10/4 + 5*out_addr_count0 + 2;
                    out_wr_data[63:32] <= {sat_q7_9(buffer[1]),sat_q7_9(buffer[0])};  
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 2)begin
                    out_wr_addr <= total_slicing*0/4 + total_slicing*next_weight*10/4 + 5*out_addr_count0 + 3;
                    out_wr_data <= {sat_q7_9(buffer[5]),sat_q7_9(buffer[4]),sat_q7_9(buffer[3]),sat_q7_9(buffer[2])};  
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 3)begin
                    out_wr_addr <= total_slicing*0/4 + total_slicing*next_weight*10/4 + 5*out_addr_count0 + 4;
                    out_wr_data <= {sat_q7_9(buffer[9]),sat_q7_9(buffer[8]),sat_q7_9(buffer[7]),sat_q7_9(buffer[6])};
                    store_cnt <= store_cnt + 1;
                end
                //weight 1 -- 4 feaure map
                else if(store_cnt < 4)begin
                    out_wr_addr <= total_slicing*1/4 + total_slicing*next_weight*10/4 + 5*out_addr_count1 + 2;
                    out_wr_data[63:32] <= {sat_q7_9(buffer[11]),sat_q7_9(buffer[10])};  
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 5)begin
                    out_wr_addr <= total_slicing*1/4 + total_slicing*next_weight*10/4 + 5*out_addr_count1 + 3;
                    out_wr_data <= {sat_q7_9(buffer[15]),sat_q7_9(buffer[14]),sat_q7_9(buffer[13]),sat_q7_9(buffer[12])};  
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 6)begin
                    out_wr_addr <= total_slicing*1/4 + total_slicing*next_weight*10/4 + 5*out_addr_count1 + 4;
                    out_wr_data <= {sat_q7_9(buffer[19]),sat_q7_9(buffer[18]),sat_q7_9(buffer[17]),sat_q7_9(buffer[16])};
                    store_cnt <= store_cnt + 1;
                end
                //weight 2 -- 4 feaure map
                else if(store_cnt < 7)begin
                    out_wr_addr <= total_slicing*2/4 + total_slicing*next_weight*10/4 + 5*out_addr_count2 + 2;
                    out_wr_data[63:32] <= {sat_q7_9(buffer[21]),sat_q7_9(buffer[20])};  
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 8)begin
                    out_wr_addr <= total_slicing*2/4 + total_slicing*next_weight*10/4 + 5*out_addr_count2 + 3;
                    out_wr_data <= {sat_q7_9(buffer[25]),sat_q7_9(buffer[24]),sat_q7_9(buffer[23]),sat_q7_9(buffer[22])};  
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 9)begin
                    out_wr_addr <= total_slicing*2/4 + total_slicing*next_weight*10/4 + 5*out_addr_count2 + 4;
                    out_wr_data <= {sat_q7_9(buffer[29]),sat_q7_9(buffer[28]),sat_q7_9(buffer[27]),sat_q7_9(buffer[26])};
                    store_cnt <= store_cnt + 1;
                end
                //weight 3 -- 4 feaure map
                else if(store_cnt < 10)begin
                    out_wr_addr <= total_slicing*3/4 + total_slicing*next_weight*10/4 + 5*out_addr_count3 + 2;
                    out_wr_data[63:32] <= {sat_q7_9(buffer[31]),sat_q7_9(buffer[30])};  
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 11)begin
                    out_wr_addr <= total_slicing*3/4 + total_slicing*next_weight*10/4 + 5*out_addr_count3 + 3;
                    out_wr_data <= {sat_q7_9(buffer[35]),sat_q7_9(buffer[34]),sat_q7_9(buffer[33]),sat_q7_9(buffer[32])};  
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 12)begin
                    out_wr_addr <= total_slicing*3/4 + total_slicing*next_weight*10/4 + 5*out_addr_count3 + 4;
                    out_wr_data <= {sat_q7_9(buffer[39]),sat_q7_9(buffer[38]),sat_q7_9(buffer[37]),sat_q7_9(buffer[36])};
                    store_cnt <= store_cnt + 1;
                end
                //weight 4 -- 4 feaure map
                else if(store_cnt < 13)begin
                    out_wr_addr <= total_slicing*4/4 + total_slicing*next_weight*10/4 + 5*out_addr_count4 + 2;
                    out_wr_data[63:32] <= {sat_q7_9(buffer[41]),sat_q7_9(buffer[40])};  
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 14)begin
                    out_wr_addr <= total_slicing*4/4 + total_slicing*next_weight*10/4 + 5*out_addr_count4 + 3;
                    out_wr_data <= {sat_q7_9(buffer[45]),sat_q7_9(buffer[44]),sat_q7_9(buffer[43]),sat_q7_9(buffer[42])};  
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 15)begin
                    out_wr_addr <= total_slicing*4/4 + total_slicing*next_weight*10/4 + 5*out_addr_count4 + 4;
                    out_wr_data <= {sat_q7_9(buffer[49]),sat_q7_9(buffer[48]),sat_q7_9(buffer[47]),sat_q7_9(buffer[46])};
                    store_cnt <= store_cnt + 1;
                end
                //weight 5 -- 4 feaure map
                else if(store_cnt < 16)begin
                    out_wr_addr <= total_slicing*5/4 + total_slicing*next_weight*10/4 + 5*out_addr_count5 + 2;
                    out_wr_data[63:32] <= {sat_q7_9(buffer[51]),sat_q7_9(buffer[50])};  
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 17)begin
                    out_wr_addr <= total_slicing*5/4 + total_slicing*next_weight*10/4 + 5*out_addr_count5 + 3;
                    out_wr_data <= {sat_q7_9(buffer[55]),sat_q7_9(buffer[54]),sat_q7_9(buffer[53]),sat_q7_9(buffer[52])};  
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 18)begin
                    out_wr_addr <= total_slicing*5/4 + total_slicing*next_weight*10/4 + 5*out_addr_count5 + 4;
                    out_wr_data <= {sat_q7_9(buffer[59]),sat_q7_9(buffer[58]),sat_q7_9(buffer[57]),sat_q7_9(buffer[56])};
                    store_cnt <= store_cnt + 1;
                end
                //weight 6 -- 4 feaure map
                else if(store_cnt < 19)begin
                    out_wr_addr <= total_slicing*6/4 + total_slicing*next_weight*10/4 + 5*out_addr_count6 + 2;
                    out_wr_data[63:32] <= {sat_q7_9(buffer[61]),sat_q7_9(buffer[60])};  
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 20)begin
                    out_wr_addr <= total_slicing*6/4 + total_slicing*next_weight*10/4 + 5*out_addr_count6 + 3;
                    out_wr_data <= {sat_q7_9(buffer[65]),sat_q7_9(buffer[64]),sat_q7_9(buffer[63]),sat_q7_9(buffer[62])};  
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 21)begin
                    out_wr_addr <= total_slicing*6/4 + total_slicing*next_weight*10/4 + 5*out_addr_count6 + 4;
                    out_wr_data <= {sat_q7_9(buffer[69]),sat_q7_9(buffer[68]),sat_q7_9(buffer[67]),sat_q7_9(buffer[66])};
                    store_cnt <= store_cnt + 1;
                end
                //weight 7 -- 4 feaure map
                else if(store_cnt < 22)begin
                    out_wr_addr <= total_slicing*7/4 + total_slicing*next_weight*10/4 + 5*out_addr_count7 + 2;
                    out_wr_data[63:32] <= {sat_q7_9(buffer[71]),sat_q7_9(buffer[70])};  
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 23)begin
                    out_wr_addr <= total_slicing*7/4 + total_slicing*next_weight*10/4 + 5*out_addr_count7 + 3;
                    out_wr_data <= {sat_q7_9(buffer[75]),sat_q7_9(buffer[74]),sat_q7_9(buffer[73]),sat_q7_9(buffer[72])};  
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 24)begin
                    out_wr_addr <= total_slicing*7/4 + total_slicing*next_weight*10/4 + 5*out_addr_count7 + 4;
                    out_wr_data <= {sat_q7_9(buffer[79]),sat_q7_9(buffer[78]),sat_q7_9(buffer[77]),sat_q7_9(buffer[76])};
                    store_cnt <= store_cnt + 1;
                end
                //weight 8 -- 4 feaure map
                else if(store_cnt < 25)begin
                    out_wr_addr <= total_slicing*8/4 + total_slicing*next_weight*10/4 + 5*out_addr_count8 + 2;
                    out_wr_data[63:32] <= {sat_q7_9(buffer[81]),sat_q7_9(buffer[80])};  
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 26)begin
                    out_wr_addr <= total_slicing*8/4 + total_slicing*next_weight*10/4 + 5*out_addr_count8 + 3;
                    out_wr_data <= {sat_q7_9(buffer[85]),sat_q7_9(buffer[84]),sat_q7_9(buffer[83]),sat_q7_9(buffer[82])};  
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 27)begin
                    out_wr_addr <= total_slicing*8/4 + total_slicing*next_weight*10/4 + 5*out_addr_count8 + 4;
                    out_wr_data <= {sat_q7_9(buffer[89]),sat_q7_9(buffer[88]),sat_q7_9(buffer[87]),sat_q7_9(buffer[86])};
                    store_cnt <= store_cnt + 1;
                end
                //weight 9 -- 4 feaure map
                else if(store_cnt < 28)begin
                    out_wr_addr <= total_slicing*9/4 + total_slicing*next_weight*10/4 + 5*out_addr_count9 + 2;
                    out_wr_data[63:32] <= {sat_q7_9(buffer[91]),sat_q7_9(buffer[90])};  
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 29)begin
                    out_wr_addr <= total_slicing*9/4 + total_slicing*next_weight*10/4 + 5*out_addr_count9 + 3;
                    out_wr_data <= {sat_q7_9(buffer[95]),sat_q7_9(buffer[94]),sat_q7_9(buffer[93]),sat_q7_9(buffer[92])};  
                    store_cnt <= store_cnt + 1;
                end
                else if(store_cnt < 30)begin
                    out_wr_addr <= total_slicing*9/4 + total_slicing*next_weight*10/4 + 5*out_addr_count9 + 4;
                    out_wr_data <= {sat_q7_9(buffer[99]),sat_q7_9(buffer[98]),sat_q7_9(buffer[97]),sat_q7_9(buffer[96])};
                    store_cnt <= store_cnt + 1;
//                    odd       <= 0;
                end
                else if(store_cnt == 30)begin
                    out_addr_count0 <= out_addr_count0 + 1;
                    out_addr_count1 <= out_addr_count1 + 1;
                    out_addr_count2 <= out_addr_count2 + 1;
                    out_addr_count3 <= out_addr_count3 + 1;
                    out_addr_count4 <= out_addr_count4 + 1;
                    out_addr_count5 <= out_addr_count5 + 1;
                    out_addr_count6 <= out_addr_count6 + 1;
                    out_addr_count7 <= out_addr_count7 + 1;
                    out_addr_count8 <= out_addr_count8 + 1;
                    out_addr_count9 <= out_addr_count9 + 1;
                end
            end
        end
        else if(state == DONE)begin
            buffer[ 0] <= 0; buffer[ 1] <= 0; buffer[ 2] <= 0; buffer[ 3] <= 0; buffer[ 4] <= 0; buffer[ 5] <= 0; buffer[ 6] <= 0; buffer[ 7] <= 0;
            buffer[ 8] <= 0; buffer[ 9] <= 0; buffer[10] <= 0; buffer[11] <= 0; buffer[12] <= 0; buffer[13] <= 0; buffer[14] <= 0; buffer[15] <= 0;
            buffer[16] <= 0; buffer[17] <= 0; buffer[18] <= 0; buffer[19] <= 0; buffer[20] <= 0; buffer[21] <= 0; buffer[22] <= 0; buffer[23] <= 0;
            buffer[24] <= 0; buffer[25] <= 0; buffer[26] <= 0; buffer[27] <= 0; buffer[28] <= 0; buffer[29] <= 0; buffer[30] <= 0; buffer[31] <= 0;
            buffer[32] <= 0; buffer[33] <= 0; buffer[34] <= 0; buffer[35] <= 0; buffer[36] <= 0; buffer[37] <= 0; buffer[38] <= 0; buffer[39] <= 0;
            buffer[40] <= 0; buffer[41] <= 0; buffer[42] <= 0; buffer[43] <= 0; buffer[44] <= 0; buffer[45] <= 0; buffer[46] <= 0; buffer[47] <= 0;
            buffer[48] <= 0; buffer[49] <= 0; buffer[50] <= 0; buffer[51] <= 0; buffer[52] <= 0; buffer[53] <= 0; buffer[54] <= 0; buffer[55] <= 0;
            buffer[56] <= 0; buffer[57] <= 0; buffer[58] <= 0; buffer[59] <= 0; buffer[60] <= 0; buffer[61] <= 0; buffer[62] <= 0; buffer[63] <= 0;
            buffer[64] <= 0; buffer[65] <= 0; buffer[66] <= 0; buffer[67] <= 0; buffer[68] <= 0; buffer[69] <= 0; buffer[70] <= 0; buffer[71] <= 0;
            buffer[72] <= 0; buffer[73] <= 0; buffer[74] <= 0; buffer[75] <= 0; buffer[76] <= 0; buffer[77] <= 0; buffer[78] <= 0; buffer[79] <= 0;
            buffer[80] <= 0; buffer[81] <= 0; buffer[82] <= 0; buffer[83] <= 0; buffer[84] <= 0; buffer[85] <= 0; buffer[86] <= 0; buffer[87] <= 0;
            buffer[88] <= 0; buffer[89] <= 0; buffer[90] <= 0; buffer[91] <= 0; buffer[92] <= 0; buffer[93] <= 0; buffer[94] <= 0; buffer[95] <= 0;
            buffer[96] <= 0; buffer[97] <= 0; buffer[98] <= 0; buffer[99] <= 0;
       
            store_cnt   <= 0;
            if(image_cnt < total_slicing/20 - 1 && !odd)begin    // kenel_idx < KENEL_MAX_NUMBER - 1
                im_valid_count <= 0;
                im_valid_del <= 1;
                we_valid_count <= 0;
                we_valid_del <= 1;
                in_channel_cnt <= 0;
                odd         <= 1;
            end
            else if(image_cnt < total_slicing/20 && !odd)begin    // kenel_idx < KENEL_MAX_NUMBER - 1
                im_valid_count <= 0;
                im_valid_del <= 1;
                we_valid_count <= 0;
                we_valid_del <= 1;
                in_channel_cnt <= 0;
                odd         <= 1;
                store_cut   <= store_cut + 1;
            end
            else if(image_cnt < total_slicing/20 - 1 && odd)begin    // kenel_idx < KENEL_MAX_NUMBER - 1
                im_valid_count <= 0;
                image_cnt <= image_cnt + 1;
                im_valid_del <= 1;
                we_valid_count <= 0;
                we_valid_del <= 1;
                in_channel_cnt <= 0;
                odd         <= 0;
            end
            else if(weight_cnt < output_channel/10)begin    // input_idx < INPUT_MAX_SLICE - 1
                out_addr_count0 <= 0;
                out_addr_count1 <= 0;
                out_addr_count2 <= 0;
                out_addr_count3 <= 0;
                out_addr_count4 <= 0;
                out_addr_count5 <= 0;
                out_addr_count6 <= 0;
                out_addr_count7 <= 0;
                out_addr_count8 <= 0;
                out_addr_count9 <= 0;
                odd             <= 0;
                in_channel_cnt  <= 0;
                we_valid_count <= 0;
                weight_cnt <= weight_cnt + 1;
                we_valid_del <= 1;
                im_valid_count <= 0; // add
                image_cnt <= 0;
                im_valid_del <= 1;
                in_rd_clear <= 1;
                next_weight <= next_weight + 1;
            end
        end
       
        else if(state == W_DONE)begin
            store_cut <= 0;
                out_addr_count0 <= 0;
                out_addr_count1 <= 0;
                out_addr_count2 <= 0;
                out_addr_count3 <= 0;
                out_addr_count4 <= 0;
                out_addr_count5 <= 0;
                out_addr_count6 <= 0;
                out_addr_count7 <= 0;
                out_addr_count8 <= 0;
                out_addr_count9 <= 0;
                odd             <= 0;
                in_channel_cnt  <= 0;
                we_valid_count <= 0;
                we_valid_del <= 1;
                im_valid_count <= 0; // add
                image_cnt <= 0;
                im_valid_del <= 1;
                in_rd_clear <= 1;
        end
       
        else if(state == C_DONE)begin
            im_valid_count    <= 0;
            we_valid_count    <= 0;
           
            cal_cnt  <= 0;
            buffer[ 0] <= 0; buffer[ 1] <= 0; buffer[ 2] <= 0; buffer[ 3] <= 0; buffer[ 4] <= 0; buffer[ 5] <= 0; buffer[ 6] <= 0; buffer[ 7] <= 0;
            buffer[ 8] <= 0; buffer[ 9] <= 0; buffer[10] <= 0; buffer[11] <= 0; buffer[12] <= 0; buffer[13] <= 0; buffer[14] <= 0; buffer[15] <= 0;
            buffer[16] <= 0; buffer[17] <= 0; buffer[18] <= 0; buffer[19] <= 0; buffer[20] <= 0; buffer[21] <= 0; buffer[22] <= 0; buffer[23] <= 0;
            buffer[24] <= 0; buffer[25] <= 0; buffer[26] <= 0; buffer[27] <= 0; buffer[28] <= 0; buffer[29] <= 0; buffer[30] <= 0; buffer[31] <= 0;
            buffer[32] <= 0; buffer[33] <= 0; buffer[34] <= 0; buffer[35] <= 0; buffer[36] <= 0; buffer[37] <= 0; buffer[38] <= 0; buffer[39] <= 0;
            buffer[40] <= 0; buffer[41] <= 0; buffer[42] <= 0; buffer[43] <= 0; buffer[44] <= 0; buffer[45] <= 0; buffer[46] <= 0; buffer[47] <= 0;
            buffer[48] <= 0; buffer[49] <= 0; buffer[50] <= 0; buffer[51] <= 0; buffer[52] <= 0; buffer[53] <= 0; buffer[54] <= 0; buffer[55] <= 0;
            buffer[56] <= 0; buffer[57] <= 0; buffer[58] <= 0; buffer[59] <= 0; buffer[60] <= 0; buffer[61] <= 0; buffer[62] <= 0; buffer[63] <= 0;
            buffer[64] <= 0; buffer[65] <= 0; buffer[66] <= 0; buffer[67] <= 0; buffer[68] <= 0; buffer[69] <= 0; buffer[70] <= 0; buffer[71] <= 0;
            buffer[72] <= 0; buffer[73] <= 0; buffer[74] <= 0; buffer[75] <= 0; buffer[76] <= 0; buffer[77] <= 0; buffer[78] <= 0; buffer[79] <= 0;
            buffer[80] <= 0; buffer[81] <= 0; buffer[82] <= 0; buffer[83] <= 0; buffer[84] <= 0; buffer[85] <= 0; buffer[86] <= 0; buffer[87] <= 0;
            buffer[88] <= 0; buffer[89] <= 0; buffer[90] <= 0; buffer[91] <= 0; buffer[92] <= 0; buffer[93] <= 0; buffer[94] <= 0; buffer[95] <= 0;
            buffer[96] <= 0; buffer[97] <= 0; buffer[98] <= 0; buffer[99] <= 0;
           
            accul_cnt         <= 0;
            in_channel_cnt    <= 0;
            im_valid_del      <= 0;
            we_valid_del      <= 0;
           
            store_cnt         <= 0;
            odd               <= 0;
            out_wr_addr       <= 0;
            out_wr_data       <= 0;
           
            out_addr_count0   <= 0;
            out_addr_count1   <= 0;
            out_addr_count2   <= 0;
            out_addr_count3   <= 0;
            out_addr_count4   <= 0;
            out_addr_count5   <= 0;
            out_addr_count6   <= 0;
            out_addr_count7   <= 0;
            out_addr_count8   <= 0;
            out_addr_count9   <= 0;
           
            next_weight       <= 0;
            image_cnt         <= 0;
            weight_cnt        <= 0;
           
            in_rd_clear       <= 0;
            we_rd_clear       <= 0;
            store_cut         <= 0;
        end
    end
 
    parallel_meissa #(
        .ROW_WIDTH     (ROW_WIDTH),
        .COLUMN_WIDTH  (COLUMN_WIDTH),
        .DATA_WIDTH    (DATA_WIDTH),
        .MAC_WIDTH     (MAC_WIDTH)
    ) parallel_meissa (
        .clk          (clk),
        .reset        (reset),
        .datain       (image_data),
        .weightin     (weight_data),
        .maccout      (dataout)
    );    
   
    adder_tree_array #(
        .ROW_WIDTH     (ROW_WIDTH),
        .COLUMN_WIDTH  (COLUMN_WIDTH),
        .DATA_WIDTH    (DATA_WIDTH),
        .MAC_WIDTH     (MAC_WIDTH),
        .OUT_WIDTH     (OUT_WIDTH)
    ) adder_tree_array (
        .clk          (clk),
        .reset        (reset),
        .maccout      (dataout),
        .result       (result)
    );  
   
   
endmodule
