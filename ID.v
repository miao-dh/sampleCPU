`include "lib/defines.vh"
module ID(
    //输入：
    input wire clk,  //时钟信号
    input wire rst,  //复位信号
    input wire flush,//清空信号，在流水线中清空指令数据
    input wire [`StallBus-1:0] stall, //流水线暂停信号
    
    output wire stallreq, //如果ID段需要暂停，发出暂停请求

    input wire [`IF_TO_ID_WD-1:0] if_to_id_bus,//IF到ID的数据总线

    input wire [31:0] inst_sram_rdata, //从指令存储器读取的指令数据

    input wire ex_we,//是否需要写寄存器文件
    input wire [4:0] ex_waddr,
    input wire [31:0] ex_wdata,
    input wire ex_ram_read,//是否需要内存读取

    input wire mem_we,
    input wire [4:0] mem_waddr,
    input wire [31:0] mem_wdata,

    input wire [`WB_TO_RF_WD-1:0] wb_to_rf_bus,//从写回阶段传递到寄存器文件的信息

    output wire stall_for_load,//r如果正在执行加载指令且前面的阶段存在数据依赖，发出暂停信号
    output wire [`ID_TO_EX_WD-1:0] id_to_ex_bus,
    output wire [`BR_WD-1:0] br_bus //跳转相关信息
);

    reg [`IF_TO_ID_WD-1:0] if_to_id_bus_r; //保存从IF阶段传递过来的数据总线值
    wire [31:0] inst;  //当前指令数据
    wire [31:0] id_pc; //当前指令的地址
    wire ce; //控制信号

    wire wb_rf_we;//控制写回阶段是否写入寄存器
    wire [4:0] wb_rf_waddr;//写回阶段写入寄存器的地址
    wire [31:0] wb_rf_wdata;//写回阶段写入寄存器的数据

    wire [4:0] mem_op;//控制存储操作的类型
    wire [8:0] hilo_op;//高低寄存器

    reg is_stop;//1位宽的寄存器，标记是否需要暂停
//控制流水线在不同条件下是否需要暂停、刷新或继续运行
    always @ (posedge clk) begin//时序逻辑块，在时钟的上升沿触发，每次时钟信号上升时，执行always
        if (rst) begin//rst为1时，系统处于重置状态，所有寄存器和状态清零
            if_to_id_bus_r <= `IF_TO_ID_WD'b0;//清空IF到ID阶段的总线传输数据
            is_stop <= 1'b0;//is_stop清零，不处于暂停状态
        end
        else if (flush) begin//flush为1时，刷新状态，处理异常时需要清除某些流水线的数据
            if_to_id_bus_r <= `IF_TO_ID_WD'b0;//停止IF到ID阶段的数据传输
            is_stop <= 1'b0;//is_stop为0，不暂停流水线
        end
        else if (stall[1]==`Stop && stall[2]==`NoStop) begin//IF需要暂停，ID不需要暂停
            if_to_id_bus_r <= `IF_TO_ID_WD'b0;//停止IF到ID的传输
            is_stop <= 1'b0;//不暂停流水线
        end
        else if (stall[1]==`NoStop) begin//IF不需要暂停
            if_to_id_bus_r <= if_to_id_bus;//保存IF阶段的值，继续传输
            is_stop <= 1'b0;//不暂停流水线
        end
        else if (stall[2]==`Stop) begin//ID段需要暂停
            is_stop <= 1'b1;//进入暂停状态
        end
    end

    assign inst = is_stop ? inst : inst_sram_rdata;//is_stop为1（暂停），则inst保持原值，否则不暂停，更新为新指令数据

    assign {//将总线信号的部分位宽赋值给多个单独的信号
        ce,//if_to_id_bus_r的高位部分赋值给ce
        id_pc//低位部分
    } = if_to_id_bus_r;

    assign {
        wb_rf_we,
        wb_rf_waddr,
        wb_rf_wdata
    } = wb_to_rf_bus;
//指令字段和操作码信号
    wire [5:0] opcode;//指示指令的类型
    wire [4:0] rs,rt,rd,sa;//rs、rt源寄存器，rd目标寄存器，sa位移值
    wire [5:0] func;//R型指令
    wire [15:0] imm;//I型指令，立即数
    wire [25:0] instr_index;//J型指令，指示跳转目标
    wire [19:0] code;
    wire [4:0] base;//基址寄存器
    wire [15:0] offset;//偏移量
    wire [2:0] sel;//3位宽的选择信号，有8个值

//解码阶段寄存器和数据
    wire [63:0] op_d, func_d;//解码阶段的操作码，功能码
    wire [31:0] rs_d, rt_d, rd_d, sa_d;//解码结果

//ALU的操作数
    wire [2:0] sel_alu_src1;//第一个操作数
    wire [3:0] sel_alu_src2;//第二个操作数
    wire [11:0] alu_op;//ALU的具体操作（加、减、与、或）

//RAM（控制数据存储器）的读写操作
    wire data_ram_en;//是否启用数据存储器操作
    wire [3:0] data_ram_wen;//指示哪些字节需要写入

//寄存器文件的读写操作
    wire rf_we;//是否写到寄存器文件
    wire [4:0] rf_waddr;//写入的寄存器编号
    wire sel_rf_res;//选择寄存器文件的数据源
    wire [2:0] sel_rf_dst;//寄存器文件的目标寄存器
//数据寄存器
    wire [31:0] rdata1, rdata2;//存储寄存器中的数据
    wire [31:0] hi_data, lo_data;//存储高低寄存器中的数据
//数据依赖检查
    wire rs_ex_ok, rt_ex_ok;//rs、rt在ex阶段是否可以正常使用
    wire rs_mem_ok, rt_mem_ok;//rs、rt在mem阶段是否可以正常使用
    wire sel_rs_forward;//是否需要数据转发
    wire sel_rt_forward;
    wire [31:0] rs_forward_data;//分别存储转发的数据，解决数据依赖问题
    wire [31:0] rt_forward_data;
//寄存器文件读取
    wire [31:0] rf_rdata1;//从寄存器读取数据
    wire [31:0] rf_rdata2;
//前向数据
    wire [31:0] rdata1_fd;//存储经过前向的数据
    wire [31:0] rdata2_fd;

    regfile u_regfile(//从寄存器读取数据并根据写使能信号将数据写入寄存器
    	.clk             (clk               ),
        .raddr1          (rs                ),
        .rdata1          (rdata1            ),
        .raddr2          (rt                ),
        .rdata2          (rdata2            ),
        
        .we              (wb_rf_we          ),//写使能信号，为1时，允许写数据到寄存器文件
        .waddr           (wb_rf_waddr       ),
        .wdata           (wb_rf_wdata       )
    );
//数据转发逻辑（解决数据依赖问题）
    wire sel_r1_wdata;//如果写回阶段要写入的寄存器地址（wb_rf_waddr)与当前指令的rs或rt寄存器地址相同，
    wire sel_r2_wdata;//并且wb_rf_we为1，则选择写回数据，否则使用寄存器文件读取的数据（rdata1或rdata2）
    assign sel_r1_wdata = wb_rf_we & (wb_rf_waddr == rs);
    assign sel_r2_wdata = wb_rf_we & (wb_rf_waddr == rt);

    assign rf_rdata1 = sel_r1_wdata ? wb_rf_wdata : rdata1;//如果需要转发数据，数据使用wb_rf_wdata，
    assign rf_rdata2 = sel_r2_wdata ? wb_rf_wdata : rdata2;//否则使用从寄存器读取的数据 
//指令译码
    assign opcode      = inst[31:26];
    assign rs          = inst[25:21];
    assign rt          = inst[20:16];
    assign rd          = inst[15:11];
    assign sa          = inst[10:6];
    assign func        = inst[5:0];
    assign imm         = inst[15:0];
    assign instr_index = inst[25:0];//跳转指令
    assign code        = inst[25:6];//提取指令的高26位
    assign base        = inst[25:21];
    assign offset      = inst[15:0];
    assign sel         = inst[2:0];//选择信号
//操作码信号定义（指令解码阶段识别当前执行的指令）
    wire inst_add,   inst_addi,   inst_addu,   inst_addiu;
    wire inst_sub,   inst_subu,   inst_slt,    inst_slti;  
    wire inst_sltu,  inst_sltiu,  inst_div,    inst_divu;
    wire inst_mult,  inst_multu,  inst_and,    inst_andi;  
    wire inst_lui,   inst_nor,    inst_or,     inst_ori;
    wire inst_xor,   inst_xori,   inst_sll,    inst_sllv;
    wire inst_sra,   inst_srav,   inst_srl,    inst_srlv;
    wire inst_beq,   inst_bne,    inst_bgez,   inst_bgtz;
    wire inst_blez,  inst_bltz,   inst_bltzal, inst_bgezal;
    wire inst_j,     inst_jal,    inst_jr,     inst_jalr;  
    wire inst_mfhi,  inst_mflo,   inst_mthi,   inst_mtlo;
    wire inst_lb,    inst_lbu,    inst_lh,     inst_lhu;
    wire inst_lw,    inst_sb,     inst_sh,     inst_sw;
    wire inst_break, inst_syscall;
    wire inst_eret,  inst_mfc0,   inst_mtc0;
    wire inst_mul;

//操作信号定义
    wire op_add, op_sub, op_slt, op_sltu;
    wire op_and, op_nor, op_or, op_xor;
    wire op_sll, op_srl, op_sra, op_lui;
//解码器
    decoder_6_64 u0_decoder_6_64(
    	.in  (opcode),
        .out (op_d  )
    );

    decoder_6_64 u1_decoder_6_64(
    	.in  (func   ),
        .out (func_d )
    );
    
    decoder_5_32 u0_decoder_5_32(
    	.in  (rs   ),
        .out (rs_d )
    );

    decoder_5_32 u1_decoder_5_32(
    	.in  (rt   ),
        .out (rt_d )
    );

//MIPS指令的解码实现，通过操作码（opcode）和功能码（func）生成各种指令信息，确定指令类型和相应操作进行控制    
    assign inst_add     = op_d[6'b00_0000] & func_d[6'b10_0000];//R,加
    assign inst_addi    = op_d[6'b00_1000];//I，立即数加
    assign inst_addu    = op_d[6'b00_0000] & func_d[6'b10_0001];//R，无符号加
    assign inst_addiu   = op_d[6'b00_1001];//无符号立即数加
    assign inst_sub     = op_d[6'b00_0000] & func_d[6'b10_0010];//减
    assign inst_subu    = op_d[6'b00_0000] & func_d[6'b10_0011];//R无符号减
    assign inst_slt     = op_d[6'b00_0000] & func_d[6'b10_1010];//R，两个操作数是否满足小于
    assign inst_slti    = op_d[6'b00_1010];//一个寄存器，一个立即数  小于
    assign inst_sltu    = op_d[6'b00_0000] & func_d[6'b10_1011];
    assign inst_sltiu   = op_d[6'b00_1011];

    assign inst_div     = op_d[6'b00_0000] & func_d[6'b01_1010];
    assign inst_divu    = op_d[6'b00_0000] & func_d[6'b01_1011];
    assign inst_mul     = op_d[6'b01_1100] & func_d[6'b00_0010];
    assign inst_mult    = op_d[6'b00_0000] & func_d[6'b01_1000];
    assign inst_multu   = op_d[6'b00_0000] & func_d[6'b01_1001];
    
    assign inst_and     = op_d[6'b00_0000] & func_d[6'b10_0100];
    assign inst_andi    = op_d[6'b00_1100];
    assign inst_lui     = op_d[6'b00_1111];//16位立即数加载到寄存器的高16位，低16填充为0
    assign inst_nor     = op_d[6'b00_0000] & func_d[6'b10_0111];//按位或，取反
    assign inst_or      = op_d[6'b00_0000] & func_d[6'b10_0101];
    assign inst_ori     = op_d[6'b00_1101];
    assign inst_xor     = op_d[6'b00_0000] & func_d[6'b10_0110];//按位异或
    assign inst_xori    = op_d[6'b00_1110];
    
    assign inst_sllv    = op_d[6'b00_0000] & func_d[6'b00_0100];//逻辑左移  寄存器中的一个数决定左移的位数
    assign inst_sll     = op_d[6'b00_0000] & func_d[6'b00_0000];//立即数决定左移的位数
    assign inst_srav    = op_d[6'b00_0000] & func_d[6'b00_0111];//算术右移  保持符号位，左侧空位用符号位填充
    assign inst_sra     = op_d[6'b00_0000] & func_d[6'b00_0011];
    assign inst_srlv    = op_d[6'b00_0000] & func_d[6'b00_0110];//逻辑右移  空位填0，不考虑符号位
    assign inst_srl     = op_d[6'b00_0000] & func_d[6'b00_0010];

    assign inst_beq     = op_d[6'b00_0100];//rs与rt相等，PC更新为PC+offset
    assign inst_bne     = op_d[6'b00_0101];//rs和rt不相等，更新PC
    assign inst_bgez    = op_d[6'b00_0001] & rt_d[5'b0_0001];//rs大于等于零，则跳转
    assign inst_bgtz    = op_d[6'b00_0111];//rs大于零，跳转
    assign inst_blez    = op_d[6'b00_0110];//rs小于等于零，跳转
    assign inst_bltz    = op_d[6'b00_0001] & rt_d[5'b0_0000];//rs小于零，跳转
    assign inst_bgezal  = op_d[6'b00_0001] & rt_d[5'b1_0001];//rs大于等于零，跳转，并将PC保存到ra
    assign inst_bltzal  = op_d[6'b00_0001] & rt_d[5'b1_0000];//rs小于零，跳转，保存PC
    assign inst_j       = op_d[6'b00_0010];//J指令，无条件跳转
    assign inst_jal     = op_d[6'b00_0011];//无条件跳转，并将返回地址保存到ra
    assign inst_jr      = op_d[6'b00_0000] & func_d[6'b00_1000];//跳转到rs地址，PC更新为rs中的值
    assign inst_jalr    = op_d[6'b00_0000] & func_d[6'b00_1001];//跳转到rs地址，把PC+4保存到rd中

    assign inst_mfhi    = op_d[6'b00_0000] & func_d[6'b01_0000];//将HI（存储乘法和除法操作的高32位结果）的值移到目标寄存器
    assign inst_mflo    = op_d[6'b00_0000] & func_d[6'b01_0010];//将LO（存储惩罚和额除法操作的低32位结果）的值移到目标寄存器
    assign inst_mthi    = op_d[6'b00_0000] & func_d[6'b01_0001];//将除法操作中的高32位结果写入HI
    assign inst_mtlo    = op_d[6'b00_0000] & func_d[6'b01_0011];//将除法操作中的低32位结果写入LO

    assign inst_break   = op_d[6'b00_0000] & func_d[6'b00_1101];//触发断点，中断当前程序执行
    assign inst_syscall = op_d[6'b00_0000] & func_d[6'b00_1100];//程序通过异常或中断切换到操作系统内核模式

    assign inst_lb      = op_d[6'b10_0000];//一个字节符号扩展，成32位
    assign inst_lbu     = op_d[6'b10_0100];//无符号扩展
    assign inst_lh      = op_d[6'b10_0001];//一个半字符号扩展
    assign inst_lhu     = op_d[6'b10_0101];
    assign inst_lw      = op_d[6'b10_0011];//一个完整的字
    assign inst_sb      = op_d[6'b10_1000];//将一个字节存储到内存中
    assign inst_sh      = op_d[6'b10_1001];//半字存储到内存
    assign inst_sw      = op_d[6'b10_1011];//字存储到内存

    assign inst_eret    = op_d[6'b01_0000] & func_d[6'b01_1000];//从异常处理程序返回
    assign inst_mfc0    = op_d[6'b01_0000] & rs_d[5'b0_0000];//从协处理器0中读取数据，移动到指定寄存器
    assign inst_mtc0    = op_d[6'b01_0000] & rs_d[5'b0_0100];//从常规寄存器移动到协处理器0

    assign hilo_op = {
        inst_mfhi, inst_mflo , inst_mthi, inst_mtlo,
        inst_mult, inst_multu, inst_div , inst_divu,
        inst_mul
    };
//选择ALU的输入源
    // ALU的输入1来自该指令的rs  
    assign sel_alu_src1[0] = inst_add  | inst_addi  | inst_addu  | inst_addiu 
                           | inst_sub  | inst_subu  | inst_slt   | inst_slti 
                           | inst_sltu | inst_sltiu | inst_div   | inst_divu 
                           | inst_mul  | inst_mult  | inst_multu | inst_and 
                           | inst_andi | inst_nor   | inst_or    | inst_ori 
                           | inst_xor  | inst_xori  | inst_sllv  | inst_srav 
                           | inst_srlv | inst_mthi  | inst_mtlo  | inst_lb 
                           | inst_lbu  | inst_lh    | inst_lhu   | inst_lw 
                           | inst_sb   | inst_sh    | inst_sw; 
    // ALU输入来自PC的数据
    assign sel_alu_src1[1] = inst_jal | inst_bltzal | inst_bgezal | inst_jalr;
    // 立即数
    assign sel_alu_src1[2] = inst_sll | inst_sra | inst_srl;

    
    // 输入2来自rt
    assign sel_alu_src2[0] = inst_add | inst_addu | inst_sub   | inst_subu 
                           | inst_slt | inst_sltu | inst_div   | inst_divu 
                           | inst_mul | inst_mult | inst_multu | inst_and 
                           | inst_nor | inst_or   | inst_xor   | inst_sllv 
                           | inst_sll | inst_srav | inst_sra   | inst_srlv 
                           | inst_srl;
    // 立即数扩展并送入ALU作为第二个输入
    assign sel_alu_src2[1] = inst_addi | inst_addiu | inst_lw  | inst_lb 
                           | inst_lbu  | inst_lh    | inst_lhu | inst_sw 
                           | inst_sh   | inst_sb    | inst_lui
                           | inst_slti | inst_sltiu ;
    // 32位的常数8送入输入2，计算目标地址
    assign sel_alu_src2[2] = inst_jal | inst_bltzal | inst_bgezal | inst_jalr;
    // 零扩展的立即数作为输入2，通过按位与、或、异或等指令，立即数会被0扩展为32位
    assign sel_alu_src2[3] = inst_ori | inst_andi | inst_xori;

    assign op_add  =  inst_add | inst_addu   | inst_addi   | inst_addiu 
                    | inst_lw  | inst_lb     | inst_lbu    | inst_lh 
                    | inst_lhu | inst_sw     | inst_sh     | inst_sb 
                    | inst_jal | inst_bltzal | inst_bgezal | inst_jalr;
    assign op_sub  =  inst_sub | inst_subu;
    assign op_slt  =  inst_slt | inst_slti;
    assign op_sltu =  inst_sltu | inst_sltiu;
    assign op_and  =  inst_and | inst_andi;
    assign op_nor  =  inst_nor;
    assign op_or   =  inst_or | inst_ori;
    assign op_xor  =  inst_xor | inst_xori;
    assign op_sll  =  inst_sllv | inst_sll;
    assign op_srl  =  inst_srlv | inst_srl;
    assign op_sra  = inst_srav | inst_sra;
    assign op_lui  =  inst_lui;

    assign alu_op = {op_add, op_sub, op_slt, op_sltu,
                     op_and, op_nor, op_or, op_xor,
                     op_sll, op_srl, op_sra, op_lui};

    assign mem_op = {inst_lb, inst_lbu, inst_lh, inst_lhu, inst_lw};

    // 控制数据内存的读取或写入（内存使能）
    assign data_ram_en =  inst_lb | inst_lbu | inst_lh | inst_lhu 
                        | inst_lw | inst_sb  | inst_sh | inst_sw;

    // 内存写使能
    assign data_ram_wen = {1'b0, inst_sb, inst_sh, inst_sw};

    // 寄存器文件写使能
    assign rf_we = inst_add    | inst_addu   | inst_addi  | inst_addiu 
                 | inst_sub    | inst_subu   | inst_lw    | inst_lb 
                 | inst_lbu    | inst_lh     | inst_lhu   | inst_jal 
                 | inst_bltzal | inst_bgezal | inst_jalr  | inst_slt 
                 | inst_slti   | inst_sltu   | inst_sltiu | inst_sllv 
                 | inst_sll    | inst_srlv   | inst_srl   | inst_srav 
                 | inst_sra    | inst_lui    | inst_and   | inst_andi
                 | inst_or     | inst_ori    | inst_xor   | inst_xori 
                 | inst_nor    | inst_mfhi   | inst_mflo  | inst_mfc0 
                 | inst_mul;

    // 写入寄存器文件时选择的目标寄存器是rd
    assign sel_rf_dst[0] = inst_add  | inst_addu | inst_sub  | inst_subu 
                         | inst_slt  | inst_sltu | inst_sllv | inst_sll 
                         | inst_srlv | inst_srl  | inst_srav | inst_sra 
                         | inst_and  | inst_or   | inst_xor  | inst_nor 
                         | inst_mfhi | inst_mflo | inst_mul;
    // 写入寄存器文件时选择的目标寄存器是rt 
    assign sel_rf_dst[1] = inst_addi  | inst_addiu | inst_lw   | inst_lb 
                         | inst_lbu   | inst_lh    | inst_lhu  | inst_lui 
                         | inst_ori   | inst_andi  | inst_xori | inst_slti 
                         | inst_sltiu | inst_mfc0;
    // 写入寄存器文件时选择的目标寄存器是ra
    assign sel_rf_dst[2] = inst_jal | inst_bltzal | inst_bgezal | inst_jalr;

    // 寄存器文件写地址
    assign rf_waddr = {5{sel_rf_dst[0]}} & rd 
                    | {5{sel_rf_dst[1]}} & rt
                    | {5{sel_rf_dst[2]}} & 32'd31;

    // 选择寄存器文件的写入数据，0 from alu_res   1 from ld_res
    assign sel_rf_res = inst_lw | inst_lb | inst_lbu | inst_lh | inst_lhu;

    assign rs_ex_ok =  (rs == ex_waddr)  &&  ex_we ? 1'b1 : 1'b0;//判断rs是否存在EX阶段的写回地址
    assign rt_ex_ok =  (rt == ex_waddr)  &&  ex_we ? 1'b1 : 1'b0;//

    assign rs_mem_ok = (rs == mem_waddr) && mem_we ? 1'b1 : 1'b0;
    assign rt_mem_ok = (rt == mem_waddr) && mem_we ? 1'b1 : 1'b0;
    //选择是否需要转发rs/rt数据
    assign sel_rs_forward = rs_ex_ok | rs_mem_ok;
    assign sel_rt_forward = rt_ex_ok | rt_mem_ok;
    //转发的数据
    assign rs_forward_data = rs_ex_ok  ? ex_wdata :
                             rs_mem_ok ? mem_wdata:
                             32'b0;

    assign rt_forward_data = rt_ex_ok  ? ex_wdata :
                             rt_mem_ok ? mem_wdata:
                             32'b0;
    //选择最终提供给当前流水线阶段的rs/rt数据
    assign rdata1_fd = sel_rs_forward ? rs_forward_data : rf_rdata1;
    assign rdata2_fd = sel_rt_forward ? rt_forward_data : rf_rdata2;
    //控制是否需要因加载指令而产生流水线停顿
    assign stall_for_load = ex_ram_read & (rs_ex_ok | rt_ex_ok);
//ID阶段的信号打包发送到EX
    assign id_to_ex_bus = {
        hilo_op,         // 172:164
        mem_op,          // 163:159
        id_pc,           // 158:127
        inst,            // 126:95
        alu_op,          // 94:83
        sel_alu_src1,    // 82:80
        sel_alu_src2,    // 79:76
        data_ram_en,     // 75
        data_ram_wen,    // 74:71
        rf_we,           // 70
        rf_waddr,        // 69:65
        sel_rf_res,      // 64
        rdata1_fd,       // 63:32
        rdata2_fd        // 31:0
    };


    wire br_e;
    wire [31:0] br_addr;
    wire rs_eq_rt;
    wire rs_ge_z;
    wire rs_gt_z;
    wire rs_le_z;
    wire rs_lt_z;
    wire [31:0] pc_plus_4;
    assign pc_plus_4 = id_pc + 32'h4;

    assign rs_eq_rt = (rdata1_fd == rdata2_fd);//rdata1_fd,rdata2_fd是否相等，用于分支指令beq（等于时跳转）和bne（不等跳转）
    assign rs_ge_z = ~rdata1_fd[31];//rdata1_fd大于等于0，跳bgez或bgezal
    assign rs_gt_z = ($signed(rdata1_fd) > 0);//rdata1_fd大于1，跳bgtz
    assign rs_le_z = (rdata1_fd[31]==1'b1 || rdata1_fd == 32'b0);//rdata1_fd小于等于0，跳blez
    assign rs_lt_z = (rdata1_fd[31]);//rdata1_fd小于0，跳bltz或bltzal
    //分支使能信号
    assign br_e = inst_beq & rs_eq_rt
                | inst_bne & ~rs_eq_rt
                | inst_bgez & rs_ge_z
                | inst_bgezal & rs_ge_z
                | inst_bgtz & rs_gt_z
                | inst_blez & rs_le_z
                | inst_bltz & rs_lt_z
                | inst_bltzal & rs_lt_z
                | inst_j
                | inst_jal
                | inst_jr
                | inst_jalr;
    //计算分支指令的目标地址
    assign br_addr = inst_beq    ? (pc_plus_4 + {{14{inst[15]}}, inst[15:0], 2'b0}) ://pc_plus_4加上立即数偏移（指令中的立即数进行符号扩展后左移2位）
                     inst_bne    ? (pc_plus_4 + {{14{inst[15]}}, inst[15:0], 2'b0}) :
                     inst_bgez   ? (pc_plus_4 + {{14{inst[15]}}, inst[15:0], 2'b0}) :
                     inst_bgezal ? (pc_plus_4 + {{14{inst[15]}}, inst[15:0], 2'b0}) :
                     inst_bgtz   ? (pc_plus_4 + {{14{inst[15]}}, inst[15:0], 2'b0}) :
                     inst_blez   ? (pc_plus_4 + {{14{inst[15]}}, inst[15:0], 2'b0}) :
                     inst_bltz   ? (pc_plus_4 + {{14{inst[15]}}, inst[15:0], 2'b0}) :
                     inst_bltzal ? (pc_plus_4 + {{14{inst[15]}}, inst[15:0], 2'b0}) :
                     inst_j      ? {pc_plus_4[31:28],inst[25:0], 2'b0}              ://指令中的地址部分和当前PC的高4位拼接而成
                     inst_jal    ? {pc_plus_4[31:28],inst[25:0], 2'b0}              : 
                     inst_jr     ? rdata1_fd                                     :
                     inst_jalr   ? rdata1_fd                                     :
                     32'b0;

    assign br_bus = {
        br_e,
        br_addr
    };
    


endmodule