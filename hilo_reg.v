`include "lib/defines.vh"
//处理高字和低字相关寄存器的操作
module hilo_reg(
    input wire clk,
    input wire rst,
    input wire [`StallBus-1:0] stall,

    input wire ex_hi_we, ex_lo_we, //执行阶段写使能信号
    input wire [31:0] ex_hi_in,//执行阶段要写入寄存器的数据
    input wire [31:0] ex_lo_in,

    input wire mem_hi_we, mem_lo_we,
    input wire [31:0] mem_hi_in,
    input wire [31:0] mem_lo_in,
    
    input wire [65:0] hilo_bus,//总线，传递回写到寄存器的数据及使能信号

    output reg [31:0] hi_data,
    output reg [31:0] lo_data
);

    reg [31:0] reg_hi, reg_lo;//定义寄存器

    wire wb_hi_we, wb_lo_we;
    wire [31:0] wb_hi_in, wb_lo_in;
    assign {
        wb_hi_we, 
        wb_lo_we,
        wb_hi_in,
        wb_lo_in
    } = hilo_bus; //输入信号总线拆包

    always @ (posedge clk) begin //时钟信号的上升沿触发
        if (rst) begin
            reg_hi <= 32'b0; //复位信号为高，清零
        end
        else if (wb_hi_we) begin //复位信号为低，且写使能为高，回写阶段允许向hi寄存器写数据
            reg_hi <= wb_hi_in;
        end
    end

    always @ (posedge clk) begin
        if (rst) begin
            reg_lo <= 32'b0;
        end
        else if (wb_lo_we) begin
            reg_lo <= wb_lo_in;
        end
    end

    wire [31:0] hi_temp, lo_temp;
    
    assign hi_temp = ex_hi_we  ? ex_hi_in
                   : mem_hi_we ? mem_hi_in
                   : wb_hi_we  ? wb_hi_in
                   : reg_hi;//选择写入hi寄存器的数据，写使能为高，则取后面的值，若都不满足，取当前寄存器的现有值
    
    assign lo_temp = ex_lo_we  ? ex_lo_in
                   : mem_lo_we ? mem_lo_in
                   : wb_lo_we  ? wb_lo_in
                   : reg_lo;

    always @ (posedge clk) begin
        if (rst) begin
            {hi_data, lo_data} <= {32'b0, 32'b0}; //复位，清零
        end
        else if(stall[2] == `Stop && stall[3] == `NoStop) begin
            {hi_data, lo_data} <= {32'b0, 32'b0};
        end
        else if (stall[2] == `NoStop) begin
            {hi_data, lo_data} <= {hi_temp, lo_temp}; //正常更新数据
        end
    end
endmodule