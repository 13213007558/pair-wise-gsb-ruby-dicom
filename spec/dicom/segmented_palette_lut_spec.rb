# encoding: UTF-8

require 'spec_helper'


module DICOM

  describe SegmentedPaletteLUT do

    # A small segmented LUT vector which reuses an earlier linear segment
    # through an indirect segment:
    #   Segment 0 (byte offset 0):  Linear, length 4, start value 100.
    #                               Interpolates towards 210 (the first
    #                               value of segment 1), giving a fractional
    #                               step of 27.5 to exercise rounding.
    #   Segment 1 (byte offset 6):  Discrete, length 3: 210, 220, 230.
    #   Segment 2 (byte offset 16): Indirect, length 4, referencing byte
    #                               offset 0 (a copy of segment 0).
    # Expected expansion (halves rounded away from zero):
    #   [100, 128, 155, 183, 210, 220, 230, 100, 128, 155, 183]
    def sample_data(word, double_word)
      [1, 4, 100].pack("#{word}3") +
        [0, 3, 210, 220, 230].pack("#{word}5") +
        [2, 4].pack("#{word}2") + [0].pack(double_word)
    end

    let(:little_endian_data) { sample_data('v', 'V') }
    let(:big_endian_data) { sample_data('n', 'N') }
    let(:expected_table) { [100, 128, 155, 183, 210, 220, 230, 100, 128, 155, 183] }


    describe "#expand" do

      it "should expand discrete, linear and indirect segments to the expected color table (little endian)" do
        table = SegmentedPaletteLUT.new(little_endian_data, [11, 0, 16], :little).expand
        expect(table).to eql expected_table
      end

      it "should expand the same vector encoded in big endian byte order" do
        table = SegmentedPaletteLUT.new(big_endian_data, [11, 0, 16], :big).expand
        expect(table).to eql expected_table
      end

      it "should round interpolated values to the nearest integer, halves away from zero" do
        # Step of (210 - 100) / 4 = 27.5 gives the fractional values 127.5 and 182.5:
        table = SegmentedPaletteLUT.new(little_endian_data, [11, 0, 16]).expand
        expect(table[1]).to eql 128
        expect(table[3]).to eql 183
      end

      it "should accept the LUT Descriptor in its backslash separated string form" do
        table = SegmentedPaletteLUT.new(little_endian_data, "11\\0\\16").expand
        expect(table).to eql expected_table
      end

      it "should treat the indirect reference as a byte offset, not a table index" do
        # The indirect segment references byte offset 6 (segment 1, the
        # discrete segment), copying its 3 entries:
        data = [1, 4, 100].pack('v3') +
          [0, 3, 210, 220, 230].pack('v5') +
          [2, 3].pack('v2') + [6].pack('V')
        table = SegmentedPaletteLUT.new(data, [10, 0, 16]).expand
        expect(table).to eql [100, 128, 155, 183, 210, 220, 230, 210, 220, 230]
      end

      it "should raise an error when an indirect segment references itself" do
        data = [2, 4].pack('v2') + [0].pack('V')
        expect {SegmentedPaletteLUT.new(data, [4, 0, 16]).expand}.to raise_error(/Circular/)
      end

      it "should raise an error on mutually referencing indirect segments" do
        data = [2, 2].pack('v2') + [8].pack('V') +
          [2, 2].pack('v2') + [0].pack('V')
        expect {SegmentedPaletteLUT.new(data, [4, 0, 16]).expand}.to raise_error(/Circular/)
      end

      it "should raise an error when an indirect reference is out of bounds" do
        data = [0, 1, 42].pack('v3') +
          [2, 1].pack('v2') + [999].pack('V')
        expect {SegmentedPaletteLUT.new(data, [2, 0, 16]).expand}.to raise_error(/out of bounds/)
      end

      it "should raise an error when an indirect reference does not point to the start of a segment" do
        data = [1, 4, 100].pack('v3') +
          [0, 3, 210, 220, 230].pack('v5') +
          [2, 4].pack('v2') + [2].pack('V')
        expect {SegmentedPaletteLUT.new(data, [11, 0, 16]).expand}.to raise_error(/not the start of a segment/)
      end

      it "should raise an error when the expansion length differs from the LUT Descriptor" do
        expect {SegmentedPaletteLUT.new(little_endian_data, [12, 0, 16]).expand}.to raise_error(/length mismatch/)
      end

      it "should raise an error on an unknown segment opcode" do
        data = [9, 1, 0].pack('v3')
        expect {SegmentedPaletteLUT.new(data, [1, 0, 16]).expand}.to raise_error(/Unknown segment opcode/)
      end

      it "should raise an error when the data is truncated" do
        data = [0, 3, 210].pack('v3')
        expect {SegmentedPaletteLUT.new(data, [3, 0, 16]).expand}.to raise_error(/Truncated/)
      end

      it "should raise an error when a linear segment has no following segment" do
        data = [1, 2, 100].pack('v3')
        expect {SegmentedPaletteLUT.new(data, [2, 0, 16]).expand}.to raise_error(/no following segment/)
      end

    end


    describe "::expand" do

      it "should expand the segmented data through the class method interface" do
        table = SegmentedPaletteLUT.expand(little_endian_data, [11, 0, 16])
        expect(table).to eql expected_table
      end

    end


    describe "::new" do

      it "should raise ArgumentError on an invalid endian argument" do
        expect {SegmentedPaletteLUT.new(little_endian_data, [11, 0, 16], :middle)}.to raise_error(ArgumentError)
      end

      it "should interpret a descriptor entry count of zero as 65536 entries" do
        lut = SegmentedPaletteLUT.new(little_endian_data, [0, 0, 16])
        expect(lut.entry_count).to eql 65536
      end

    end

  end

end
