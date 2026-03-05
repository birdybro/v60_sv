// v60_fpu.sv — DPI-C wrapper for V60 floating point unit
// Calls C++ v60_fp_exec() for IEEE 754 single-precision operations

/* verilator lint_off UNUSEDSIGNAL */
module v60_fpu
    import v60_pkg::*;
(
    input  fp_op_t      op,
    input  logic [31:0] a,
    input  logic [31:0] b,
    input  logic [2:0]  rounding,
    output logic [31:0] result,
    output logic        flag_z,
    output logic        flag_s,
    output logic        flag_ov,
    output logic        flag_cy
);

    import "DPI-C" function void v60_fp_exec(
        input int op,
        input int a,
        input int b,
        input int rounding,
        output int result,
        output byte unsigned fz,
        output byte unsigned fs,
        output byte unsigned fov,
        output byte unsigned fcy
    );

    int          dpi_result;
    byte unsigned dpi_fz, dpi_fs, dpi_fov, dpi_fcy;

    always_comb begin
        v60_fp_exec(
            int'(op), int'(a), int'(b), int'({29'd0, rounding}),
            dpi_result, dpi_fz, dpi_fs, dpi_fov, dpi_fcy
        );
        result  = dpi_result[31:0];
        flag_z  = dpi_fz[0];
        flag_s  = dpi_fs[0];
        flag_ov = dpi_fov[0];
        flag_cy = dpi_fcy[0];
    end

endmodule
