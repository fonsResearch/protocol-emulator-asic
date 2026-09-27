module pemu_core_macro (
    uio_in,
    rst_sync_n,
    clock,
    ui_in,
    uo_out,
    uio_out,
    uio_oe
);

    input [7:0] uio_in;
    input rst_sync_n;
    input clock;
    input [7:0] ui_in;
    output [7:0] uo_out;
    output [7:0] uio_out;
    output [7:0] uio_oe;

    wire [7:0] _23;
    wire [6:0] _64;
    wire _63;
    wire [7:0] _65;
    wire [3:0] _47;
    wire _48;
    wire _49;
    wire [7:0] _59;
    wire [3:0] _44;
    wire _45;
    wire _46;
    wire [7:0] _62;
    wire [3:0] _41;
    wire _42;
    wire _43;
    wire [7:0] _66;
    wire [7:0] _67;
    wire [7:0] _3;
    reg [7:0] sr;
    wire _214;
    wire [7:0] _216;
    wire _210;
    wire _209;
    wire _208;
    wire _206;
    wire _207;
    wire _204;
    wire _205;
    wire _201;
    wire _202;
    wire _203;
    wire _198;
    wire _199;
    wire _200;
    wire _195;
    wire _194;
    wire _196;
    wire [2:0] _192;
    wire _193;
    wire _197;
    wire [7:0] _211;
    wire [7:0] _212;
    wire [7:0] _213;
    wire [7:0] _217;
    wire _187;
    wire _188;
    wire [7:0] _218;
    wire [3:0] _183;
    wire _184;
    wire _179;
    wire [11:0] _175;
    wire _176;
    wire _177;
    wire [3:0] _173;
    wire _83;
    wire _84;
    wire [7:0] _88;
    wire [7:0] _90;
    wire [7:0] _4;
    reg [7:0] load_lo;
    wire [7:0] _6;
    reg [7:0] s1_uio;
    reg [7:0] s2_uio;
    wire [15:0] _170;
    wire [11:0] _108;
    wire [11:0] _109;
    wire [11:0] _111;
    wire [11:0] _100;
    wire _95;
    wire _96;
    wire _93;
    wire _97;
    wire [11:0] _101;
    wire [11:0] _112;
    wire [11:0] _113;
    wire [11:0] _7;
    reg [11:0] wait_cnt;
    wire _106;
    wire _107;
    wire [5:0] _145;
    wire [7:0] _124;
    wire [7:0] _61;
    wire [3:0] _118;
    wire _119;
    wire _120;
    wire [7:0] _126;
    wire [3:0] _115;
    wire _116;
    wire _117;
    wire [7:0] _127;
    wire [7:0] _128;
    wire [7:0] _8;
    reg [7:0] lc;
    wire [7:0] _125;
    wire _141;
    wire _142;
    wire [5:0] _143;
    wire _138;
    wire [5:0] _139;
    wire [5:0] _135;
    wire [5:0] _133;
    wire [5:0] _130;
    wire [5:0] _9;
    reg [5:0] pc;
    wire [5:0] _136;
    wire [11:0] _60;
    wire [5:0] _131;
    reg [5:0] _144;
    wire [5:0] next_pc;
    wire [5:0] _10;
    wire [5:0] _168;
    wire [5:0] _169;
    wire [5:0] _154;
    wire [5:0] _155;
    wire [5:0] _157;
    wire [5:0] _11;
    reg [5:0] load_addr;
    wire _165;
    wire _162;
    wire _163;
    wire _166;
    wire _158;
    wire _159;
    wire _161;
    wire _12;
    reg imem_write;
    wire load_hi;
    reg s3_wstb;
    wire _78;
    wire _68;
    reg s1_wstb;
    reg s2_wstb;
    wire _79;
    wire _147;
    wire _148;
    wire _149;
    wire [15:0] _172;
    wire [15:0] _13;
    wire [3:0] _40;
    wire _174;
    wire _178;
    wire _180;
    wire gnd;
    wire _181;
    wire _14;
    reg waiting;
    wire _38;
    wire _39;
    wire _185;
    wire [7:0] _219;
    wire vdd;
    wire _16;
    wire _27;
    wire _18;
    wire [7:0] _20;
    wire _25;
    reg s1_run;
    reg running;
    wire s2_run;
    wire [7:0] _220;
    wire [7:0] _21;
    reg [7:0] out;
    assign _23 = 8'b00000000;
    assign _64 = sr[7:1];
    assign _63 = 1'b0;
    assign _65 = { _63,
                   _64 };
    assign _47 = 4'b0100;
    assign _48 = _40 == _47;
    assign _49 = _39 & _48;
    assign _59 = _49 ? s2_uio : sr;
    assign _44 = 4'b0011;
    assign _45 = _40 == _44;
    assign _46 = _39 & _45;
    assign _62 = _46 ? _61 : _59;
    assign _41 = 4'b0010;
    assign _42 = _40 == _41;
    assign _43 = _39 & _42;
    assign _66 = _43 ? _65 : _62;
    assign _67 = running ? _66 : _23;
    assign _3 = _67;
    always @(posedge _18) begin
        if (_27)
            sr <= _23;
        else
            sr <= _3;
    end
    assign _214 = sr[0:0];
    assign _216 = _214 ? _211 : _23;
    assign _210 = _206 & _204;
    assign _209 = _206 & _202;
    assign _208 = _206 & _199;
    assign _206 = ~ _193;
    assign _207 = _206 & _196;
    assign _204 = _201 & _198;
    assign _205 = _193 & _204;
    assign _201 = ~ _194;
    assign _202 = _201 & _195;
    assign _203 = _193 & _202;
    assign _198 = ~ _195;
    assign _199 = _194 & _198;
    assign _200 = _193 & _199;
    assign _195 = _192[0:0];
    assign _194 = _192[1:1];
    assign _196 = _194 & _195;
    assign _192 = _60[2:0];
    assign _193 = _192[2:2];
    assign _197 = _193 & _196;
    assign _211 = { _197,
                    _200,
                    _203,
                    _205,
                    _207,
                    _208,
                    _209,
                    _210 };
    assign _212 = ~ _211;
    assign _213 = out & _212;
    assign _217 = _213 | _216;
    assign _187 = _40 == _41;
    assign _188 = _39 & _187;
    assign _218 = _188 ? _217 : out;
    assign _183 = 4'b0001;
    assign _184 = _40 == _183;
    assign _179 = ~ _107;
    assign _175 = 12'b000000000000;
    assign _176 = _60 == _175;
    assign _177 = ~ _176;
    assign _173 = 4'b0101;
    assign _83 = ~ imem_write;
    assign _84 = _79 & _83;
    assign _88 = _84 ? s2_uio : load_lo;
    assign _90 = running ? _23 : _88;
    assign _4 = _90;
    always @(posedge _18) begin
        if (_27)
            load_lo <= _23;
        else
            load_lo <= _4;
    end
    assign _6 = uio_in;
    always @(posedge _18) begin
        if (_27)
            s1_uio <= _23;
        else
            s1_uio <= _6;
    end
    always @(posedge _18) begin
        if (_27)
            s2_uio <= _23;
        else
            s2_uio <= s1_uio;
    end
    assign _170 = { s2_uio,
                    load_lo };
    assign _108 = 12'b000000000001;
    assign _109 = wait_cnt - _108;
    assign _111 = _107 ? _175 : _109;
    assign _100 = _60 - _108;
    assign _95 = _60 == _175;
    assign _96 = ~ _95;
    assign _93 = _40 == _173;
    assign _97 = _93 & _96;
    assign _101 = _97 ? _100 : _175;
    assign _112 = waiting ? _111 : _101;
    assign _113 = running ? _112 : _175;
    assign _7 = _113;
    always @(posedge _18) begin
        if (_27)
            wait_cnt <= _175;
        else
            wait_cnt <= _7;
    end
    assign _106 = wait_cnt == _175;
    assign _107 = waiting & _106;
    assign _145 = _107 ? _136 : pc;
    assign _124 = 8'b00000001;
    assign _61 = _60[7:0];
    assign _118 = 4'b0111;
    assign _119 = _40 == _118;
    assign _120 = _39 & _119;
    assign _126 = _120 ? _125 : lc;
    assign _115 = 4'b0110;
    assign _116 = _40 == _115;
    assign _117 = _39 & _116;
    assign _127 = _117 ? _61 : _126;
    assign _128 = running ? _127 : _23;
    assign _8 = _128;
    always @(posedge _18) begin
        if (_27)
            lc <= _23;
        else
            lc <= _8;
    end
    assign _125 = lc - _124;
    assign _141 = _125 == _23;
    assign _142 = ~ _141;
    assign _143 = _142 ? _131 : _136;
    assign _138 = _60 == _175;
    assign _139 = _138 ? _136 : pc;
    assign _135 = 6'b000001;
    assign _133 = 6'b000000;
    assign _130 = running ? _10 : _133;
    assign _9 = _130;
    always @(posedge _18) begin
        if (_27)
            pc <= _133;
        else
            pc <= _9;
    end
    assign _136 = pc + _135;
    assign _60 = _13[11:0];
    assign _131 = _60[5:0];
    always @* begin
        case (_40)
        0:
            _144 <= _131;
        1:
            _144 <= _136;
        2:
            _144 <= _136;
        3:
            _144 <= _136;
        4:
            _144 <= _136;
        5:
            _144 <= _139;
        6:
            _144 <= _136;
        7:
            _144 <= _143;
        default:
            _144 <= _136;
        endcase
    end
    assign next_pc = waiting ? _145 : _144;
    assign _10 = next_pc;
    assign _168 = _149 ? load_addr : _133;
    assign _169 = running ? _10 : _168;
    assign _154 = load_addr + _135;
    assign _155 = _149 ? _154 : load_addr;
    assign _157 = running ? _133 : _155;
    assign _11 = _157;
    always @(posedge _18) begin
        if (_27)
            load_addr <= _133;
        else
            load_addr <= _11;
    end
    assign _165 = load_addr == _133;
    assign _162 = ~ _149;
    assign _163 = running | _162;
    assign _166 = _163 | _165;
    assign _158 = ~ imem_write;
    assign _159 = _79 ? _158 : imem_write;
    assign _161 = running ? gnd : _159;
    assign _12 = _161;
    always @(posedge _18) begin
        if (_27)
            imem_write <= _63;
        else
            imem_write <= _12;
    end
    always @(posedge _18) begin
        if (_27)
            s3_wstb <= _63;
        else
            s3_wstb <= s2_wstb;
    end
    assign _78 = ~ s3_wstb;
    assign _68 = _20[6:6];
    always @(posedge _18) begin
        if (_27)
            s1_wstb <= _63;
        else
            s1_wstb <= _68;
    end
    always @(posedge _18) begin
        if (_27)
            s2_wstb <= _63;
        else
            s2_wstb <= s1_wstb;
    end
    assign _79 = s2_wstb & _78;
    assign _147 = ~ running;
    assign _148 = _147 & _79;
    assign _149 = _148 & imem_write;
    RM_IHPSG13_1P_64x16_c2
        u_imem
        ( .A_CLK(_18),
          .A_MEN(vdd),
          .A_WEN(_149),
          .A_REN(_166),
          .A_ADDR(_169),
          .A_DIN(_170),
          .A_DLY(vdd),
          .A_DOUT(_172[15:0]) );
    assign _13 = _172;
    assign _40 = _13[15:12];
    assign _174 = _40 == _173;
    assign _178 = _174 & _177;
    assign _180 = waiting ? _179 : _178;
    assign gnd = 1'b0;
    assign _181 = running ? _180 : gnd;
    assign _14 = _181;
    always @(posedge _18) begin
        if (_27)
            waiting <= _63;
        else
            waiting <= _14;
    end
    assign _38 = ~ waiting;
    assign _39 = running & _38;
    assign _185 = _39 & _184;
    assign _219 = _185 ? _61 : _218;
    assign vdd = 1'b1;
    assign _16 = rst_sync_n;
    assign _27 = ~ _16;
    assign _18 = clock;
    assign _20 = ui_in;
    assign _25 = _20[7:7];
    always @(posedge _18) begin
        if (_27)
            s1_run <= _63;
        else
            s1_run <= _25;
    end
    always @(posedge _18) begin
        if (_27)
            running <= _63;
        else
            running <= s1_run;
    end
    assign _220 = running ? _219 : _23;
    assign _21 = _220;
    always @(posedge _18) begin
        if (_27)
            out <= _23;
        else
            out <= _21;
    end
    assign load_hi = imem_write;
    assign s2_run = running;
    assign uo_out = out;
    assign uio_out = _23;
    assign uio_oe = _23;

endmodule
