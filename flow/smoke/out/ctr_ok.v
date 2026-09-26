module ctr (
    clock,
    bad
);

    input clock;
    output bad;

    wire vdd;
    wire [3:0] _5;
    wire [3:0] _10;
    wire [3:0] _11;
    wire [3:0] _8;
    wire _9;
    wire [3:0] _13;
    wire [3:0] _2;
    reg [3:0] _7;
    wire _15;
    assign vdd = 1'b1;
    assign _5 = 4'b0000;
    assign _10 = 4'b0001;
    assign _11 = _7 + _10;
    assign _8 = 4'b1001;
    assign _9 = _7 == _8;
    assign _13 = _9 ? _5 : _11;
    assign _2 = _13;
    always @(posedge clock) begin
        _7 <= _2;
    end
    assign _15 = _8 < _7;
    assign bad = _15;

endmodule
