module pemu_core (
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

    wire [7:0] _22;
    wire [6:0] _489;
    wire _488;
    wire [7:0] _490;
    wire [3:0] _478;
    wire _479;
    wire _480;
    wire [7:0] _484;
    wire [3:0] _475;
    wire _476;
    wire _477;
    wire [7:0] _487;
    wire [3:0] _472;
    wire _473;
    wire _474;
    wire [7:0] _491;
    wire [7:0] _492;
    wire [7:0] _3;
    reg [7:0] sr;
    wire _604;
    wire [7:0] _606;
    wire _600;
    wire _599;
    wire _598;
    wire _596;
    wire _597;
    wire _594;
    wire _595;
    wire _591;
    wire _592;
    wire _593;
    wire _588;
    wire _589;
    wire _590;
    wire _585;
    wire _584;
    wire _586;
    wire [2:0] _582;
    wire _583;
    wire _587;
    wire [7:0] _601;
    wire [7:0] _602;
    wire [7:0] _603;
    wire [7:0] _607;
    wire _577;
    wire _578;
    wire [7:0] _608;
    wire [3:0] _573;
    wire _574;
    wire _569;
    wire [11:0] _565;
    wire _566;
    wire _567;
    wire [3:0] _563;
    wire _467;
    wire _468;
    wire [5:0] _463;
    wire _464;
    wire _461;
    wire _462;
    wire _465;
    wire _466;
    wire _469;
    wire [15:0] _460;
    wire [5:0] _453;
    wire _454;
    wire _455;
    reg [15:0] rtl_imem_63;
    wire [5:0] _447;
    wire _448;
    wire _449;
    reg [15:0] rtl_imem_62;
    wire [5:0] _441;
    wire _442;
    wire _443;
    reg [15:0] rtl_imem_61;
    wire [5:0] _435;
    wire _436;
    wire _437;
    reg [15:0] rtl_imem_60;
    wire [5:0] _429;
    wire _430;
    wire _431;
    reg [15:0] rtl_imem_59;
    wire [5:0] _423;
    wire _424;
    wire _425;
    reg [15:0] rtl_imem_58;
    wire [5:0] _417;
    wire _418;
    wire _419;
    reg [15:0] rtl_imem_57;
    wire [5:0] _411;
    wire _412;
    wire _413;
    reg [15:0] rtl_imem_56;
    wire [5:0] _405;
    wire _406;
    wire _407;
    reg [15:0] rtl_imem_55;
    wire [5:0] _399;
    wire _400;
    wire _401;
    reg [15:0] rtl_imem_54;
    wire [5:0] _393;
    wire _394;
    wire _395;
    reg [15:0] rtl_imem_53;
    wire [5:0] _387;
    wire _388;
    wire _389;
    reg [15:0] rtl_imem_52;
    wire [5:0] _381;
    wire _382;
    wire _383;
    reg [15:0] rtl_imem_51;
    wire [5:0] _375;
    wire _376;
    wire _377;
    reg [15:0] rtl_imem_50;
    wire [5:0] _369;
    wire _370;
    wire _371;
    reg [15:0] rtl_imem_49;
    wire [5:0] _363;
    wire _364;
    wire _365;
    reg [15:0] rtl_imem_48;
    wire [5:0] _357;
    wire _358;
    wire _359;
    reg [15:0] rtl_imem_47;
    wire [5:0] _351;
    wire _352;
    wire _353;
    reg [15:0] rtl_imem_46;
    wire [5:0] _345;
    wire _346;
    wire _347;
    reg [15:0] rtl_imem_45;
    wire [5:0] _339;
    wire _340;
    wire _341;
    reg [15:0] rtl_imem_44;
    wire [5:0] _333;
    wire _334;
    wire _335;
    reg [15:0] rtl_imem_43;
    wire [5:0] _327;
    wire _328;
    wire _329;
    reg [15:0] rtl_imem_42;
    wire [5:0] _321;
    wire _322;
    wire _323;
    reg [15:0] rtl_imem_41;
    wire [5:0] _315;
    wire _316;
    wire _317;
    reg [15:0] rtl_imem_40;
    wire [5:0] _309;
    wire _310;
    wire _311;
    reg [15:0] rtl_imem_39;
    wire [5:0] _303;
    wire _304;
    wire _305;
    reg [15:0] rtl_imem_38;
    wire [5:0] _297;
    wire _298;
    wire _299;
    reg [15:0] rtl_imem_37;
    wire [5:0] _291;
    wire _292;
    wire _293;
    reg [15:0] rtl_imem_36;
    wire [5:0] _285;
    wire _286;
    wire _287;
    reg [15:0] rtl_imem_35;
    wire [5:0] _279;
    wire _280;
    wire _281;
    reg [15:0] rtl_imem_34;
    wire [5:0] _273;
    wire _274;
    wire _275;
    reg [15:0] rtl_imem_33;
    wire [5:0] _267;
    wire _268;
    wire _269;
    reg [15:0] rtl_imem_32;
    wire [5:0] _261;
    wire _262;
    wire _263;
    reg [15:0] rtl_imem_31;
    wire [5:0] _255;
    wire _256;
    wire _257;
    reg [15:0] rtl_imem_30;
    wire [5:0] _249;
    wire _250;
    wire _251;
    reg [15:0] rtl_imem_29;
    wire [5:0] _243;
    wire _244;
    wire _245;
    reg [15:0] rtl_imem_28;
    wire [5:0] _237;
    wire _238;
    wire _239;
    reg [15:0] rtl_imem_27;
    wire [5:0] _231;
    wire _232;
    wire _233;
    reg [15:0] rtl_imem_26;
    wire [5:0] _225;
    wire _226;
    wire _227;
    reg [15:0] rtl_imem_25;
    wire [5:0] _219;
    wire _220;
    wire _221;
    reg [15:0] rtl_imem_24;
    wire [5:0] _213;
    wire _214;
    wire _215;
    reg [15:0] rtl_imem_23;
    wire [5:0] _207;
    wire _208;
    wire _209;
    reg [15:0] rtl_imem_22;
    wire [5:0] _201;
    wire _202;
    wire _203;
    reg [15:0] rtl_imem_21;
    wire [5:0] _195;
    wire _196;
    wire _197;
    reg [15:0] rtl_imem_20;
    wire [5:0] _189;
    wire _190;
    wire _191;
    reg [15:0] rtl_imem_19;
    wire [5:0] _183;
    wire _184;
    wire _185;
    reg [15:0] rtl_imem_18;
    wire [5:0] _177;
    wire _178;
    wire _179;
    reg [15:0] rtl_imem_17;
    wire [5:0] _171;
    wire _172;
    wire _173;
    reg [15:0] rtl_imem_16;
    wire [5:0] _165;
    wire _166;
    wire _167;
    reg [15:0] rtl_imem_15;
    wire [5:0] _159;
    wire _160;
    wire _161;
    reg [15:0] rtl_imem_14;
    wire [5:0] _153;
    wire _154;
    wire _155;
    reg [15:0] rtl_imem_13;
    wire [5:0] _147;
    wire _148;
    wire _149;
    reg [15:0] rtl_imem_12;
    wire [5:0] _141;
    wire _142;
    wire _143;
    reg [15:0] rtl_imem_11;
    wire [5:0] _135;
    wire _136;
    wire _137;
    reg [15:0] rtl_imem_10;
    wire [5:0] _129;
    wire _130;
    wire _131;
    reg [15:0] rtl_imem_9;
    wire [5:0] _123;
    wire _124;
    wire _125;
    reg [15:0] rtl_imem_8;
    wire [5:0] _117;
    wire _118;
    wire _119;
    reg [15:0] rtl_imem_7;
    wire [5:0] _111;
    wire _112;
    wire _113;
    reg [15:0] rtl_imem_6;
    wire [5:0] _105;
    wire _106;
    wire _107;
    reg [15:0] rtl_imem_5;
    wire [5:0] _99;
    wire _100;
    wire _101;
    reg [15:0] rtl_imem_4;
    wire [5:0] _93;
    wire _94;
    wire _95;
    reg [15:0] rtl_imem_3;
    wire [5:0] _87;
    wire _88;
    wire _89;
    reg [15:0] rtl_imem_2;
    wire [5:0] _81;
    wire _82;
    wire _83;
    reg [15:0] rtl_imem_1;
    wire _76;
    wire _77;
    wire _493;
    wire _494;
    wire [7:0] _495;
    wire [7:0] _497;
    wire [7:0] _4;
    reg [7:0] load_lo;
    wire [7:0] _6;
    reg [7:0] s1_uio;
    reg [7:0] s2_uio;
    wire [15:0] _72;
    reg [15:0] rtl_imem_0;
    wire [11:0] _515;
    wire [11:0] _516;
    wire [11:0] _518;
    wire [11:0] _507;
    wire _502;
    wire _503;
    wire _500;
    wire _504;
    wire [11:0] _508;
    wire [11:0] _519;
    wire [11:0] _520;
    wire [11:0] _7;
    reg [11:0] wait_cnt;
    wire _513;
    wire _514;
    wire [5:0] _552;
    wire [7:0] _531;
    wire [7:0] _486;
    wire [3:0] _525;
    wire _526;
    wire _527;
    wire [7:0] _533;
    wire [3:0] _522;
    wire _523;
    wire _524;
    wire [7:0] _534;
    wire [7:0] _535;
    wire [7:0] _8;
    reg [7:0] lc;
    wire [7:0] _532;
    wire _548;
    wire _549;
    wire [5:0] _550;
    wire _545;
    wire [5:0] _546;
    wire [5:0] _537;
    wire [5:0] _9;
    reg [5:0] pc;
    wire [5:0] _543;
    wire [11:0] _485;
    wire [5:0] _538;
    reg [5:0] _551;
    wire [5:0] next_pc;
    wire [5:0] _10;
    wire [5:0] _555;
    wire [5:0] _556;
    wire [5:0] _558;
    wire [5:0] _11;
    reg [5:0] load_addr;
    wire [5:0] _61;
    wire [5:0] _62;
    reg [15:0] _457;
    wire _559;
    wire _560;
    wire _562;
    wire _12;
    reg imem_write;
    wire load_hi;
    reg s3_wstb;
    wire _50;
    wire _40;
    reg s1_wstb;
    reg s2_wstb;
    wire _51;
    wire _39;
    wire _52;
    wire _56;
    wire [15:0] _458;
    reg [15:0] rtl_imem_dout;
    wire [3:0] _471;
    wire _564;
    wire _568;
    wire _570;
    wire gnd;
    wire _571;
    wire _13;
    reg waiting;
    wire _37;
    wire _38;
    wire _575;
    wire [7:0] _609;
    wire vdd;
    wire _15;
    wire _26;
    wire _17;
    wire [7:0] _19;
    wire _24;
    reg s1_run;
    reg running;
    wire s2_run;
    wire [7:0] _610;
    wire [7:0] _20;
    reg [7:0] out;
    assign _22 = 8'b00000000;
    assign _489 = sr[7:1];
    assign _488 = 1'b0;
    assign _490 = { _488,
                    _489 };
    assign _478 = 4'b0100;
    assign _479 = _471 == _478;
    assign _480 = _38 & _479;
    assign _484 = _480 ? s2_uio : sr;
    assign _475 = 4'b0011;
    assign _476 = _471 == _475;
    assign _477 = _38 & _476;
    assign _487 = _477 ? _486 : _484;
    assign _472 = 4'b0010;
    assign _473 = _471 == _472;
    assign _474 = _38 & _473;
    assign _491 = _474 ? _490 : _487;
    assign _492 = running ? _491 : _22;
    assign _3 = _492;
    always @(posedge _17) begin
        if (_26)
            sr <= _22;
        else
            sr <= _3;
    end
    assign _604 = sr[0:0];
    assign _606 = _604 ? _601 : _22;
    assign _600 = _596 & _594;
    assign _599 = _596 & _592;
    assign _598 = _596 & _589;
    assign _596 = ~ _583;
    assign _597 = _596 & _586;
    assign _594 = _591 & _588;
    assign _595 = _583 & _594;
    assign _591 = ~ _584;
    assign _592 = _591 & _585;
    assign _593 = _583 & _592;
    assign _588 = ~ _585;
    assign _589 = _584 & _588;
    assign _590 = _583 & _589;
    assign _585 = _582[0:0];
    assign _584 = _582[1:1];
    assign _586 = _584 & _585;
    assign _582 = _485[2:0];
    assign _583 = _582[2:2];
    assign _587 = _583 & _586;
    assign _601 = { _587,
                    _590,
                    _593,
                    _595,
                    _597,
                    _598,
                    _599,
                    _600 };
    assign _602 = ~ _601;
    assign _603 = out & _602;
    assign _607 = _603 | _606;
    assign _577 = _471 == _472;
    assign _578 = _38 & _577;
    assign _608 = _578 ? _607 : out;
    assign _573 = 4'b0001;
    assign _574 = _471 == _573;
    assign _569 = ~ _514;
    assign _565 = 12'b000000000000;
    assign _566 = _485 == _565;
    assign _567 = ~ _566;
    assign _563 = 4'b0101;
    assign _467 = ~ _56;
    assign _468 = _467 & _465;
    assign _463 = 6'b000000;
    assign _464 = load_addr == _463;
    assign _461 = ~ _56;
    assign _462 = running | _461;
    assign _465 = _462 | _464;
    assign _466 = _56 & _465;
    assign _469 = _466 | _468;
    assign _460 = 16'b0000000000000000;
    assign _453 = 6'b111111;
    assign _454 = _62 == _453;
    assign _455 = _56 & _454;
    always @(posedge _17) begin
        if (_455)
            rtl_imem_63 <= _72;
    end
    assign _447 = 6'b111110;
    assign _448 = _62 == _447;
    assign _449 = _56 & _448;
    always @(posedge _17) begin
        if (_449)
            rtl_imem_62 <= _72;
    end
    assign _441 = 6'b111101;
    assign _442 = _62 == _441;
    assign _443 = _56 & _442;
    always @(posedge _17) begin
        if (_443)
            rtl_imem_61 <= _72;
    end
    assign _435 = 6'b111100;
    assign _436 = _62 == _435;
    assign _437 = _56 & _436;
    always @(posedge _17) begin
        if (_437)
            rtl_imem_60 <= _72;
    end
    assign _429 = 6'b111011;
    assign _430 = _62 == _429;
    assign _431 = _56 & _430;
    always @(posedge _17) begin
        if (_431)
            rtl_imem_59 <= _72;
    end
    assign _423 = 6'b111010;
    assign _424 = _62 == _423;
    assign _425 = _56 & _424;
    always @(posedge _17) begin
        if (_425)
            rtl_imem_58 <= _72;
    end
    assign _417 = 6'b111001;
    assign _418 = _62 == _417;
    assign _419 = _56 & _418;
    always @(posedge _17) begin
        if (_419)
            rtl_imem_57 <= _72;
    end
    assign _411 = 6'b111000;
    assign _412 = _62 == _411;
    assign _413 = _56 & _412;
    always @(posedge _17) begin
        if (_413)
            rtl_imem_56 <= _72;
    end
    assign _405 = 6'b110111;
    assign _406 = _62 == _405;
    assign _407 = _56 & _406;
    always @(posedge _17) begin
        if (_407)
            rtl_imem_55 <= _72;
    end
    assign _399 = 6'b110110;
    assign _400 = _62 == _399;
    assign _401 = _56 & _400;
    always @(posedge _17) begin
        if (_401)
            rtl_imem_54 <= _72;
    end
    assign _393 = 6'b110101;
    assign _394 = _62 == _393;
    assign _395 = _56 & _394;
    always @(posedge _17) begin
        if (_395)
            rtl_imem_53 <= _72;
    end
    assign _387 = 6'b110100;
    assign _388 = _62 == _387;
    assign _389 = _56 & _388;
    always @(posedge _17) begin
        if (_389)
            rtl_imem_52 <= _72;
    end
    assign _381 = 6'b110011;
    assign _382 = _62 == _381;
    assign _383 = _56 & _382;
    always @(posedge _17) begin
        if (_383)
            rtl_imem_51 <= _72;
    end
    assign _375 = 6'b110010;
    assign _376 = _62 == _375;
    assign _377 = _56 & _376;
    always @(posedge _17) begin
        if (_377)
            rtl_imem_50 <= _72;
    end
    assign _369 = 6'b110001;
    assign _370 = _62 == _369;
    assign _371 = _56 & _370;
    always @(posedge _17) begin
        if (_371)
            rtl_imem_49 <= _72;
    end
    assign _363 = 6'b110000;
    assign _364 = _62 == _363;
    assign _365 = _56 & _364;
    always @(posedge _17) begin
        if (_365)
            rtl_imem_48 <= _72;
    end
    assign _357 = 6'b101111;
    assign _358 = _62 == _357;
    assign _359 = _56 & _358;
    always @(posedge _17) begin
        if (_359)
            rtl_imem_47 <= _72;
    end
    assign _351 = 6'b101110;
    assign _352 = _62 == _351;
    assign _353 = _56 & _352;
    always @(posedge _17) begin
        if (_353)
            rtl_imem_46 <= _72;
    end
    assign _345 = 6'b101101;
    assign _346 = _62 == _345;
    assign _347 = _56 & _346;
    always @(posedge _17) begin
        if (_347)
            rtl_imem_45 <= _72;
    end
    assign _339 = 6'b101100;
    assign _340 = _62 == _339;
    assign _341 = _56 & _340;
    always @(posedge _17) begin
        if (_341)
            rtl_imem_44 <= _72;
    end
    assign _333 = 6'b101011;
    assign _334 = _62 == _333;
    assign _335 = _56 & _334;
    always @(posedge _17) begin
        if (_335)
            rtl_imem_43 <= _72;
    end
    assign _327 = 6'b101010;
    assign _328 = _62 == _327;
    assign _329 = _56 & _328;
    always @(posedge _17) begin
        if (_329)
            rtl_imem_42 <= _72;
    end
    assign _321 = 6'b101001;
    assign _322 = _62 == _321;
    assign _323 = _56 & _322;
    always @(posedge _17) begin
        if (_323)
            rtl_imem_41 <= _72;
    end
    assign _315 = 6'b101000;
    assign _316 = _62 == _315;
    assign _317 = _56 & _316;
    always @(posedge _17) begin
        if (_317)
            rtl_imem_40 <= _72;
    end
    assign _309 = 6'b100111;
    assign _310 = _62 == _309;
    assign _311 = _56 & _310;
    always @(posedge _17) begin
        if (_311)
            rtl_imem_39 <= _72;
    end
    assign _303 = 6'b100110;
    assign _304 = _62 == _303;
    assign _305 = _56 & _304;
    always @(posedge _17) begin
        if (_305)
            rtl_imem_38 <= _72;
    end
    assign _297 = 6'b100101;
    assign _298 = _62 == _297;
    assign _299 = _56 & _298;
    always @(posedge _17) begin
        if (_299)
            rtl_imem_37 <= _72;
    end
    assign _291 = 6'b100100;
    assign _292 = _62 == _291;
    assign _293 = _56 & _292;
    always @(posedge _17) begin
        if (_293)
            rtl_imem_36 <= _72;
    end
    assign _285 = 6'b100011;
    assign _286 = _62 == _285;
    assign _287 = _56 & _286;
    always @(posedge _17) begin
        if (_287)
            rtl_imem_35 <= _72;
    end
    assign _279 = 6'b100010;
    assign _280 = _62 == _279;
    assign _281 = _56 & _280;
    always @(posedge _17) begin
        if (_281)
            rtl_imem_34 <= _72;
    end
    assign _273 = 6'b100001;
    assign _274 = _62 == _273;
    assign _275 = _56 & _274;
    always @(posedge _17) begin
        if (_275)
            rtl_imem_33 <= _72;
    end
    assign _267 = 6'b100000;
    assign _268 = _62 == _267;
    assign _269 = _56 & _268;
    always @(posedge _17) begin
        if (_269)
            rtl_imem_32 <= _72;
    end
    assign _261 = 6'b011111;
    assign _262 = _62 == _261;
    assign _263 = _56 & _262;
    always @(posedge _17) begin
        if (_263)
            rtl_imem_31 <= _72;
    end
    assign _255 = 6'b011110;
    assign _256 = _62 == _255;
    assign _257 = _56 & _256;
    always @(posedge _17) begin
        if (_257)
            rtl_imem_30 <= _72;
    end
    assign _249 = 6'b011101;
    assign _250 = _62 == _249;
    assign _251 = _56 & _250;
    always @(posedge _17) begin
        if (_251)
            rtl_imem_29 <= _72;
    end
    assign _243 = 6'b011100;
    assign _244 = _62 == _243;
    assign _245 = _56 & _244;
    always @(posedge _17) begin
        if (_245)
            rtl_imem_28 <= _72;
    end
    assign _237 = 6'b011011;
    assign _238 = _62 == _237;
    assign _239 = _56 & _238;
    always @(posedge _17) begin
        if (_239)
            rtl_imem_27 <= _72;
    end
    assign _231 = 6'b011010;
    assign _232 = _62 == _231;
    assign _233 = _56 & _232;
    always @(posedge _17) begin
        if (_233)
            rtl_imem_26 <= _72;
    end
    assign _225 = 6'b011001;
    assign _226 = _62 == _225;
    assign _227 = _56 & _226;
    always @(posedge _17) begin
        if (_227)
            rtl_imem_25 <= _72;
    end
    assign _219 = 6'b011000;
    assign _220 = _62 == _219;
    assign _221 = _56 & _220;
    always @(posedge _17) begin
        if (_221)
            rtl_imem_24 <= _72;
    end
    assign _213 = 6'b010111;
    assign _214 = _62 == _213;
    assign _215 = _56 & _214;
    always @(posedge _17) begin
        if (_215)
            rtl_imem_23 <= _72;
    end
    assign _207 = 6'b010110;
    assign _208 = _62 == _207;
    assign _209 = _56 & _208;
    always @(posedge _17) begin
        if (_209)
            rtl_imem_22 <= _72;
    end
    assign _201 = 6'b010101;
    assign _202 = _62 == _201;
    assign _203 = _56 & _202;
    always @(posedge _17) begin
        if (_203)
            rtl_imem_21 <= _72;
    end
    assign _195 = 6'b010100;
    assign _196 = _62 == _195;
    assign _197 = _56 & _196;
    always @(posedge _17) begin
        if (_197)
            rtl_imem_20 <= _72;
    end
    assign _189 = 6'b010011;
    assign _190 = _62 == _189;
    assign _191 = _56 & _190;
    always @(posedge _17) begin
        if (_191)
            rtl_imem_19 <= _72;
    end
    assign _183 = 6'b010010;
    assign _184 = _62 == _183;
    assign _185 = _56 & _184;
    always @(posedge _17) begin
        if (_185)
            rtl_imem_18 <= _72;
    end
    assign _177 = 6'b010001;
    assign _178 = _62 == _177;
    assign _179 = _56 & _178;
    always @(posedge _17) begin
        if (_179)
            rtl_imem_17 <= _72;
    end
    assign _171 = 6'b010000;
    assign _172 = _62 == _171;
    assign _173 = _56 & _172;
    always @(posedge _17) begin
        if (_173)
            rtl_imem_16 <= _72;
    end
    assign _165 = 6'b001111;
    assign _166 = _62 == _165;
    assign _167 = _56 & _166;
    always @(posedge _17) begin
        if (_167)
            rtl_imem_15 <= _72;
    end
    assign _159 = 6'b001110;
    assign _160 = _62 == _159;
    assign _161 = _56 & _160;
    always @(posedge _17) begin
        if (_161)
            rtl_imem_14 <= _72;
    end
    assign _153 = 6'b001101;
    assign _154 = _62 == _153;
    assign _155 = _56 & _154;
    always @(posedge _17) begin
        if (_155)
            rtl_imem_13 <= _72;
    end
    assign _147 = 6'b001100;
    assign _148 = _62 == _147;
    assign _149 = _56 & _148;
    always @(posedge _17) begin
        if (_149)
            rtl_imem_12 <= _72;
    end
    assign _141 = 6'b001011;
    assign _142 = _62 == _141;
    assign _143 = _56 & _142;
    always @(posedge _17) begin
        if (_143)
            rtl_imem_11 <= _72;
    end
    assign _135 = 6'b001010;
    assign _136 = _62 == _135;
    assign _137 = _56 & _136;
    always @(posedge _17) begin
        if (_137)
            rtl_imem_10 <= _72;
    end
    assign _129 = 6'b001001;
    assign _130 = _62 == _129;
    assign _131 = _56 & _130;
    always @(posedge _17) begin
        if (_131)
            rtl_imem_9 <= _72;
    end
    assign _123 = 6'b001000;
    assign _124 = _62 == _123;
    assign _125 = _56 & _124;
    always @(posedge _17) begin
        if (_125)
            rtl_imem_8 <= _72;
    end
    assign _117 = 6'b000111;
    assign _118 = _62 == _117;
    assign _119 = _56 & _118;
    always @(posedge _17) begin
        if (_119)
            rtl_imem_7 <= _72;
    end
    assign _111 = 6'b000110;
    assign _112 = _62 == _111;
    assign _113 = _56 & _112;
    always @(posedge _17) begin
        if (_113)
            rtl_imem_6 <= _72;
    end
    assign _105 = 6'b000101;
    assign _106 = _62 == _105;
    assign _107 = _56 & _106;
    always @(posedge _17) begin
        if (_107)
            rtl_imem_5 <= _72;
    end
    assign _99 = 6'b000100;
    assign _100 = _62 == _99;
    assign _101 = _56 & _100;
    always @(posedge _17) begin
        if (_101)
            rtl_imem_4 <= _72;
    end
    assign _93 = 6'b000011;
    assign _94 = _62 == _93;
    assign _95 = _56 & _94;
    always @(posedge _17) begin
        if (_95)
            rtl_imem_3 <= _72;
    end
    assign _87 = 6'b000010;
    assign _88 = _62 == _87;
    assign _89 = _56 & _88;
    always @(posedge _17) begin
        if (_89)
            rtl_imem_2 <= _72;
    end
    assign _81 = 6'b000001;
    assign _82 = _62 == _81;
    assign _83 = _56 & _82;
    always @(posedge _17) begin
        if (_83)
            rtl_imem_1 <= _72;
    end
    assign _76 = _62 == _463;
    assign _77 = _56 & _76;
    assign _493 = ~ imem_write;
    assign _494 = _51 & _493;
    assign _495 = _494 ? s2_uio : load_lo;
    assign _497 = running ? _22 : _495;
    assign _4 = _497;
    always @(posedge _17) begin
        if (_26)
            load_lo <= _22;
        else
            load_lo <= _4;
    end
    assign _6 = uio_in;
    always @(posedge _17) begin
        if (_26)
            s1_uio <= _22;
        else
            s1_uio <= _6;
    end
    always @(posedge _17) begin
        if (_26)
            s2_uio <= _22;
        else
            s2_uio <= s1_uio;
    end
    assign _72 = { s2_uio,
                   load_lo };
    always @(posedge _17) begin
        if (_77)
            rtl_imem_0 <= _72;
    end
    assign _515 = 12'b000000000001;
    assign _516 = wait_cnt - _515;
    assign _518 = _514 ? _565 : _516;
    assign _507 = _485 - _515;
    assign _502 = _485 == _565;
    assign _503 = ~ _502;
    assign _500 = _471 == _563;
    assign _504 = _500 & _503;
    assign _508 = _504 ? _507 : _565;
    assign _519 = waiting ? _518 : _508;
    assign _520 = running ? _519 : _565;
    assign _7 = _520;
    always @(posedge _17) begin
        if (_26)
            wait_cnt <= _565;
        else
            wait_cnt <= _7;
    end
    assign _513 = wait_cnt == _565;
    assign _514 = waiting & _513;
    assign _552 = _514 ? _543 : pc;
    assign _531 = 8'b00000001;
    assign _486 = _485[7:0];
    assign _525 = 4'b0111;
    assign _526 = _471 == _525;
    assign _527 = _38 & _526;
    assign _533 = _527 ? _532 : lc;
    assign _522 = 4'b0110;
    assign _523 = _471 == _522;
    assign _524 = _38 & _523;
    assign _534 = _524 ? _486 : _533;
    assign _535 = running ? _534 : _22;
    assign _8 = _535;
    always @(posedge _17) begin
        if (_26)
            lc <= _22;
        else
            lc <= _8;
    end
    assign _532 = lc - _531;
    assign _548 = _532 == _22;
    assign _549 = ~ _548;
    assign _550 = _549 ? _538 : _543;
    assign _545 = _485 == _565;
    assign _546 = _545 ? _543 : pc;
    assign _537 = running ? _10 : _463;
    assign _9 = _537;
    always @(posedge _17) begin
        if (_26)
            pc <= _463;
        else
            pc <= _9;
    end
    assign _543 = pc + _81;
    assign _485 = rtl_imem_dout[11:0];
    assign _538 = _485[5:0];
    always @* begin
        case (_471)
        0:
            _551 <= _538;
        1:
            _551 <= _543;
        2:
            _551 <= _543;
        3:
            _551 <= _543;
        4:
            _551 <= _543;
        5:
            _551 <= _546;
        6:
            _551 <= _543;
        7:
            _551 <= _550;
        default:
            _551 <= _543;
        endcase
    end
    assign next_pc = waiting ? _552 : _551;
    assign _10 = next_pc;
    assign _555 = load_addr + _81;
    assign _556 = _56 ? _555 : load_addr;
    assign _558 = running ? _463 : _556;
    assign _11 = _558;
    always @(posedge _17) begin
        if (_26)
            load_addr <= _463;
        else
            load_addr <= _11;
    end
    assign _61 = _56 ? load_addr : _463;
    assign _62 = running ? _10 : _61;
    always @* begin
        case (_62)
        0:
            _457 <= rtl_imem_0;
        1:
            _457 <= rtl_imem_1;
        2:
            _457 <= rtl_imem_2;
        3:
            _457 <= rtl_imem_3;
        4:
            _457 <= rtl_imem_4;
        5:
            _457 <= rtl_imem_5;
        6:
            _457 <= rtl_imem_6;
        7:
            _457 <= rtl_imem_7;
        8:
            _457 <= rtl_imem_8;
        9:
            _457 <= rtl_imem_9;
        10:
            _457 <= rtl_imem_10;
        11:
            _457 <= rtl_imem_11;
        12:
            _457 <= rtl_imem_12;
        13:
            _457 <= rtl_imem_13;
        14:
            _457 <= rtl_imem_14;
        15:
            _457 <= rtl_imem_15;
        16:
            _457 <= rtl_imem_16;
        17:
            _457 <= rtl_imem_17;
        18:
            _457 <= rtl_imem_18;
        19:
            _457 <= rtl_imem_19;
        20:
            _457 <= rtl_imem_20;
        21:
            _457 <= rtl_imem_21;
        22:
            _457 <= rtl_imem_22;
        23:
            _457 <= rtl_imem_23;
        24:
            _457 <= rtl_imem_24;
        25:
            _457 <= rtl_imem_25;
        26:
            _457 <= rtl_imem_26;
        27:
            _457 <= rtl_imem_27;
        28:
            _457 <= rtl_imem_28;
        29:
            _457 <= rtl_imem_29;
        30:
            _457 <= rtl_imem_30;
        31:
            _457 <= rtl_imem_31;
        32:
            _457 <= rtl_imem_32;
        33:
            _457 <= rtl_imem_33;
        34:
            _457 <= rtl_imem_34;
        35:
            _457 <= rtl_imem_35;
        36:
            _457 <= rtl_imem_36;
        37:
            _457 <= rtl_imem_37;
        38:
            _457 <= rtl_imem_38;
        39:
            _457 <= rtl_imem_39;
        40:
            _457 <= rtl_imem_40;
        41:
            _457 <= rtl_imem_41;
        42:
            _457 <= rtl_imem_42;
        43:
            _457 <= rtl_imem_43;
        44:
            _457 <= rtl_imem_44;
        45:
            _457 <= rtl_imem_45;
        46:
            _457 <= rtl_imem_46;
        47:
            _457 <= rtl_imem_47;
        48:
            _457 <= rtl_imem_48;
        49:
            _457 <= rtl_imem_49;
        50:
            _457 <= rtl_imem_50;
        51:
            _457 <= rtl_imem_51;
        52:
            _457 <= rtl_imem_52;
        53:
            _457 <= rtl_imem_53;
        54:
            _457 <= rtl_imem_54;
        55:
            _457 <= rtl_imem_55;
        56:
            _457 <= rtl_imem_56;
        57:
            _457 <= rtl_imem_57;
        58:
            _457 <= rtl_imem_58;
        59:
            _457 <= rtl_imem_59;
        60:
            _457 <= rtl_imem_60;
        61:
            _457 <= rtl_imem_61;
        62:
            _457 <= rtl_imem_62;
        default:
            _457 <= rtl_imem_63;
        endcase
    end
    assign _559 = ~ imem_write;
    assign _560 = _51 ? _559 : imem_write;
    assign _562 = running ? gnd : _560;
    assign _12 = _562;
    always @(posedge _17) begin
        if (_26)
            imem_write <= _488;
        else
            imem_write <= _12;
    end
    always @(posedge _17) begin
        if (_26)
            s3_wstb <= _488;
        else
            s3_wstb <= s2_wstb;
    end
    assign _50 = ~ s3_wstb;
    assign _40 = _19[6:6];
    always @(posedge _17) begin
        if (_26)
            s1_wstb <= _488;
        else
            s1_wstb <= _40;
    end
    always @(posedge _17) begin
        if (_26)
            s2_wstb <= _488;
        else
            s2_wstb <= s1_wstb;
    end
    assign _51 = s2_wstb & _50;
    assign _39 = ~ running;
    assign _52 = _39 & _51;
    assign _56 = _52 & imem_write;
    assign _458 = _56 ? _72 : _457;
    always @(posedge _17) begin
        if (_469)
            rtl_imem_dout <= _458;
    end
    assign _471 = rtl_imem_dout[15:12];
    assign _564 = _471 == _563;
    assign _568 = _564 & _567;
    assign _570 = waiting ? _569 : _568;
    assign gnd = 1'b0;
    assign _571 = running ? _570 : gnd;
    assign _13 = _571;
    always @(posedge _17) begin
        if (_26)
            waiting <= _488;
        else
            waiting <= _13;
    end
    assign _37 = ~ waiting;
    assign _38 = running & _37;
    assign _575 = _38 & _574;
    assign _609 = _575 ? _486 : _608;
    assign vdd = 1'b1;
    assign _15 = rst_sync_n;
    assign _26 = ~ _15;
    assign _17 = clock;
    assign _19 = ui_in;
    assign _24 = _19[7:7];
    always @(posedge _17) begin
        if (_26)
            s1_run <= _488;
        else
            s1_run <= _24;
    end
    always @(posedge _17) begin
        if (_26)
            running <= _488;
        else
            running <= s1_run;
    end
    assign _610 = running ? _609 : _22;
    assign _20 = _610;
    always @(posedge _17) begin
        if (_26)
            out <= _22;
        else
            out <= _20;
    end
    assign load_hi = imem_write;
    assign s2_run = running;
    assign uo_out = out;
    assign uio_out = _22;
    assign uio_oe = _22;

endmodule
