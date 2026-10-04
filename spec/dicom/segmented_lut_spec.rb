# encoding: UTF-8

require 'spec_helper'

module DICOM

  describe SegmentedLUT do

    # Builds binary segmented palette color LUT data from a list of segment
    # definitions: [opcode, segment length, data value(s)].
    def build_segmented_data(segments, big_endian = false)
      word = big_endian ? 'n' : 'v'
      dword = big_endian ? 'N' : 'V'
      bin = ''.b
      segments.each do |opcode, length, values|
        bin << [opcode, length].pack("#{word}2")
        case opcode
        when SegmentedLUT::DISCRETE
          bin << values.pack("#{word}*")
        when SegmentedLUT::LINEAR
          bin << [values].pack(word)
        when SegmentedLUT::INDIRECT
          bin << [values].pack(dword)
        end
      end
      bin
    end

    # A small lookup table where an indirect segment reuses an earlier linear
    # segment. Byte layout (segment headers are 4 bytes each):
    #   offset  0: discrete, length 2, values [0, 100]   (8 bytes)
    #   offset  8: linear, length 2, end point 200       (6 bytes)
    #   offset 14: discrete, length 1, value [50]        (6 bytes)
    #   offset 20: indirect, length 1, byte offset 8     (8 bytes)
    # The indirect reference (8) is a byte offset to the linear segment's
    # header - neither a segment index nor a word array index. The reused
    # linear segment interpolates from the current last entry (50) to its
    # stored end point (200), yielding 125 and 200.
    def reuse_vector(big_endian = false)
      build_segmented_data([
        [SegmentedLUT::DISCRETE, 2, [0, 100]],
        [SegmentedLUT::LINEAR, 2, 200],
        [SegmentedLUT::DISCRETE, 1, [50]],
        [SegmentedLUT::INDIRECT, 1, 8]
      ], big_endian)
    end

    context "when expanding segmented palette color LUT data" do

      it "expands discrete, linear and indirect segments, reusing an earlier linear segment" do
        lut = SegmentedLUT.expand(reuse_vector, [7, 0, 16])
        expect(lut).to eql [0, 100, 150, 200, 50, 125, 200]
      end

      it "produces the same table from big endian encoded data" do
        lut = SegmentedLUT.expand(reuse_vector(true), [7, 0, 16], true)
        expect(lut).to eql [0, 100, 150, 200, 50, 125, 200]
      end

      it "fails when the data is decoded with the wrong byte order" do
        # With swapped byte order the big endian segment headers and the 4 byte
        # indirect reference decode to nonsense values:
        expect {
          SegmentedLUT.expand(reuse_vector(true), [7, 0, 16])
        }.to raise_error(RuntimeError)
      end

      it "copies multiple segments with a single indirect segment" do
        # The indirect segment copies the 2 segments starting at byte offset 0:
        data = build_segmented_data([
          [SegmentedLUT::DISCRETE, 2, [1, 2]],
          [SegmentedLUT::DISCRETE, 1, [9]],
          [SegmentedLUT::INDIRECT, 2, 0]
        ])
        expect(SegmentedLUT.expand(data, [6, 0, 16])).to eql [1, 2, 9, 1, 2, 9]
      end

      it "rounds linear interpolation to the nearest integer, halves away from zero" do
        # Interpolation from 0 to 1 in 2 steps hits 0.5, which rounds up to 1:
        data = build_segmented_data([
          [SegmentedLUT::DISCRETE, 1, [0]],
          [SegmentedLUT::LINEAR, 2, 1]
        ])
        expect(SegmentedLUT.expand(data, [3, 0, 16])).to eql [0, 1, 1]
      end

      it "interpolates downwards and always ends exactly on the stored end point" do
        data = build_segmented_data([
          [SegmentedLUT::DISCRETE, 1, [10]],
          [SegmentedLUT::LINEAR, 3, 0]
        ])
        expect(SegmentedLUT.expand(data, [4, 0, 16])).to eql [10, 7, 3, 0]
      end

      it "treats a descriptor entry count of zero as 65536" do
        data = build_segmented_data([
          [SegmentedLUT::DISCRETE, 65535, Array.new(65535, 3)],
          [SegmentedLUT::DISCRETE, 1, [7]]
        ])
        lut = SegmentedLUT.expand(data, [0, 0, 16])
        expect(lut.length).to eql 65536
        expect(lut.last).to eql 7
      end

    end

    context "when rejecting invalid segmented data" do

      it "rejects a circular reference where an indirect segment points to itself" do
        # The indirect segment at byte offset 6 references its own header:
        data = build_segmented_data([
          [SegmentedLUT::DISCRETE, 1, [10]],
          [SegmentedLUT::INDIRECT, 1, 6]
        ])
        expect {
          SegmentedLUT.expand(data, [2, 0, 16])
        }.to raise_error(RuntimeError, /Circular reference/)
      end

      it "rejects a circular reference where the copied range includes the indirect segment itself" do
        # Copying 2 segments from byte offset 0 would include the indirect segment:
        data = build_segmented_data([
          [SegmentedLUT::DISCRETE, 1, [10]],
          [SegmentedLUT::INDIRECT, 2, 0]
        ])
        expect {
          SegmentedLUT.expand(data, [3, 0, 16])
        }.to raise_error(RuntimeError, /Circular reference/)
      end

      it "rejects an indirect reference that doesn't point to a segment boundary" do
        # Byte offset 4 is in the middle of the first segment's data:
        data = build_segmented_data([
          [SegmentedLUT::DISCRETE, 2, [0, 100]],
          [SegmentedLUT::INDIRECT, 1, 4]
        ])
        expect {
          SegmentedLUT.expand(data, [4, 0, 16])
        }.to raise_error(RuntimeError, /does not point to the start of a segment/)
      end

      it "rejects an indirect reference that points beyond the data" do
        data = build_segmented_data([
          [SegmentedLUT::DISCRETE, 1, [10]],
          [SegmentedLUT::INDIRECT, 1, 1000]
        ])
        expect {
          SegmentedLUT.expand(data, [2, 0, 16])
        }.to raise_error(RuntimeError, /does not point to the start of a segment/)
      end

      it "rejects an expansion whose length doesn't match the LUT Descriptor" do
        expect {
          SegmentedLUT.expand(reuse_vector, [8, 0, 16])
        }.to raise_error(RuntimeError, /does not match the number of entries/)
      end

      it "rejects an unknown segment opcode" do
        data = [5, 1, 0].pack('v*')
        expect {
          SegmentedLUT.expand(data, [1, 0, 16])
        }.to raise_error(RuntimeError, /Invalid segment opcode/)
      end

      it "rejects a linear first segment" do
        data = build_segmented_data([[SegmentedLUT::LINEAR, 2, 200]])
        expect {
          SegmentedLUT.expand(data, [2, 0, 16])
        }.to raise_error(RuntimeError, /first segment cannot be a linear/)
      end

      it "rejects an indirect first segment" do
        data = build_segmented_data([[SegmentedLUT::INDIRECT, 1, 0]])
        expect {
          SegmentedLUT.expand(data, [1, 0, 16])
        }.to raise_error(RuntimeError, /first segment cannot be an indirect/)
      end

      it "rejects truncated segment data" do
        data = build_segmented_data([[SegmentedLUT::DISCRETE, 2, [0, 100]]])
        expect {
          SegmentedLUT.expand(data.byteslice(0, data.bytesize - 1), [2, 0, 16])
        }.to raise_error(RuntimeError, /Truncated segment data/)
      end

    end

  end

end
