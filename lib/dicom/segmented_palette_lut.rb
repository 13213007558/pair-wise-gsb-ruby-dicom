module DICOM

  # This class expands Segmented Palette Color Lookup Table Data into a
  # full lookup table (an array of integer values), as described in the
  # DICOM Standard, PS3.3, Section C.7.6.3.1.5 (and C.8.11.3.1.5).
  #
  # A segmented palette color LUT is built from three kinds of segments:
  # * Discrete (opcode 0): An explicit list of LUT values.
  # * Linear (opcode 1): A single start value; the remaining entries are
  #   linearly interpolated towards the first entry of the next segment.
  #   Interpolated values are rounded to the nearest integer, with halves
  #   rounded away from zero.
  # * Indirect (opcode 2): A copy of one or more previously defined
  #   segments. The segment data holds a 32 bit unsigned integer which is
  #   the byte offset (relative to the first byte of the segmented LUT
  #   data, in the byte order of the data set) of the first segment to be
  #   copied. Note that this is a byte position into the encoded data -
  #   not an index into the expanded table - and as such it depends both
  #   on the byte order and on the 4 byte segment header length.
  #
  # @example
  #   lut = DICOM::SegmentedPaletteLUT.new(bin, [11, 0, 16], :little)
  #   table = lut.expand
  #
  class SegmentedPaletteLUT

    # Segment opcodes as defined by the DICOM standard:
    OPCODE_DISCRETE = 0
    OPCODE_LINEAR = 1
    OPCODE_INDIRECT = 2
    # Byte length of a segment header (opcode + segment length):
    SEGMENT_HEADER_LENGTH = 4
    # Byte length of the reference position carried by an indirect segment:
    INDIRECT_REFERENCE_LENGTH = 4

    # The number of entries that the expanded lookup table shall contain
    # (as given by the first value of the LUT Descriptor).
    attr_reader :entry_count
    # The byte order of the segmented LUT data (:little or :big).
    attr_reader :endian

    # Creates a SegmentedPaletteLUT instance.
    #
    # @param [String] data the binary Segmented Palette Color Lookup Table
    #   Data (e.g. the value of element 0028,1221), encoded as 16 bit words
    # @param [Array<Integer>, String] descriptor the corresponding LUT
    #   Descriptor (e.g. 0028,1101), either as an array of three integers
    #   (number of entries, first mapped value, bits per entry) or as its
    #   backslash separated string representation
    # @param [Symbol] endian the byte order of the data (:little or :big)
    #
    def initialize(data, descriptor, endian = :little)
      raise ArgumentError, "Expected :little or :big as endian, got #{endian.inspect}" unless [:little, :big].include?(endian)
      @data = data.to_str.dup
      @endian = endian
      descriptor = descriptor.split("\\").map(&:to_i) if descriptor.is_a?(String)
      @entry_count = descriptor[0].to_i
      # A descriptor entry count of zero denotes 2**16 entries:
      @entry_count = 65536 if @entry_count.zero?
    end

    # Expands the segmented LUT data to a full lookup table.
    #
    # @raise [RuntimeError] if the data is malformed, contains a circular
    #   or invalid indirect reference, or expands to a number of entries
    #   that differs from the LUT Descriptor
    # @return [Array<Integer>] the expanded lookup table
    #
    def expand
      @segments = parse_segments
      @offset_index = {}
      @segments.each_with_index { |segment, i| @offset_index[segment[:offset]] = i }
      table = expand_from(0, [])
      if table.length != @entry_count
        raise "Segmented LUT expansion length mismatch: The LUT Descriptor specifies #{@entry_count} entries, but the segmented data expanded to #{table.length} entries."
      end
      table
    end

    # Expands the segmented LUT data to a full lookup table.
    #
    # @param [String] data the binary Segmented Palette Color Lookup Table Data
    # @param [Array<Integer>, String] descriptor the corresponding LUT Descriptor
    # @param [Symbol] endian the byte order of the data (:little or :big)
    # @return [Array<Integer>] the expanded lookup table
    #
    def self.expand(data, descriptor, endian = :little)
      new(data, descriptor, endian).expand
    end


    private


    # Expands the segments from the given segment index onwards, until the
    # end of the data or (when copying through an indirect segment) until
    # the requested number of entries has been produced.
    #
    # @param [Integer] index index of the first segment to expand
    # @param [Array<Integer>] stack indices of the indirect segments currently being expanded (for cycle detection)
    # @param [Integer] limit maximum number of entries to produce (nil for no limit)
    # @return [Array<Integer>] the expanded entries
    #
    def expand_from(index, stack, limit = nil)
      entries = []
      while index < @segments.length && (limit.nil? || entries.length < limit)
        segment = @segments[index]
        case segment[:opcode]
        when OPCODE_DISCRETE
          entries.concat(segment[:values])
        when OPCODE_LINEAR
          entries.concat(expand_linear(segment, index, stack))
        when OPCODE_INDIRECT
          entries.concat(expand_indirect(segment, stack))
        end
        index += 1
      end
      if limit && entries.length != limit
        raise "Indirect segment requested #{limit} entries, but the referenced segments provide #{entries.length} entries."
      end
      entries
    end

    # Expands a linear segment by interpolating between its start value
    # and the first entry of the following segment.
    #
    # @param [Hash] segment the parsed segment
    # @param [Integer] index the position of the segment in the segment list
    # @param [Array<Integer>] stack indices of the indirect segments currently being expanded
    # @return [Array<Integer>] the interpolated entries
    #
    def expand_linear(segment, index, stack)
      y0 = segment[:first]
      y1 = first_value_of(index + 1, stack)
      if y1.nil?
        raise "Linear segment at byte offset #{segment[:offset]} has no following segment to interpolate towards."
      end
      length = segment[:length]
      # Linear interpolation between this segment's start value (y0) and the
      # first entry of the next segment (y1). Rounding is explicit: to the
      # nearest integer, halves rounded away from zero (Ruby's Float#round).
      (0...length).map { |i| (y0 + (y1 - y0) * i.to_f / length).round }
    end

    # Expands an indirect segment by copying previously defined segments.
    # The segment's reference is a byte offset into the segmented LUT data
    # (in the data set's byte order), identifying the first segment to copy.
    #
    # @param [Hash] segment the parsed segment
    # @param [Array<Integer>] stack indices of the indirect segments currently being expanded
    # @return [Array<Integer>] the copied entries
    #
    def expand_indirect(segment, stack)
      index = @offset_index[segment[:reference]]
      if index.nil?
        raise "Indirect segment at byte offset #{segment[:offset]} references byte offset #{segment[:reference]}, which is out of bounds or not the start of a segment."
      end
      if stack.include?(index)
        raise "Circular indirect segment reference detected at byte offset #{segment[:offset]}."
      end
      expand_from(index, stack + [index], segment[:length])
    end

    # Gives the first expanded value of the segment at the given index,
    # without expanding the remainder of the segment.
    #
    # @param [Integer] index the segment index
    # @param [Array<Integer>] stack indices of the indirect segments currently being expanded
    # @return [Integer, nil] the first entry value (nil if index is out of range)
    #
    def first_value_of(index, stack)
      segment = @segments[index]
      return nil unless segment
      case segment[:opcode]
      when OPCODE_DISCRETE
        segment[:values].first
      when OPCODE_LINEAR
        segment[:first]
      when OPCODE_INDIRECT
        expand_indirect(segment, stack).first
      end
    end

    # Parses the segmented LUT data into a list of segments, recording the
    # byte offset of each segment (needed to resolve indirect references).
    #
    # @raise [RuntimeError] if the data is truncated or contains an unknown opcode
    # @return [Array<Hash>] the parsed segments
    #
    def parse_segments
      segments = []
      offset = 0
      while offset < @data.bytesize
        if offset + SEGMENT_HEADER_LENGTH > @data.bytesize
          raise "Truncated segmented LUT data: Incomplete segment header at byte offset #{offset}."
        end
        opcode, length = @data.byteslice(offset, SEGMENT_HEADER_LENGTH).unpack("#{word_directive}2")
        segment = {:opcode => opcode, :length => length, :offset => offset}
        data_offset = offset + SEGMENT_HEADER_LENGTH
        case opcode
        when OPCODE_DISCRETE
          byte_length = length * 2
          ensure_available(data_offset, byte_length, offset)
          segment[:values] = @data.byteslice(data_offset, byte_length).unpack("#{word_directive}*")
          offset = data_offset + byte_length
        when OPCODE_LINEAR
          ensure_available(data_offset, 2, offset)
          segment[:first] = @data.byteslice(data_offset, 2).unpack(word_directive).first
          offset = data_offset + 2
        when OPCODE_INDIRECT
          ensure_available(data_offset, INDIRECT_REFERENCE_LENGTH, offset)
          segment[:reference] = @data.byteslice(data_offset, INDIRECT_REFERENCE_LENGTH).unpack(double_word_directive).first
          offset = data_offset + INDIRECT_REFERENCE_LENGTH
        else
          raise "Unknown segment opcode #{opcode} at byte offset #{offset}."
        end
        segments << segment
      end
      segments
    end

    # Raises an error if the given number of bytes is not available.
    #
    # @param [Integer] offset byte offset of the segment data
    # @param [Integer] byte_length number of bytes required
    # @param [Integer] segment_offset byte offset of the segment header (used in the error message)
    #
    def ensure_available(offset, byte_length, segment_offset)
      if offset + byte_length > @data.bytesize
        raise "Truncated segmented LUT data: Segment at byte offset #{segment_offset} extends beyond the end of the data."
      end
    end

    # Gives the unpack directive for 16 bit words in the current byte order.
    #
    # @return [String] the unpack directive
    #
    def word_directive
      @endian == :little ? 'v' : 'n'
    end

    # Gives the unpack directive for 32 bit unsigned integers in the current byte order.
    #
    # @return [String] the unpack directive
    #
    def double_word_directive
      @endian == :little ? 'V' : 'N'
    end

  end

end
