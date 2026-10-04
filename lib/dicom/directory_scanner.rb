module DICOM

  # DirectoryScanner is an internal helper which walks the binary layout of an
  # explicit little-endian DICOMDIR and records the byte positions of the directory
  # record Item headers and their next/lower-level pointer values.
  #
  class DirectoryScanner

    # The 8-byte headers of item and sequence delimitation tags (tag + zero length).
    ITEM_DELIMITER_HEADER = "\xFE\xFF\x0D\xE0"
    SEQUENCE_DELIMITER_HEADER = "\xFE\xFF\xDD\xE0"

    # Byte offsets of every Item of the Directory Record Sequence, in physical order.
    attr_reader :item_offsets
    # For every directory record item offset, a hash of tag => byte offset of the element value.
    attr_reader :value_offsets
    # Byte offset of the value of the first root directory record pointer (0004,1200).
    attr_reader :root_first_position
    # Byte offset of the value of the last root directory record pointer (0004,1202).
    attr_reader :root_last_position

    # Scans an encoded DICOMDIR binary string.
    #
    # @param [String] bin the DICOMDIR binary string
    # @return [DirectoryScanner] the completed scan
    #
    def self.scan(bin)
      scanner = new
      scanner.send(:scan_all, bin)
      return scanner
    end

    # Creates an empty scan.
    #
    def initialize
      @item_offsets = Array.new
      @value_offsets = Hash.new
      @root_first_position = nil
      @root_last_position = nil
    end

    private

    # Decodes the VR/length header of a data element at the given position.
    #
    # @param [String] bin the binary string
    # @param [Integer] position byte offset of the element tag
    # @param [Boolean] explicit whether explicit VR encoding is used at this position
    # @return [Array(String, Integer, Integer)] the VR, value length and byte offset of the value
    #
    def decode_header(bin, position)
      tag = decode_tag(bin, position)
      if tag == ITEM_TAG || tag == ITEM_DELIMITER || tag == SEQUENCE_DELIMITER
        length = bin.slice(position + 4, 4).unpack('l<')[0]
        return tag, length, position + 8
      end
      vr = bin.slice(position + 4, 2)
      if %w(OB OW OF SQ UN UT).include?(vr)
        length = bin.slice(position + 8, 4).unpack('l<')[0]
        value_position = position + 12
      else
        length = bin.slice(position + 6, 2).unpack('v')[0]
        value_position = position + 8
      end
      return vr, length, value_position
    end

    # Decodes a 4-byte tag at the given position to a ruby-dicom tag string.
    #
    # @param [String] bin the binary string
    # @param [Integer] position the byte offset of the tag
    # @return [String] the tag string
    #
    def decode_tag(bin, position)
      group, element = bin.slice(position, 4).unpack('v2')
      return format('%04X,%04X', group, element)
    end

    # Walks the file, starting after the 128 byte preamble and 'DICM' signature.
    #
    # @param [String] bin the DICOMDIR binary string
    #
    def scan_all(bin)
      # Directory offsets are measured from the first byte following the 'DICM' prefix (byte 132).
      start = bin.slice(128, 4) == 'DICM' ? 132 : 0
      # The DICOMDIR Media Storage Directory is always encoded as Explicit VR Little Endian (PS3.10):
      scan_elements(bin, start)
    end

    # Walks elements until the Directory Record Sequence is encountered and records its items.
    #
    # @param [String] bin the binary string
    # @param [Integer] position starting byte offset
    #
    def scan_elements(bin, position)
      while position < bin.length
        tag = decode_tag(bin, position)
        break if tag == SEQUENCE_DELIMITER || tag == ITEM_DELIMITER
        vr, length, value_position = decode_header(bin, position)
        if tag == DIRECTORY_RECORD_SEQUENCE_TAG
          if length == -1
            scan_items(bin, value_position, nil)
          else
            scan_items(bin, value_position, value_position + length)
          end
          position = (length == -1 ? end_of_delimited(bin, value_position, SEQUENCE_DELIMITER_HEADER) : value_position + length)
        elsif vr == 'SQ'
          position = (length == -1 ? skip_delimited(bin, value_position, SEQUENCE_DELIMITER_HEADER) : value_position + length)
        elsif tag == ITEM_TAG
          position = (length == -1 ? end_of_delimited(bin, value_position, ITEM_DELIMITER_HEADER) : value_position + length)
        else
          @root_first_position = value_position if tag == ROOT_RECORD_FIRST_TAG
          @root_last_position = value_position if tag == ROOT_RECORD_LAST_TAG
          position = value_position + length
        end
      end
    end

    # Walks the Items of the Directory Record Sequence, recording their byte offsets and pointers.
    #
    # @param [String] bin the binary string
    # @param [Integer] start byte offset of the sequence content
    # @param [Integer, NilClass] stop byte offset that ends the sequence (explicit length) or nil (delimited)
    #
    def scan_items(bin, start, stop)
      position = start
      while position < bin.length && (stop.nil? || position < stop)
        tag = decode_tag(bin, position)
        break if tag == SEQUENCE_DELIMITER
        _vr, length, value_position = decode_header(bin, position)
        item_start = position
        @item_offsets << item_start
        @value_offsets[item_start] = Hash.new
        item_stop = length == -1 ? nil : value_position + length
        scan_record(bin, value_position, item_stop)
        position = (length == -1 ? end_of_delimited(bin, value_position, ITEM_DELIMITER_HEADER) : value_position + length)
      end
    end

    # Returns the byte offset immediately following a delimited item/sequence.
    #
    # @param [String] bin the binary string
    # @param [Integer] start byte offset of the delimited content
    # @param [String] delimiter the 8-byte delimiter tag to search for
    # @return [Integer] the byte offset after the delimiter's length field
    #
    def end_of_delimited(bin, start, delimiter)
      position = start
      while position < bin.length
        tag = decode_tag(bin, position)
        _vr, length, value_position = decode_header(bin, position)
        if tag == ITEM_TAG
          position = (length == -1 ? end_of_delimited(bin, value_position, ITEM_DELIMITER_HEADER) : value_position + length)
        elsif (tag == ITEM_DELIMITER && delimiter == ITEM_DELIMITER_HEADER) || (tag == SEQUENCE_DELIMITER && delimiter == SEQUENCE_DELIMITER_HEADER)
          # value_position already points past the 8-byte delimiter header (whose value length is zero):
          return value_position
        else
          position = value_position + length
        end
      end
      return position
    end

    # Scans the (undefined length) body of a directory record item.
    #
    # @param [String] bin the binary string
    # @param [Integer] start byte offset of the item body
    #
    def scan_record(bin, start, stop=nil)
      position = start
      while position < bin.length && (stop.nil? || position < stop)
        tag = decode_tag(bin, position)
        break if tag == ITEM_DELIMITER
        vr, length, value_position = decode_header(bin, position)
        if vr == 'SQ'
          position = (length == -1 ? skip_delimited(bin, value_position, SEQUENCE_DELIMITER_HEADER) : value_position + length)
        elsif tag == ITEM_TAG
          position = (length == -1 ? end_of_delimited(bin, value_position, ITEM_DELIMITER_HEADER) : value_position + length)
        else
          @value_offsets[@item_offsets.last][tag] = value_position
          position = value_position + length
        end
      end
    end

    # Skips a delimited construct and returns the position immediately following it.
    #
    # @param [String] bin the binary string
    # @param [Integer] start byte offset of the delimited content
    # @param [String] delimiter the delimiter header that terminates the construct
    # @return [Integer] the byte offset after the construct
    #
    def skip_delimited(bin, start, delimiter)
      return end_of_delimited(bin, start, delimiter)
    end

  end

end
