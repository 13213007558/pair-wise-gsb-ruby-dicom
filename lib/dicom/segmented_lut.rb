module DICOM

  # The SegmentedLUT module expands Segmented Palette Color Lookup Table Data
  # (0028,1221-0028,1224) into a full palette color lookup table, as defined
  # in the DICOM Standard, PS3.3, Section C.7.6.3.1.5.
  #
  # Three segment types are supported:
  # * Discrete (opcode 0): A series of literal lookup table entries.
  # * Linear (opcode 1): Entries produced by linear interpolation between the
  #   last entry of the previous segment and a stored end point value.
  # * Indirect (opcode 2): Copies one or more previously defined segments,
  #   referenced by a 4 byte offset into the segmented data.
  #
  # @note
  #   The indirect segment reference is a byte offset from the first byte of
  #   the segmented data (i.e. the first byte of the first segment's opcode).
  #   It is not an index into the decoded word array, and its value depends on
  #   both the transfer syntax byte order and the 4 byte segment headers that
  #   precede each segment's data.
  #
  module SegmentedLUT

    # Segment opcode for a discrete segment (literal entries).
    DISCRETE = 0
    # Segment opcode for a linear segment (interpolated entries).
    LINEAR = 1
    # Segment opcode for an indirect segment (copies earlier segments).
    INDIRECT = 2
    # The byte length of a segment header (2 byte opcode + 2 byte segment length).
    HEADER_LENGTH = 4

    # Expands segmented palette color lookup table data to a full lookup table.
    #
    # @note Linear interpolation produces fractional values which are rounded
    #   to the nearest integer, with halves rounded away from zero
    #   (Float#round semantics).
    # @param [String] data the binary Segmented Palette Color Lookup Table Data
    # @param [Array<Integer>] descriptor the corresponding Palette Color Lookup
    #   Table Descriptor (number of entries, first mapped value, bits per entry);
    #   a first value of 0 denotes 65536 entries
    # @param [Boolean] big_endian the byte order of the segmented data
    #   (false for little endian, true for big endian)
    # @raise [RuntimeError] if the segmented data is invalid, or if the expanded
    #   table length doesn't match the number of entries given by the descriptor
    # @return [Array<Integer>] the expanded lookup table entries
    #
    def self.expand(data, descriptor, big_endian = false)
      raise ArgumentError, "Invalid argument data. Expected String, got #{data.class}" unless data.is_a?(String)
      raise ArgumentError, "Invalid argument descriptor. Expected Array, got #{descriptor.class}" unless descriptor.is_a?(Array)
      entries = descriptor[0].to_i
      entries = 65536 if entries.zero?
      word = big_endian ? 'n' : 'v'
      dword = big_endian ? 'N' : 'V'
      segments = parse_segments(data, word)
      lut = Array.new
      segments.each_index do |i|
        expand_segment(segments, i, data, word, dword, lut)
      end
      if lut.length != entries
        raise "Expanded lookup table length (#{lut.length}) does not match the number of entries specified by the LUT Descriptor (#{entries})."
      end
      lut
    end

    # Parses the segmented data and records each segment along with its byte
    # offset, so that indirect segments can be resolved against actual segment
    # boundaries (and not mistaken for word array indices).
    #
    # @param [String] data the binary segmented lookup table data
    # @param [String] word the unpack template for a 16 bit word ('v' or 'n')
    # @raise [RuntimeError] if a segment header or its data is truncated, or an
    #   unknown opcode is encountered
    # @return [Array<Array>] one [opcode, length, offset, data_offset] array per segment
    #
    def self.parse_segments(data, word)
      segments = Array.new
      offset = 0
      while offset < data.bytesize
        if offset + HEADER_LENGTH > data.bytesize
          raise "Truncated segment header at byte offset #{offset} of the segmented lookup table data."
        end
        opcode, length = data.byteslice(offset, HEADER_LENGTH).unpack("#{word}2")
        data_offset = offset + HEADER_LENGTH
        case opcode
        when DISCRETE
          data_length = 2 * length
        when LINEAR
          data_length = 2
        when INDIRECT
          data_length = 4
        else
          raise "Invalid segment opcode (#{opcode}) at byte offset #{offset} of the segmented lookup table data."
        end
        if data_offset + data_length > data.bytesize
          raise "Truncated segment data at byte offset #{offset} of the segmented lookup table data."
        end
        segments << [opcode, length, offset, data_offset]
        offset = data_offset + data_length
      end
      segments
    end

    # Expands a single segment, appending its entries to the lookup table.
    # Indirect segments are expanded by re-applying the referenced (earlier)
    # segments in the current context.
    #
    # @param [Array<Array>] segments the parsed segment definitions
    # @param [Integer] index the index of the segment to expand
    # @param [String] data the binary segmented lookup table data
    # @param [String] word the unpack template for a 16 bit word ('v' or 'n')
    # @param [String] dword the unpack template for a 32 bit dword ('V' or 'N')
    # @param [Array<Integer>] lut the lookup table entries produced so far
    # @raise [RuntimeError] if the segment is invalid
    #
    def self.expand_segment(segments, index, data, word, dword, lut)
      opcode, length, offset, data_offset = segments[index]
      case opcode
      when DISCRETE
        lut.concat(data.byteslice(data_offset, 2 * length).unpack("#{word}#{length}"))
      when LINEAR
        if lut.empty?
          raise "Invalid segmented lookup table: The first segment cannot be a linear segment, as there is no previous entry to interpolate from."
        end
        # The segment contributes 'length' new entries, linearly interpolated
        # from the last entry of the previous segment (y0) to the stored end
        # point value (y1). Entry i (1-based) is y0 + (y1 - y0) * i / length,
        # rounded to the nearest integer (halves rounded away from zero), so
        # that the final entry equals y1 exactly.
        y0 = lut.last
        y1 = data.byteslice(data_offset, 2).unpack(word).first
        length.times do |i|
          lut << (y0 + (y1 - y0) * (i + 1).to_f / length).round
        end
      when INDIRECT
        if index.zero?
          raise "Invalid segmented lookup table: The first segment cannot be an indirect segment, as there is no previous segment to copy."
        end
        # The reference is a 32 bit byte offset (decoded using the transfer
        # syntax byte order) from the start of the segmented data to the first
        # segment to copy. It must point at the header of a previously defined
        # segment, and the copied segments must all precede this segment.
        byte_offset = data.byteslice(data_offset, 4).unpack(dword).first
        start = segments.index { |s| s[2] == byte_offset }
        if start.nil?
          raise "Invalid indirect segment at byte offset #{offset}: Reference #{byte_offset} does not point to the start of a segment."
        end
        if start + length > index
          raise "Invalid indirect segment at byte offset #{offset}: Circular reference detected (an indirect segment may only copy segments that precede it)."
        end
        length.times do |i|
          expand_segment(segments, start + i, data, word, dword, lut)
        end
      end
    end

  end

end
