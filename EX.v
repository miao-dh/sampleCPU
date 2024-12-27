`include "lib/defines.vh"
module EX(
    //输入信号
    input wire clk,//时钟信号
    input wire rst,//重置信号
    input wire flush,//清空
    input wire [`StallBus-1:0] stall,//流水线暂停信号
    input wire [31:0] hi_data,//保存高位结果
    input wire [31:0] lo_data,//保存低位结果

    input wire [`ID_TO_EX_WD-1:0] id_to_ex_bus,
    //输出信号
    output wire [`EX_TO_MEM_WD-1:0] ex_to_mem_bus,
    output wire stall_for_ex,//EX阶段是否需要暂停流水线

    output wire data_sram_en,//数据存储器使能信号，启动数据存储器的读写操作
    output wire [3:0] data_sram_wen,//写使能信号
    output wire [31:0] data_sram_addr,
    output wire [31:0] data_sram_wdata
);

    reg [`ID_TO_EX_WD-1:0] id_to_ex_bus_r;//存储ID到EX的总线数据
    //时序逻辑块，在时钟信号的上升沿对id_to_ex_bus_r进行更新
    always @ (posedge clk) begin
        if (rst) begin
            id_to_ex_bus_r <= `ID_TO_EX_WD'b0;//寄存器清零，确保系统处于初始状态
        end
        else if (flush) begin
            id_to_ex_bus_r <= `ID_TO_EX_WD'b0;//分支预测错误或异常中断，清空流水线
        end
        else if (stall[2]==`Stop && stall[3]==`NoStop) begin//EX阶段停止，插入气泡
            id_to_ex_bus_r <= `ID_TO_EX_WD'b0;
        end
        else if (stall[2]==`NoStop) begin//无需暂停，正常更新，将从ID阶段传来的总线数据写入寄存器
            id_to_ex_bus_r <= id_to_ex_bus;
        end
    end

    wire [31:0] ex_pc, inst;//EX段的指令地址和指令内容
    wire [8:0] hilo_op;
    wire [4:0] mem_op;//访存操作类型（读、写）
    wire [11:0] alu_op;
    wire [2:0] sel_alu_src1;
    wire [3:0] sel_alu_src2;
    wire data_ram_en;//数据存储器是否被启用
    wire [3:0] data_ram_wen;//数据存储器写使能信号
    wire rf_we;//寄存器文件写使能信号
    wire [4:0] rf_waddr;
    wire sel_rf_res;//选择写回寄存器文件的数据来源
    wire [31:0] rf_rdata1, rf_rdata2;//从寄存器文件读取的操作数
    reg is_in_delayslot;//标记当前指令是否处于延迟槽（跳转或分支指令的下一条指令会被执行）

    assign {
        hilo_op,        // 172:164
        mem_op,         // 163:159
        ex_pc,          // 158:127
        inst,           // 126:95
        alu_op,         // 94:83
        sel_alu_src1,   // 82:80
        sel_alu_src2,   // 79:76
        data_ram_en,    // 75
        data_ram_wen,   // 74:71
        rf_we,          // 70
        rf_waddr,       // 69:65
        sel_rf_res,     // 64
        rf_rdata1,      // 63:32
        rf_rdata2       // 31:0
    } = id_to_ex_bus_r;

    wire [31:0] imm_sign_extend, imm_zero_extend, sa_zero_extend;移位量零扩展 
    assign imm_sign_extend = {{16{inst[15]}},inst[15:0]};//立即数符号扩展
    assign imm_zero_extend = {16'b0, inst[15:0]};//立即数零扩展
    assign sa_zero_extend = {27'b0,inst[10:6]};//移位量零扩展 

    wire [31:0] alu_src1, alu_src2;
    wire [31:0] alu_result;
    wire [31:0] ex_result;
    wire [31:0] hilo_result;
    wire [65:0] hilo_bus;

    assign alu_src1 = sel_alu_src1[1] ? ex_pc :
                      sel_alu_src1[2] ? sa_zero_extend ://5位移位量零扩展至32位
                      rf_rdata1;//寄存器堆的第一个寄存器数据

    assign alu_src2 = sel_alu_src2[1] ? imm_sign_extend :
                      sel_alu_src2[2] ? 32'd8           :
                      sel_alu_src2[3] ? imm_zero_extend :
                      rf_rdata2;
    
    alu u_alu(
    	.alu_control (alu_op      ),//控制信号，指定ALU要执行的操作
        .alu_src1    (alu_src1    ),
        .alu_src2    (alu_src2    ),
        .alu_result  (alu_result  )
    );

    //Store Part
    wire inst_sb, inst_sh, inst_sw;//存储字节，存储半字，存储字指令
    reg [3:0] data_sram_wen_r;//写使能信号，指定实际需要写入哪些字节
    reg [31:0] data_sram_wdata_r;//写入数据存储器的实际数据

    assign {
        inst_sb, 
        inst_sh,
        inst_sw
    } = data_ram_wen[2:0];
//处理存储指令的具体逻辑，根据指令类型和地址的低位值来控制存储器写入数据的内容以及写使能信号
    always @ (*) begin
        case(1'b1)
            inst_sb://字节
            begin
                data_sram_wdata_r <= {4{rf_rdata2[7:0]}};//将数据的最低8位重复4次，生成32位的值
                case(alu_result[1:0])//地址的最低两位，决定字节对齐位置
                    2'b00://地址对齐在4字节边界的第0字节
                    begin
                        data_sram_wen_r <= 4'b0001;//写入第0字节
                    end
                    2'b01://地址对齐在第1字节
                    begin
                        data_sram_wen_r <= 4'b0010;//写入第1字节
                    end
                    2'b10://地址对齐在第2字节
                    begin
                        data_sram_wen_r <= 4'b0100;
                    end
                    2'b11://地址对齐在第3字节
                    begin
                        data_sram_wen_r <= 4'b1000;
                    end
                    default:
                    begin
                        data_sram_wen_r <= 4'b0;//无效
                    end
                endcase
            end
            inst_sh://半字
            begin
                data_sram_wdata_r <= {2{rf_rdata2[15:0]}};//寄存器的低16位重复2次，扩展为32位
                case(alu_result[1:0])
                    2'b00:
                    begin
                        data_sram_wen_r <= 4'b0011;//写入第0字节和第1字节
                    end
                    2'b10:
                    begin
                        data_sram_wen_r <= 4'b1100;//写入第2字节和第3字节
                    end
                    default:
                    begin
                        data_sram_wen_r <= 4'b0000;
                    end
                endcase
            end
            inst_sw://字
            begin
                data_sram_wdata_r <= rf_rdata2;//将寄存器中的完整32位数据直接写入存储器
                data_sram_wen_r <= 4'b1111;//写入所有4个字节
            end
            default://当前没有有效指令，默认不写入任何数据
            begin
                data_sram_wdata_r <= 32'b0;//写入数据为0
                data_sram_wen_r <= 4'b0000;//写使能信号为0
            end
        endcase
    end
//数据存储器接口信号分配部分（将组合逻辑块生成的信号连接到数据存储器接口上）
    assign data_sram_en = data_ram_en;//数据存储器的启用信号，决定存储器是否进行读/写操作
    assign data_sram_wen = data_sram_wen_r;//写使能信号，控制存储器哪些字节被写入
    assign data_sram_addr = alu_result; //把ALU计算结果（当前内存操作的目标地址）赋值给数据存储器的地址信号，决定当前存储器访问的目标地址
    assign data_sram_wdata = data_sram_wdata_r;//数据存储器的写入数据信号

    assign ex_to_mem_bus = {
        hilo_bus,       // 146:81
        mem_op,         // 80:76
        ex_pc,          // 75:44
        data_ram_en,    // 43
        data_ram_wen,   // 42:39
        sel_rf_res,     // 38  写回寄存器的结果选择
        rf_we,          // 37
        rf_waddr,       // 36:32
        ex_result       // 31:0
    };

// HILO Part
    wire inst_mfhi, inst_mflo,  inst_mthi,  inst_mtlo;//从HI、LO中取值和写入
    wire inst_mult, inst_multu, inst_div,   inst_divu;//结果储存在HI、LO
    wire inst_mul;//乘法，结果直接写入目标寄存器（无需HI、LO）

    assign {
        inst_mfhi, inst_mflo, inst_mthi, inst_mtlo,
        inst_mult, inst_multu, inst_div, inst_divu,
        inst_mul
    } = hilo_op;

    reg stall_for_div;
    reg stall_for_mul;
    assign stall_for_ex = stall_for_div | stall_for_mul;
    wire [63:0] mul_result;//乘法运算的结果，64位（高32位在HI，低32位在LO）
    wire mul_signed; // 为高，有符号乘法标记
    
    wire [63:0] div_result;
    wire div_ready_i;

    reg [31:0] div_opdata1_o;//被除数
    reg [31:0] div_opdata2_o;//除数
    reg div_start_o;
    reg signed_div_o;//高：有符号除法

    wire hi_we, lo_we;//写使能信号
    wire [31:0] hi_result, lo_result;//写入的数据

    wire op_mul  = inst_mul | inst_mult | inst_multu;
    wire op_div  = inst_div | inst_divu;

    assign hi_we = inst_mthi | inst_div | inst_divu | inst_mult | inst_multu;//高32位，除法操作的余数
    assign lo_we = inst_mtlo | inst_div | inst_divu | inst_mult | inst_multu;//低32位，除法操作的商
    
    assign hi_result = inst_mthi ? rf_rdata1         ://写入寄存器的数据
                       op_mul    ? mul_result[63:32] :
                       op_div    ? div_result[63:32] : 
                       32'b0;//写入默认值
    assign lo_result = inst_mtlo ? rf_rdata1        : 
                       op_mul    ? mul_result[31:0] :
                       op_div    ? div_result[31:0] :
                       32'b0;
    //值的读取
    assign hilo_result = inst_mfhi ? hi_data :
                         inst_mflo ? lo_data :
                         32'b0;

    assign hilo_bus = {
        hi_we, 
        lo_we,
        hi_result,
        lo_result
    };
    //EX阶段最终的计算结果选择
    assign ex_result = (inst_mfhi | inst_mflo) ? hilo_result :
                       alu_result;
    
// 乘法器模块
    assign mul_signed = inst_mult;//布尔信号，高电平（Inst_mult)时为有符号乘法

    mul u_mul(
    	.clk        (clk            ),
        .resetn     (~rst           ),//复位信号，低电平有效
        .mul_signed (mul_signed     ),
        .ina        (rf_rdata1      ), // 乘法源操作数1
        .inb        (rf_rdata2      ), // 乘法源操作数2
        .result     (mul_result     )  // 乘法结果 64bit
    );
    //时钟计数器
    reg cnt;//存储当前的计数状态，初始为0，复位时强制设置为1'b0  0：乘法操作刚开始，未完成  1：乘法操作已经完成
    reg next_cnt;

    always @ (posedge clk) begin
        if (rst) begin//复位信号有效时
            cnt <= 1'b0;//设置为0
        end
        else begin
            cnt <= next_cnt;//更新为下一周期的cnt
        end
    end

    always @ (*) begin
        if (rst) begin//全局复位信号有效
            stall_for_mul <= 1'b0;//0，流水线不暂停
            next_cnt <= 1'b0;//计数器重置为0
        end
        else if ((inst_mult | inst_multu) & ~cnt) begin//乘法，且未完成
            stall_for_mul <= 1'b1;//暂停
            next_cnt <= 1'b1;//进入乘法第二阶段
        end
        else if ((inst_mult | inst_multu) & cnt) begin//已完成
            stall_for_mul <= 1'b0;
            next_cnt <= 1'b0;
        end
        else begin
            stall_for_mul <= 1'b0;
            next_cnt <= 1'b0;
        end
    end 
    
// 除法器模块
    div u_div(
    	.rst          (rst           ),
        .clk          (clk           ),
        .signed_div_i (signed_div_o  ),
        .opdata1_i    (div_opdata1_o ),
        .opdata2_i    (div_opdata2_o ),
        .start_i      (div_start_o   ),
        .annul_i      (1'b0          ),//取消信号，恒为0，当前模块没有支持取消操作的功能
        .result_o     (div_result    ), // 除法结果 64bit
        .ready_o      (div_ready_i   )
    );

    always @ (*) begin
        if (rst) begin//复位
            stall_for_div <= `NoStop;
            div_opdata1_o <= `ZeroWord;
            div_opdata2_o <= `ZeroWord;
            div_start_o <= `DivStop;
            signed_div_o <= 1'b0;//默认无符号
        end
        else begin   //初始化
            stall_for_div <= `NoStop;
            div_opdata1_o <= `ZeroWord;
            div_opdata2_o <= `ZeroWord;
            div_start_o <= `DivStop;
            signed_div_o <= 1'b0;
            case ({inst_div, inst_divu})
                2'b10://有符号除法
                begin
                    if (div_ready_i == `DivResultNotReady) begin//除法器未准备好
                        div_opdata1_o <= rf_rdata1;
                        div_opdata2_o <= rf_rdata2;
                        div_start_o <= `DivStart;
                        signed_div_o <= 1'b1;
                        stall_for_div <= `Stop;
                    end
                    else if (div_ready_i == `DivResultReady) begin//除法器已准备好
                        div_opdata1_o <= rf_rdata1;
                        div_opdata2_o <= rf_rdata2;
                        div_start_o <= `DivStop;
                        signed_div_o <= 1'b1;
                        stall_for_div <= `NoStop;//恢复流水线运行
                    end
                    else begin//默认情况，清零所有信号，流水线不暂停
                        div_opdata1_o <= `ZeroWord;
                        div_opdata2_o <= `ZeroWord;
                        div_start_o <= `DivStop;
                        signed_div_o <= 1'b0;
                        stall_for_div <= `NoStop;
                    end
                end
                2'b01://无符号除法
                begin
                    if (div_ready_i == `DivResultNotReady) begin
                        div_opdata1_o <= rf_rdata1;
                        div_opdata2_o <= rf_rdata2;
                        div_start_o <= `DivStart;
                        signed_div_o <= 1'b0;
                        stall_for_div <= `Stop;
                    end
                    else if (div_ready_i == `DivResultReady) begin
                        div_opdata1_o <= rf_rdata1;
                        div_opdata2_o <= rf_rdata2;
                        div_start_o <= `DivStop;
                        signed_div_o <= 1'b0;
                        stall_for_div <= `NoStop;
                    end
                    else begin
                        div_opdata1_o <= `ZeroWord;
                        div_opdata2_o <= `ZeroWord;
                        div_start_o <= `DivStop;
                        signed_div_o <= 1'b0;
                        stall_for_div <= `NoStop;
                    end
                end
                default:
                begin
                end
            endcase
        end
    end

    // mul_result 和 div_result 可以直接使用
    
    
endmodule