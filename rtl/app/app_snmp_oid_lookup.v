// OID table is deliberately parameterized: final enterprise OIDs are TBD.
// Each OID is left-aligned in its 128-bit parameter; zero length disables it.
module app_snmp_oid_lookup #(
    parameter integer OID0_LEN = 0,
    parameter [127:0] OID0_DATA = 0,
    parameter integer OID1_LEN = 0,
    parameter [127:0] OID1_DATA = 0,
    parameter integer OID2_LEN = 0,
    parameter [127:0] OID2_DATA = 0
) (
    input wire [7:0] oid_len,
    input wire [127:0] oid_data,
    output reg found,
    output reg [1:0] object_id,
    output reg writable,
    output reg [7:0] value_tag
);
    // 匹配启用的 OID，并返回对象编号、写权限和 BER 类型。
    always @* begin
        found = 0;
        object_id = 0;
        writable = 0;
        value_tag = 8'h02;
        if (OID0_LEN != 0 && oid_len == OID0_LEN && oid_data == OID0_DATA) begin
            found = 1;
            object_id = 0;
            writable = 0;
            value_tag = 8'h02;
        end else if (OID1_LEN != 0 && oid_len == OID1_LEN && oid_data == OID1_DATA) begin
            found = 1;
            object_id = 1;
            writable = 0;
            value_tag = 8'h41;
        end else if (OID2_LEN != 0 && oid_len == OID2_LEN && oid_data == OID2_DATA) begin
            found = 1;
            object_id = 2;
            writable = 1;
            value_tag = 8'h02;
        end
    end
endmodule
