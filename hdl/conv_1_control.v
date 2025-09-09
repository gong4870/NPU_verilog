`default_nettype none

module conv_1_control #(
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
   
    input  wire                                            conv1_en,
    output reg                                             conv1_done,
   
    //OPCODE DATA
    input wire  [9:0]                                      in_row,     // Է                  
    input wire  [9:0]                                      in_column,  // Է                  
    input wire  [11:0]                                     input_channel,  //weight channel  
    input wire  [11:0]                                     output_channel,  //weight channel  
   
    //INPUT BRAM WRITE  
    output reg                                             in_rd_en,
    output reg  [ADDR_WIDTH:0]                             in_rd_addr,
    input  wire [AXI_HP_BIT-1:0]                           in_rd_data,

    //WEIGHT BRAM WRITE  
    output reg                                             we_rd_en,
    output reg  [ADDR_WIDTH-1:0]                           we_rd_addr,
    input  wire [AXI_HP_BIT-1:0]                           we_rd_data,
   
    //OUTPUT BRAM WRITE          
    output reg                                             out_wr_en,
    output reg [ADDR_WIDTH-1:0]                            out_wr_addr,
    output reg [AXI_HP_BIT-1:0]                            out_wr_data
   
    //to testbench
//    output wire [MAC_WIDTH*COLUMN_WIDTH*ROW_WIDTH - 1:0]   dataout,
//    output wire [OUT_WIDTH*ROW_WIDTH - 1:0]                result
);
   
    localparam IDLE          = 0,
               LOAD_WEIGHT   = 1,
               LOAD_DATA     = 2,
               LAST_ADD      = 8,
               CONVOLUTION   = 3,
               STORE         = 4,
               DELETE        = 7,
               NEXT          = 5,
               DONE          = 6;
   
    reg [3:0] state, n_state;

    reg [63:0] buffer [0:3];
    reg [12:0] channel_cnt, weight_cnt, output_cnt;
    reg [10:0] input_cnt;
    reg [3:0] add_cnt;
    reg [5:0] next_channel;
    reg [14:0] next_weight;
    reg [10:0] out_channel_cnt;
    reg [3:0] wait_cnt;
   
   
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
       
        conv1_done = 0;
        case(state)
            IDLE: begin
                if(conv1_en)begin
                    n_state = LOAD_WEIGHT;
                end
            end
            LOAD_WEIGHT: begin
                n_state = LOAD_DATA;
            end
           
            LOAD_DATA: begin
                n_state = CONVOLUTION;
            end

            CONVOLUTION: begin
                if(channel_cnt == input_channel - 1)begin
                    n_state = STORE;
                end else if(add_cnt == 3)begin
                    n_state = LAST_ADD;
                end else begin
                    n_state = LOAD_DATA;
                end
            end
           
            LAST_ADD:begin
                n_state = LOAD_WEIGHT;
            end
           
            STORE: begin
                if(next_channel==(in_row*in_column/4-1))begin
                    n_state = NEXT;
                end else begin
                    n_state = DELETE;
                end  
            end
           
            DELETE:begin
                n_state = LOAD_WEIGHT;
            end
           
            NEXT:begin
                if(next_weight == (output_channel-1)*input_channel/4)begin
                    n_state = DONE;
                end else begin
                    n_state = LOAD_WEIGHT;
                end
            end
           
            DONE:begin
                conv1_done = 1;
                n_state = IDLE;
            end

           
            default: n_state = IDLE;
        endcase
    end
   
    always@(posedge clk or negedge reset)begin
        if(!reset)begin
            in_rd_en      <= 0;
            in_rd_addr    <= 0;  
            input_cnt     <= 0;
           
            we_rd_en      <= 0;
            we_rd_addr    <= 0;
            weight_cnt    <= 0;
           
           
            buffer[0]     <= 0;
            buffer[1]     <= 0;
            buffer[2]     <= 0;
            buffer[3]     <= 0;              
                         
            channel_cnt   <= 0;
               
            out_wr_en     <= 0;
            out_wr_addr   <= 0;
            out_wr_data   <= 0;
            output_cnt    <= 0;
           
            next_channel  <= 0;
            next_weight   <= 0;
           
        end
       
        else if(sudo_reset)begin
            in_rd_en      <= 0;
            in_rd_addr    <= 0;  
            input_cnt     <= 0;
           
            we_rd_en      <= 0;
            we_rd_addr    <= 0;
            weight_cnt    <= 0;
           
           
            buffer[0]     <= 0;
            buffer[1]     <= 0;
            buffer[2]     <= 0;
            buffer[3]     <= 0;              
                         
            channel_cnt   <= 0;
               
            out_wr_en     <= 0;
            out_wr_addr   <= 0;
            out_wr_data   <= 0;
            output_cnt    <= 0;
           
            next_channel  <= 0;
            next_weight   <= 0;
           
        end
       
        else if(state == IDLE)begin
            in_rd_en      <= 0;
            in_rd_addr    <= 0;  
            input_cnt     <= 0;
           
            we_rd_en      <= 0;
            we_rd_addr    <= 0;
            weight_cnt    <= 0;  
           
            buffer[0]     <= 0;
            buffer[1]     <= 0;
            buffer[2]     <= 0;
            buffer[3]     <= 0;              
                         
            channel_cnt   <= 0;
            add_cnt       <= 0;
               
            out_wr_en     <= 0;
            out_wr_addr   <= 0;
            out_wr_data   <= 0;
            output_cnt    <= 0;
           
            next_channel  <= 0;
            next_weight   <= 0;
           
        end
       
        else if(state == LOAD_WEIGHT)begin
            in_rd_en      <= 0;
            in_rd_addr    <= 0;  
            input_cnt     <= input_cnt;
             
            we_rd_en      <= 1;
            we_rd_addr    <= next_weight + weight_cnt;  
            weight_cnt    <= weight_cnt;    
           
            buffer[0]     <= buffer[0];
            buffer[1]     <= buffer[1];
            buffer[2]     <= buffer[2];
            buffer[3]     <= buffer[3];    
             
            channel_cnt   <= channel_cnt;
            add_cnt       <= 0;

            out_wr_en     <= 0;
            out_wr_addr   <= 0;
            out_wr_data   <= 0;
            output_cnt    <= output_cnt;
       
        end
       
        else if(state == LOAD_DATA)begin
            in_rd_en      <= 1;
            in_rd_addr    <= input_cnt;  
            input_cnt     <= input_cnt;
             
            we_rd_en      <= 1;
            we_rd_addr    <= next_weight + weight_cnt;  
            weight_cnt    <= weight_cnt;    
           
            buffer[0]     <= buffer[0];
            buffer[1]     <= buffer[1];
            buffer[2]     <= buffer[2];
            buffer[3]     <= buffer[3];    
             
            channel_cnt   <= channel_cnt;
            add_cnt       <= add_cnt;

            out_wr_en     <= 0;
            out_wr_addr   <= 0;
            out_wr_data   <= 0;
            output_cnt    <= output_cnt;
        end
       
        else if(state == CONVOLUTION)begin
            in_rd_en      <= 0;
            in_rd_addr    <= 0;  
            input_cnt     <= input_cnt + in_row*in_column/4;
                     
            we_rd_en      <= 0;
            we_rd_addr    <= next_weight + weight_cnt;  

               
            if(add_cnt == 0)begin
                buffer[0] <= $signed(buffer[0]) + $signed(in_rd_data[15:0])  * $signed(we_rd_data[15:0]);     //input img 0
                buffer[1] <= $signed(buffer[1]) + $signed(in_rd_data[31:16]) * $signed(we_rd_data[15:0]);    //input img 1
                buffer[2] <= $signed(buffer[2]) + $signed(in_rd_data[47:32]) * $signed(we_rd_data[15:0]);    //input img 2
                buffer[3] <= $signed(buffer[3]) + $signed(in_rd_data[63:48]) * $signed(we_rd_data[15:0]);    //input img 3
            end
            else if(add_cnt == 1)begin
                buffer[0] <= $signed(buffer[0]) + $signed(in_rd_data[15:0])  * $signed(we_rd_data[31:16]);     //input img 0
                buffer[1] <= $signed(buffer[1]) + $signed(in_rd_data[31:16]) * $signed(we_rd_data[31:16]);    //input img 1
                buffer[2] <= $signed(buffer[2]) + $signed(in_rd_data[47:32]) * $signed(we_rd_data[31:16]);    //input img 2
                buffer[3] <= $signed(buffer[3]) + $signed(in_rd_data[63:48]) * $signed(we_rd_data[31:16]);    //input img 3
            end
            else if(add_cnt == 2)begin
                buffer[0] <= $signed(buffer[0]) + $signed(in_rd_data[15:0])  * $signed(we_rd_data[47:32]);     //input img 0
                buffer[1] <= $signed(buffer[1]) + $signed(in_rd_data[31:16]) * $signed(we_rd_data[47:32]);    //input img 1
                buffer[2] <= $signed(buffer[2]) + $signed(in_rd_data[47:32]) * $signed(we_rd_data[47:32]);    //input img 2
                buffer[3] <= $signed(buffer[3]) + $signed(in_rd_data[63:48]) * $signed(we_rd_data[47:32]);    //input img 3
            end
            else if(add_cnt == 3)begin
                buffer[0] <= $signed(buffer[0]) + $signed(in_rd_data[15:0])  * $signed(we_rd_data[63:48]);     //input img 0
                buffer[1] <= $signed(buffer[1]) + $signed(in_rd_data[31:16]) * $signed(we_rd_data[63:48]);    //input img 1
                buffer[2] <= $signed(buffer[2]) + $signed(in_rd_data[47:32]) * $signed(we_rd_data[63:48]);    //input img 2
                buffer[3] <= $signed(buffer[3]) + $signed(in_rd_data[63:48]) * $signed(we_rd_data[63:48]);    //input img 3
            end
           
            if(add_cnt == 3)begin
                weight_cnt    <= weight_cnt + 1;  
            end
            add_cnt       <= add_cnt +1;
            channel_cnt   <= channel_cnt + 1;

            out_wr_en     <= 0;
            out_wr_addr   <= 0;
            out_wr_data   <= 0;
            output_cnt    <= output_cnt;
        end    
        else if(state == LAST_ADD)begin
                buffer[0] <= $signed(buffer[0]) + $signed(in_rd_data[15:0])  * $signed(we_rd_data[63:63]);     //input img 0
                buffer[1] <= $signed(buffer[1]) + $signed(in_rd_data[31:16]) * $signed(we_rd_data[63:63]);    //input img 1
                buffer[2] <= $signed(buffer[2]) + $signed(in_rd_data[47:32]) * $signed(we_rd_data[63:63]);    //input img 2
                buffer[3] <= $signed(buffer[3]) + $signed(in_rd_data[63:48]) * $signed(we_rd_data[63:63]);    //input img 3
        end
           
        else if(state == STORE)begin
            in_rd_en      <= 0;
            in_rd_addr    <= 0;  
            input_cnt     <= input_cnt%(in_row*in_column/4) + 1;
                     
            we_rd_en      <= 0;
            we_rd_addr    <= next_weight;  
            weight_cnt    <= 0;  
           
           
            channel_cnt   <= 0;

            out_wr_en     <= 1;
            out_wr_addr   <= output_cnt;
            out_wr_data   <= {buffer[3][15:0],buffer[2][15:0],buffer[1][15:0],buffer[0][15:0]};
            output_cnt    <= output_cnt + 1;
           
            next_channel  <= next_channel + 1;
        end  
        else if(state == DELETE)begin
           
            buffer[0]     <= 0;
            buffer[1]     <= 0;
            buffer[2]     <= 0;
            buffer[3]     <= 0;        
        end    
        else if(state == NEXT)begin
                   
            buffer[0]     <= 0;
            buffer[1]     <= 0;
            buffer[2]     <= 0;
            buffer[3]     <= 0;        
            next_channel  <= 0;
            next_weight <= next_weight + input_channel/4;
        end    
        else if(state == DONE)begin
            in_rd_en      <= 0;
            in_rd_addr    <= 0;  
            input_cnt     <= 0;
           
            we_rd_en      <= 0;
            we_rd_addr    <= 0;
            weight_cnt    <= 0;
           
           
            buffer[0]     <= 0;
            buffer[1]     <= 0;
            buffer[2]     <= 0;
            buffer[3]     <= 0;              
                         
            channel_cnt   <= 0;
               
            out_wr_en     <= 0;
            out_wr_addr   <= 0;
            out_wr_data   <= 0;
            output_cnt    <= 0;
           
            next_channel  <= 0;
            next_weight   <= 0;
        end
    end

   
endmodule
