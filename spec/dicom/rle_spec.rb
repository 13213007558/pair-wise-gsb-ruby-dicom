# encoding: UTF-8

require 'spec_helper'

module DICOM

  describe "RLE encoding/decoding" do

    before :context do
      DICOM.logger = Logger.new(STDOUT)
      DICOM.logger.level = Logger::FATAL
    end

    # Builds a DObject with the image related elements needed for pixel
    # encoding, configured for the RLE Lossless transfer syntax.
    def rle_dcm(columns, rows, bits, samples=1, frames=1, options={})
      dcm = DObject.new
      dcm.add_element('0028,0011', columns)
      dcm.add_element('0028,0010', rows)
      dcm.add_element('0028,0008', frames) if frames > 1
      dcm.add_element('0028,0002', samples)
      dcm.add_element('0028,0004', samples == 3 ? 'RGB' : 'MONOCHROME2')
      dcm.add_element('0028,0006', options[:planar].to_i) if samples == 3 and options.key?(:planar)
      dcm.add_element('0028,0100', bits)
      dcm.add_element('0028,0101', bits)
      dcm.add_element('0028,0102', bits - 1)
      dcm.add_element('0028,0103', options[:signed] ? 1 : 0)
      dcm.transfer_syntax = TXS_RLE
      dcm
    end

    # RLE decodes the given frame and recombines the byte planes into samples.
    def decode_rle_samples(dcm, frame, columns, rows, bits, samples)
      raw = dcm.send(:decode_rle, columns, rows, frame)
      pixels_per_plane = columns * rows
      num_planes = (bits / 8) * samples
      planes = (0...num_planes).collect {|p| raw[p * pixels_per_plane, pixels_per_plane]}
      if bits == 8
        if samples == 1
          planes[0]
        elsif dcm.value('0028,0006').to_i == 1
          planes.flatten
        else
          planes.transpose.flatten
        end
      else
        values = Array.new
        if samples == 1
          values = planes[0].zip(planes[1]).collect {|hi, lo| (hi << 8) | lo}
        elsif dcm.value('0028,0006').to_i == 1
          samples.times do |s|
            values.concat(planes[s].zip(planes[samples + s]).collect {|hi, lo| (hi << 8) | lo})
          end
        else
          hi_planes = planes[0...samples]
          lo_planes = planes[samples...2 * samples]
          values = hi_planes.transpose.zip(lo_planes.transpose).flat_map do |hi_row, lo_row|
            hi_row.zip(lo_row).collect {|hi, lo| (hi << 8) | lo}
          end
        end
        if dcm.value('0028,0103').to_i == 1
          values.collect {|v| v >= 32768 ? v - 65536 : v}
        else
          values
        end
      end
    end

    describe "ImageItem#encode_rle" do

      it "should raise an error for unsupported bit depths" do
        dcm = rle_dcm(2, 2, 8)
        dcm['0028,0100'].value = 12
        expect { dcm.encode_rle("\x00" * 4) }.to raise_error(ArgumentError, /8 or 16/)
      end

      it "should raise an error when the pixel data size does not match the image elements" do
        dcm = rle_dcm(2, 2, 8)
        expect { dcm.encode_rle("\x00" * 3) }.to raise_error(RuntimeError, /does not match/)
      end

      it "should encode a literal run with the expected hand-computed bytes" do
        dcm = rle_dcm(4, 1, 8)
        pixels = [10, 20, 30, 40]
        frame = dcm.encode_rle(dcm.encode_pixels(pixels)).first
        # 64 byte RLE header, then one segment: control byte 3 followed by the 4 literal
        # values. The encoded row is 5 bytes (odd), so the no-op pad byte 128 is appended:
        expect(frame[0...64].unpack('L<*').first).to eql 1
        expect(frame[64..-1].bytes).to eql [3, 10, 20, 30, 40, 128]
      end

      it "should encode a repeated run with the expected hand-computed bytes" do
        dcm = rle_dcm(5, 1, 8)
        pixels = [7] * 5
        frame = dcm.encode_rle(dcm.encode_pixels(pixels)).first
        # 5 repeats => control byte (257 - 5) = 252, followed by the repeated value:
        expect(frame[64..-1].bytes).to eql [252, 7]
      end

      it "should encode a run of exactly 128 bytes as one RLE packet" do
        dcm = rle_dcm(128, 1, 8)
        frame = dcm.encode_rle(dcm.encode_pixels([0] * 128)).first
        # 128 repeats => control byte 129 (0x81), followed by the value 0:
        expect(frame[64..-1].bytes).to eql [129, 0]
      end

      it "should split a run of 129 bytes into a repeat and a literal single byte" do
        dcm = rle_dcm(129, 1, 8)
        frame = dcm.encode_rle(dcm.encode_pixels([0] * 129)).first
        # 128 repeats (81 00) followed by a literal single byte (00 00):
        expect(frame[64..-1].bytes).to eql [129, 0, 0, 0]
      end

      it "should split a long run of 300 bytes into 128 + 128 + 44 repeats" do
        dcm = rle_dcm(300, 1, 8)
        frame = dcm.encode_rle(dcm.encode_pixels([0] * 300)).first
        # Control bytes: 129 (128 repeats), 129 (128 repeats), 213 (44 repeats):
        expect(frame[64..-1].bytes).to eql [129, 0, 129, 0, 213, 0]
      end

      it "should use one literal packet for exactly 128 distinct bytes" do
        dcm = rle_dcm(128, 1, 8)
        pixels = (0...128).to_a
        frame = dcm.encode_rle(dcm.encode_pixels(pixels)).first
        # Control byte 127, followed by the 128 literal bytes, then a no-op pad
        # byte (the 129 encoded bytes make the row odd):
        expect(frame.getbyte(64)).to eql 127
        expect(frame[65...193].bytes).to eql pixels
        expect(frame.getbyte(193)).to eql 128
      end

      it "should split 129 distinct bytes into two literal packets" do
        dcm = rle_dcm(129, 1, 8)
        pixels = (0...129).to_a
        frame = dcm.encode_rle(dcm.encode_pixels(pixels)).first
        # First packet: 128 bytes (control 127), second packet: 1 byte (control 0):
        expect(frame.getbyte(64)).to eql 127
        expect(frame.getbyte(193)).to eql 0
      end

      it "should pad an odd-length encoded row with the no-op code 128" do
        dcm = rle_dcm(4, 1, 8)
        pixels = [1, 3, 2, 2]
        frame = dcm.encode_rle(dcm.encode_pixels(pixels)).first
        # Literal pair (01 01 03), repeated pair (FF 02) = 5 bytes, then pad (80):
        expect(frame[64..-1].bytes).to eql [1, 1, 3, 255, 2, 128]
      end

      it "should not let RLE runs cross the row boundary for odd row widths" do
        dcm = rle_dcm(3, 3, 8)
        pixels = [9] * 9
        frame = dcm.encode_rle(dcm.encode_pixels(pixels)).first
        # Every row contains three identical bytes: control 254 (3 repeats),
        # emitted three separate times (one per row):
        expect(frame[64..-1].bytes).to eql [254, 9] * 3
      end

      it "should produce two byte plane segments for 16 bit monochrome data" do
        dcm = rle_dcm(3, 2, 16)
        pixels = [1, 2, 256, 257, 1000, 65535]
        frame = dcm.encode_rle(dcm.encode_pixels(pixels)).first
        header = frame[0...64].unpack('L<*')
        expect(header[0]).to eql 2
        expect(header[1]).to eql 64
        expect(header[2]).to be > 64
        expect(decode_rle_samples(dcm, frame, 3, 2, 16, 1)).to eql pixels
      end

      it "should produce three segments for 8 bit pixel-interleaved RGB data" do
        dcm = rle_dcm(2, 1, 8, 3, 1, :planar => 0)
        pixels = [10, 20, 30, 40, 50, 60]
        frame = dcm.encode_rle(dcm.encode_pixels(pixels)).first
        expect(frame[0...64].unpack('L<*').first).to eql 3
        expect(decode_rle_samples(dcm, frame, 2, 1, 8, 3)).to eql pixels
      end

      it "should produce six segments for 16 bit pixel-interleaved RGB data" do
        dcm = rle_dcm(2, 1, 16, 3, 1, :planar => 0)
        pixels = [0x0102, 0x0304, 0x0506, 0x0708, 0x090A, 0x0B0C]
        frame = dcm.encode_rle(dcm.encode_pixels(pixels)).first
        expect(frame[0...64].unpack('L<*').first).to eql 6
        expect(decode_rle_samples(dcm, frame, 2, 1, 16, 3)).to eql pixels
      end

      it "should arrange segments by sample for 8 bit planar RGB data" do
        dcm = rle_dcm(2, 1, 8, 3, 1, :planar => 1)
        # Plane by plane: R values, then G values, then B values:
        pixels = [10, 11, 20, 21, 30, 31]
        frame = dcm.encode_rle(dcm.encode_pixels(pixels)).first
        expect(frame[0...64].unpack('L<*').first).to eql 3
        expect(decode_rle_samples(dcm, frame, 2, 1, 8, 3)).to eql pixels
      end

      it "should encode signed 16 bit values using their two's complement bytes" do
        dcm = rle_dcm(2, 2, 16, 1, 1, :signed => true)
        pixels = [-1, -32768, 32767, 0]
        frame = dcm.encode_rle(dcm.encode_pixels(pixels)).first
        expect(decode_rle_samples(dcm, frame, 2, 2, 16, 1)).to eql pixels
      end

    end

    describe "DObject RLE round trip" do

      it "should return one encoded frame string per frame for a multiframe image" do
        dcm = rle_dcm(3, 2, 8, 1, 4)
        pixels = Array.new(24) {|i| i * 11}
        frames = dcm.encode_rle(dcm.encode_pixels(pixels))
        expect(frames.length).to eql 4
        decoded = frames.flat_map {|frame| dcm.send(:decode_rle, 3, 2, frame)}
        expect(decoded).to eql pixels
      end

      it "should store RLE encoded pixels as an encapsulated pixel data sequence" do
        dcm = rle_dcm(4, 2, 8)
        dcm.pixels = [1, 2, 3, 4, 5, 6, 7, 8]
        sequence = dcm[PIXEL_TAG]
        expect(sequence).to be_a(Sequence)
        expect(sequence.name).to eql ENCAPSULATED_PIXEL_NAME
        offset_item = sequence.children.first
        expect(offset_item.length).to eql 0
        expect(offset_item.children.length).to eql 1
        pixel_item = offset_item.children.first
        expect(pixel_item.name).to eql PIXEL_ITEM_NAME
        expect(pixel_item.bin[0...64].unpack('L<*').first).to eql 1
      end

      it "should round trip 8 bit monochrome pixels through a written and re-read file" do
        dcm = rle_dcm(5, 3, 8, 1, 2)
        srand(42)
        pixels = Array.new(30) {rand(256)}
        dcm.pixels = pixels
        file = TMPDIR + 'rle_8bit_mono.dcm'
        dcm.write(file)
        reloaded = DObject.read(file)
        expect(reloaded.transfer_syntax).to eql TXS_RLE
        expect(reloaded.compression?).to be_truthy
        frames = reloaded.image_strings(true)
        expect(frames.length).to eql 2
        decoded = frames.flat_map {|frame| reloaded.send(:decode_rle, 5, 3, frame)}
        expect(decoded).to eql pixels
      end

      it "should round trip 16 bit monochrome pixels through a written and re-read file" do
        dcm = rle_dcm(7, 4, 16, 1, 3)
        srand(43)
        pixels = Array.new(84) {rand(65536)}
        dcm.pixels = pixels
        file = TMPDIR + 'rle_16bit_mono.dcm'
        dcm.write(file)
        reloaded = DObject.read(file)
        frames = reloaded.image_strings(true)
        expect(frames.length).to eql 3
        decoded = frames.flat_map {|frame| decode_rle_samples(reloaded, frame, 7, 4, 16, 1)}
        expect(decoded).to eql pixels
      end

      it "should round trip pixel-interleaved 8 bit RGB pixels with an odd row width" do
        dcm = rle_dcm(3, 3, 8, 3, 2, :planar => 0)
        srand(44)
        pixels = Array.new(54) {rand(256)}
        dcm.pixels = pixels
        file = TMPDIR + 'rle_8bit_rgb.dcm'
        dcm.write(file)
        reloaded = DObject.read(file)
        frames = reloaded.image_strings(true)
        decoded = frames.flat_map {|frame| decode_rle_samples(reloaded, frame, 3, 3, 8, 3)}
        expect(decoded).to eql pixels
      end

      it "should round trip planar 16 bit RGB pixels for multiple frames" do
        dcm = rle_dcm(3, 3, 16, 3, 2, :planar => 1)
        srand(45)
        pixels = Array.new(54) {rand(65536)}
        dcm.pixels = pixels
        file = TMPDIR + 'rle_16bit_rgb_planar.dcm'
        dcm.write(file)
        reloaded = DObject.read(file)
        frames = reloaded.image_strings(true)
        decoded = frames.flat_map {|frame| decode_rle_samples(reloaded, frame, 3, 3, 16, 3)}
        expect(decoded).to eql pixels
      end

      it "should replace the existing pixel data sequence when assigning new RLE pixels" do
        dcm = rle_dcm(4, 1, 8)
        dcm.pixels = [1, 2, 3, 4]
        dcm.pixels = [9, 9, 9, 9]
        sequence = dcm[PIXEL_TAG]
        expect(sequence.children.length).to eql 1
        expect(sequence.children.first.children.length).to eql 1
        decoded = dcm.send(:decode_rle, 4, 1, dcm.image_strings.first)
        expect(decoded).to eql [9, 9, 9, 9]
      end

    end

    describe "ImageItem#decode_rle" do

      it "should decode the existing 8 bit monochrome RLE sample file" do
        dcm = DObject.read(DCM_EXPLICIT_MR_RLE_MONO2)
        frame = dcm.image_strings.first
        pixels = dcm.send(:decode_rle, dcm.num_cols, dcm.num_rows, frame)
        expect(pixels.length).to eql 256 * 256
      end

      it "should decode every frame of the existing palette color multiframe RLE sample file" do
        dcm = DObject.read(DCM_EXPLICIT_US_RLE_PAL_MULTIFRAME)
        cols = dcm.num_cols
        rows = dcm.num_rows
        frames = dcm.image_strings(true)
        expect(frames.length).to eql 10
        frames.each do |frame|
          pixels = dcm.send(:decode_rle, cols, rows, frame)
          expect(pixels.length).to eql cols * rows
        end
      end

    end

  end

end
