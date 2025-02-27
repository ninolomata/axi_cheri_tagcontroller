// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Wolfgang Roenninger <wroennin@iis.ee.ethz.ch>
// Date:   20.05.2019

/// Implements one Way/Set of the cache and controls the memory macro where the
/// cached data is stored in. From the `way_inp` struct it determines what action
/// should be performed on the macro. The module answers with read output and the
/// enum of the module, which made the read request. The module is able to stall
/// if the read is not consumed the cycle it is made.
`include "common_cells/registers.svh"
module axi_tagctrl_data_way #(
    /// Static AXI LLC configuration
    parameter axi_llc_pkg::llc_cfg_t Cfg = axi_llc_pkg::llc_cfg_t'{default: '0},
    /// Static LLC AXI configuration parameters.
    parameter axi_llc_pkg::llc_axi_cfg_t AxiCfg = axi_llc_pkg::llc_axi_cfg_t'{default: '0},
    /// The input struct has to be defined as follows (is done in `axi_llc_top`):
    /// typedef struct packed {
    ///   axi_axi_llc_pkg::cache_unit_e     cache_unit;   // which unit does the access
    ///   logic [Cfg.SetAssociativity -1:0] way_ind;      // to which way the access goes
    ///   logic [Cfg.IndexLength      -1:0] line_addr;    // cache line address
    ///   logic [Cfg.BlockOffsetLength-1:0] blk_offset;   // block offset
    ///   logic                             we;           // write enable
    ///   axi_data_t                        data;         // write data to the macro
    ///   axi_strb_t                        strb;         // write enable (AXI strb)
    /// } way_inp_t;
    parameter type way_inp_t = logic,
    /// The output struct has to be defined as follows (is done in `axi_llc_top`):
    /// typedef struct packed {
    ///   axi_axi_llc_pkg::cache_unit_e cache_unit;   // which unit had the access
    ///   axi_data_t                    data;         // read data from the macro
    /// } way_oup_t;
    parameter type way_oup_t = logic,
    /// Whether to print SRAM configs.
    parameter bit PrintSramCfg = 0
) (
    /// Clock, positive edge triggered
    input logic clk_i,
    /// Asynchronous reset active low
    input logic rst_ni,
    /// Testmode enable
    input logic test_i,
    /// Data way request input
    input way_inp_t inp_i,
    /// Request is valid
    input logic inp_valid_i,
    /// Module is ready to handle a request
    output logic inp_ready_o,
    /// Output is read data, has routing information, which unit made an access.
    output way_oup_t out_o,
    /// Output is valid.
    output logic out_valid_o,
    /// Downstream is ready for output.
    input logic out_ready_i
);
  // local typedefs
  typedef logic [(AxiCfg.DataWidthFull/8)-1:0] strb_t;
  typedef logic [AxiCfg.DataWidthFull-1:0] data_t;
  // The number of lines of each data SRAM macro
  localparam int unsigned SRamAddrWidth = Cfg.IndexLength + Cfg.BlockOffsetLength;

  // SRAM control signals
  logic [SRamAddrWidth-1:0] addr;  // true macro address
  logic                     ram_req;  // request to the macro

  // flip-flops to know when the output data is valid on a read request
  logic outp_valid_d, outp_valid_q;
  axi_llc_pkg::cache_unit_e cache_unit_d, cache_unit_q;
  logic load_unit, load_valid;

  // flip-flops for the write operation
  logic [SRamAddrWidth-1:0] wr_addr_d, wr_addr_q;
  data_t wr_data_d, wr_data_q;
  strb_t wr_strb_d, wr_strb_q;
  data_t wr_bit_en_d, wr_bit_en_q;
  logic wr_en_d, wr_en_q;
  logic ram_req_d, ram_req_q;
  logic load_wr_addr, load_wr_data, load_wr_strb, load_wr_bit_en, load_wr_en, load_ram_req;

  // concatenate the line address (index) and block offset to get the true address
  assign addr             = {inp_i.line_addr, inp_i.blk_offset};

  //----------------------------------------------------------
  // Control
  //----------------------------------------------------------
  assign out_o.cache_unit = cache_unit_q;  // for the data demux in the module `axi_llc_ways`
  assign out_valid_o      = outp_valid_q;

  // control of the data way, handles the handshaking and macro signals
  always_comb begin
    // default assignments
    cache_unit_d = cache_unit_q;
    load_unit    = 1'b0;
    outp_valid_d = outp_valid_q;
    load_valid   = 1'b0;
    ram_req      = 1'b0;
    // module handshakes for the input
    inp_ready_o  = 1'b0;
    if (outp_valid_q) begin
      // valid output from the SRAM, wait for handshake
      if (out_ready_i) begin
        // we update `outp_valid_d` anyway
        load_valid = 1'b1;
        // what value gets written depends on if there is another sram request
        if (inp_valid_i) begin
          // we can handle the new input
          inp_ready_o  = 1'b1;
          cache_unit_d = inp_i.cache_unit;
          load_unit    = 1'b1;
          outp_valid_d = ~inp_i.we;
          ram_req      = 1'b1;
        end else begin
          outp_valid_d = 1'b0;
        end
      end
    end else begin
      // we are able to handle a request to the sram
      inp_ready_o = wr_en_q ? 1'b0 : 1'b1;
      if (inp_valid_i && !wr_en_q) begin
        // load the registers and request to the sram
        cache_unit_d = inp_i.cache_unit;
        load_unit    = 1'b1;
        outp_valid_d = ~inp_i.we;
        load_valid   = 1'b1;
        ram_req      = 1'b1;
      end
    end
  end

  // control the write operation we need granularity at the bit level so the operation is
  // a ready-modify-write process
  always_comb begin : write_proc
    //default assignments
    wr_addr_d = wr_addr_q;
    load_wr_addr = 1'b0;
    wr_data_d = wr_data_q;
    load_wr_addr = 1'b0;
    wr_strb_d = wr_strb_q;
    load_wr_strb = 1'b0;
    wr_bit_en_d = wr_bit_en_q;
    load_wr_bit_en = 1'b0;
    wr_en_d = 1'b0;
    load_wr_en = 1'b0;
    ram_req_d = 1'b0;
    load_ram_req = 1'b0;

    // if input valid and is a write operation
    if (inp_valid_i && inp_i.we && inp_ready_o) begin
      wr_addr_d = addr;
      load_wr_addr = 1'b1;
      wr_data_d = inp_i.data;
      load_wr_data = 1'b1;
      wr_strb_d = inp_i.strb;
      load_wr_strb = 1'b1;
      wr_bit_en_d = inp_i.bit_en;
      load_wr_bit_en = 1'b1;
      wr_en_d = inp_i.we;
      load_wr_en = 1'b1;
      ram_req_d = ram_req;
      load_ram_req = 1'b1;
    end else begin
      wr_en_d = 1'b0;
      load_wr_en = 1'b1;
      wr_addr_d = 0;
      load_wr_addr = 1'b1;
      wr_data_d = 0;
      load_wr_data = 1'b1;
      wr_strb_d = 0;
      load_wr_strb = 1'b1;
      wr_bit_en_d = 0;
      load_wr_bit_en = 1'b1;
      wr_en_d = 0;
      load_wr_en = 1'b1;
      ram_req_d = 0;
      load_ram_req = 1'b1;
    end

  end

  tc_sram #(
      .NumWords   (Cfg.NumLines * Cfg.NumBlocks),
      .DataWidth  (Cfg.BlockSize),
      .ByteWidth  (32'd8),
      .NumPorts   (32'd1),
      .Latency    (32'd1),
      .SimInit    ("none"),
      .PrintSimCfg(PrintSramCfg)
  ) i_data_sram (
      .clk_i,
      .rst_ni,
      .req_i  (wr_en_q ? ram_req_q : ram_req),
      .we_i   (wr_en_q),
      .addr_i (wr_en_q ? wr_addr_q : addr),
      .wdata_i(wr_en_q ? ((out_o.data & ~wr_bit_en_q) | wr_data_q) : inp_i.data),
      .be_i   (wr_en_q ? wr_strb_q : inp_i.strb),
      .rdata_o(out_o.data)
  );

  // Flip Flops to hold the read request meta information
  `FFLARN(outp_valid_q, outp_valid_d, load_valid, '0, clk_i, rst_ni)
  `FFLARN(cache_unit_q, cache_unit_d, load_unit, axi_llc_pkg::EvictUnit, clk_i, rst_ni)
  `FFLARN(wr_addr_q, wr_addr_d, load_wr_addr, '0, clk_i, rst_ni)
  `FFLARN(wr_data_q, wr_data_d, load_wr_data, '0, clk_i, rst_ni)
  `FFLARN(wr_strb_q, wr_strb_d, load_wr_strb, '0, clk_i, rst_ni)
  `FFLARN(wr_bit_en_q, wr_bit_en_d, load_wr_bit_en, '0, clk_i, rst_ni)
  `FFLARN(wr_en_q, wr_en_d, load_wr_en, '0, clk_i, rst_ni)
  `FFLARN(ram_req_q, ram_req_d, load_ram_req, '0, clk_i, rst_ni)

  // pragma translate_off
`ifndef VERILATOR
  initial begin
    assert (axi_llc_pkg::DataMacroLatency == 32'd1)
    else $fatal(1, "Currently only support axi_llc_pkg::DataMacroLatency == 32'd1");
  end
`endif
  // pragma translate_on
endmodule
