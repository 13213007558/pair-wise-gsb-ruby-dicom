module DICOM

  # The DicomDir class handles reading, editing and writing of DICOMDIR files
  # (the directory file of a DICOM file-set, PS3.10 Annex F).
  #
  # A DICOMDIR is a DICOM object whose Media Storage SOP Class UID is
  # 1.2.840.10008.1.3.10. It carries a Directory Record Sequence
  # (0004,1220) where the directory records are physically stored as a flat
  # list of Items but logically form a tree, linked together by byte offsets
  # (Offset of the Next Directory Record 0004,1400 and Offset of Referenced
  # Lower-Level Directory Entity 0004,1420).
  #
  # DicomDir rebuilds these links into an editable tree of DirectoryRecord
  # instances (accessible through #records). Records may be inserted and
  # deleted freely, and when the DICOMDIR is written, the records are
  # flattened again and all link offsets (as well as the root entity offsets
  # 0004,1200/0004,1202) are recalculated to match the new physical layout.
  #
  class DicomDir < DObject

    # The root level directory records (records linked from the root directory entity).
    attr_reader :records

    # Creates a DicomDir instance, either by parsing an encoded binary string
    # or from an empty state.
    #
    # @param [String, NilClass] string an optional encoded binary DICOMDIR string to parse
    # @return [DicomDir] the created DicomDir instance
    # @example Create an empty DICOMDIR
    #   dir = DICOM::DicomDir.new
    #
    def initialize(string=nil)
      super()
      @records = Array.new
      @directory_binary = nil
      if string
        read(string, true, :syntax => EXPLICIT_LITTLE_ENDIAN)
        load_directory_tree(string) if @read_success
      end
    end

    # Adds an existing DirectoryRecord as a root level record.
    #
    # @param [DirectoryRecord] record the record to attach at the root level
    # @param [Hash] options the options to use when adding the record
    # @option options [Integer] :index if specified, inserts the record at this root level position
    # @return [DirectoryRecord] the record that was added
    #
    def add_root_record(record, options={})
      raise ArgumentError, "Expected DirectoryRecord, got #{record.class}." unless record.is_a?(DirectoryRecord)
      record.parent.delete(record) if record.parent
      index = options[:index]
      if index
        raise ArgumentError, "The specified index (#{index}) is out of range." if index < 0 or index > @records.length
        @records.insert(index, record)
      else
        @records << record
      end
      record.set_parent(nil)
      return record
    end

    # Creates and attaches a root level DirectoryRecord.
    #
    # @param [String] type the Directory Record Type, e.g. 'PATIENT'
    # @param [Hash] options the options to use for creating the record (see DirectoryRecord.new)
    # @return [DirectoryRecord] the newly created record
    #
    def add_record(type, options={})
      index = options[:index]
      record_options = options.dup
      record_options.delete(:index)
      record = DirectoryRecord.new(type, record_options)
      add_root_record(record, :index => index)
      return record
    end

    # Removes a root level record (and the complete subtree below it by default).
    #
    # @param [DirectoryRecord] record the root record to remove
    # @param [Hash] options the options to use when removing the record
    # @option options [Boolean] :keep_children when true, the child records of the removed record are promoted to the root level
    # @return [DirectoryRecord, nil] the removed record, or nil if no match was made
    #
    def delete(record, options={})
      insertion_index = @records.index(record)
      removed = @records.delete(record)
      if removed
        if options[:keep_children]
          grandchildren = removed.children
          grandchildren.each { |grandchild| grandchild.set_parent(nil) }
          @records.insert(insertion_index, *grandchildren)
        else
          removed.detach_subtree
        end
      end
      return removed
    end

    # Gives the total number of directory records in the file-set tree.
    #
    # @return [Integer] the number of directory records
    #
    def record_count
      @records.inject(0) { |total, record| total + record.count_all }
    end

    # Flattens the complete directory tree into an array, in pre-order
    # (depth-first) traversal order. This is the canonical physical order of
    # the records in the Directory Record Sequence.
    #
    # @return [Array<DirectoryRecord>] all records, depth-first
    #
    def flatten_records
      records = Array.new
      @records.each { |record| records.concat(record.flatten) }
      return records
    end

    # Iterates over every directory record in the tree, depth-first.
    #
    def each_record
      @records.each { |record| record.each_record { |node| yield node } }
      return nil
    end

    # Retrieves all records matching a specific Directory Record Type.
    #
    # @param [String] type the record type to match, e.g. 'PATIENT', 'STUDY', 'IMAGE'
    # @return [Array<DirectoryRecord>] the matching records
    #
    def records_by_type(type)
      found = Array.new
      each_record { |record| found << record if record.type.to_s.upcase == type.to_s.upcase }
      return found
    end

    # The File-set ID (0004,1130).
    #
    # @return [String, nil] the file-set ID
    #
    def file_set_id
      value(FILE_SET_ID_TAG)
    end

    # Sets the File-set ID (0004,1130).
    #
    # @param [String] new_id the new file-set ID
    #
    def file_set_id=(new_id)
      set_top_value(FILE_SET_ID_TAG, new_id)
    end

    # Encodes the DicomDir to a binary DICOMDIR string.
    #
    # Before encoding, the directory tree is flattened and the link offsets
    # (0004,1400, 0004,1420) as well as the root entity offsets (0004,1200,
    # 0004,1202) are (re)calculated to match the physical layout.
    #
    # @param [Hash] options the options to use for encoding
    # @option options [Array<DirectoryRecord>] :record_order an explicit physical record order (defaults to canonical depth-first order). Used for testing that the offsets are correct regardless of physical arrangement.
    # @return [String] the encoded binary DICOMDIR string
    #
    def to_binary(options={})
      write_dicomdir(options)
    end

    # Writes the DicomDir to file. See #to_binary for details on how the
    # directory link offsets are handled.
    #
    # @param [String] file_name the path of the DICOMDIR file to write
    # @param [Hash] options the options to use for writing (see #to_binary)
    # @option options [Boolean] :ignore_meta if true, the file meta group is not supplemented with missing mandatory elements before writing
    #
    def write(file_name, options={})
      raise ArgumentError, "Invalid file_name. Expected String, got #{file_name.class}." unless file_name.is_a?(String)
      bin = write_dicomdir(options)
      open_file(file_name)
      if @file
        @file.write(bin)
        @file.close
        @write_success = true
      end
      return @write_success
    end


    #-- Class methods ++

    class << self

      # Creates a DicomDir instance by adopting the data elements of an
      # already parsed DObject. Used internally when the generic parser
      # detects the Media Storage Directory SOP Class.
      #
      # @param [DObject] dcm the parsed DICOM object
      # @param [String] binary the raw binary string the object was parsed from
      # @return [DicomDir] the converted DICOMDIR instance
      #
      def from_dcm(dcm, binary)
        dir = self.allocate
        dir.send(:initialize_adopted, dcm, binary)
        dir
      end

      # Creates a DicomDir instance by reading and parsing a DICOMDIR file.
      #
      # @param [String] file the path of the DICOMDIR file to load
      # @param [Hash] options the options passed on to the parser
      # @return [DicomDir] the created DicomDir instance
      #
      def read(file, options={})
        raise ArgumentError, "Invalid argument 'file'. Expected String, got #{file.class}." unless file.is_a?(String)
        if File.exist?(file) && File.file?(file) && File.readable?(file) && File.size(file) >= 132
          bin = File.open(file, "rb") { |f| f.read }
          dir = self.new(bin)
          dir.source = file
          logger.info("DICOMDIR file successfully read: #{file}") if dir.read?
          dir
        else
          dir = self.new
          dir.read_success = false
          dir.source = file
          logger.error("Unable to read DICOMDIR file: #{file}")
          dir
        end
      end

      # Creates a DicomDir instance by parsing an encoded binary DICOMDIR string.
      #
      # @param [String] string an encoded binary string containing DICOMDIR information
      # @param [Hash] options the options passed on to the parser
      # @return [DicomDir] the created DicomDir instance
      #
      def parse(string, options={})
        raise ArgumentError, "Invalid argument 'string'. Expected String, got #{string.class}." unless string.is_a?(String)
        self.new(string)
      end

    end


    private

    # Initializes a DicomDir by adopting the state of a parsed DObject.
    #
    # @param [DObject] dcm the parsed DICOM object to adopt
    # @param [String] binary the raw binary string the object was parsed from
    #
    def initialize_adopted(dcm, binary)
      @tags = dcm.instance_variable_get(:@tags)
      @explicit = dcm.instance_variable_get(:@explicit)
      @str_endian = dcm.instance_variable_get(:@str_endian)
      @read_success = dcm.read_success
      @write_success = nil
      @stream = dcm.stream
      @parent = nil
      @records = Array.new
      @directory_binary = nil
      # Re-parent the adopted top level elements to self. Their descendants
      # keep their existing item/sequence parents.
      children.each { |child| child.set_parent(self) }
      load_directory_tree(binary)
    end

    # Builds the editable directory tree from the parsed Directory Record
    # Sequence by walking the next/lower-level byte offsets rather than the
    # physical Item order. This ensures a correct tree even if the records are
    # stored in a non-canonical physical arrangement.
    #
    # @param [String] binary the raw, encoded DICOMDIR string
    #
    def load_directory_tree(binary)
      sequence = self[DIRECTORY_RECORD_SEQUENCE_TAG]
      return unless sequence && sequence.children?
      @directory_binary = binary
      # Map each physical record Item to its byte position (offset origin: start of file meta information).
      item_offsets = record_item_offsets(binary)
      offset_to_item = Hash.new
      if item_offsets.length == sequence.count
        item_offsets.each_with_index do |file_position, index|
          offset_to_item[file_position - meta_origin(binary)] = sequence[index]
        end
      elsif item_offsets.length >= sequence.count
        # Prefer physical order alignment; the tree walk itself only uses
        # offsets that resolve, so extras are simply ignored.
        sequence.items.each_with_index do |item, index|
          offset_to_item[item_offsets[index] - meta_origin(binary)] = item
        end
        logger.warn("Mismatch between detected record offsets and parsed record items while building the directory tree.")
      else
        # Too few offsets detected to map every item reliably.
        logger.warn("Mismatch between detected record offsets and parsed record items while building the directory tree.")
      end
      @records = Array.new
      first_root_offset = integer_value(self[FIRST_ROOT_RECORD_TAG])
      build_directory_tree_from_links(first_root_offset, offset_to_item)
    end

    # Rebuilds the directory tree using only the link offsets, independent of
    # the physical Item order. The algorithm works in two stages:
    #
    # 1. Every reachable Item gets a DirectoryRecord, and the parent/child
    #    hierarchy is established exclusively from the root offset and the
    #    lower-level (0004,1420) links. Each non-root record is the first child
    #    of exactly one record, so this determines the tree shape without regard
    #    to physical arrangement.
    # 2. Within each level, records are ordered by following the next (0004,1400)
    #    links from each record's first child/root chain head.
    #
    # A work queue is used so that a child may be physically located before its
    # parent (shuffled order) without affecting the result.
    #
    # @param [Integer] first_root_offset the offset of the first root level record
    # @param [Hash{Integer => Item}] offset_to_item a map from byte offset to parsed record Item
    #
    def build_directory_tree_from_links(first_root_offset, offset_to_item)
      # Records are keyed by byte offset (Integer) instead of the Item itself,
      # because Item equality is value based and would merge distinct records
      # that happen to carry identical child elements.
      records_by_offset = Hash.new
      record_for = lambda do |offset|
        item = offset_to_item[offset]
        unless records_by_offset[offset]
          records_by_offset[offset] = DirectoryRecord.new(record_type_of(item), :item => item)
        end
        records_by_offset[offset]
      end
      # A work item is a [parent_head_offset_or_nil, chain_head_offset] pair:
      # walk the sibling chain beginning at chain_head_offset (all sharing the
      # same parent), and enqueue one descent edge for every node that has children.
      queue = [[nil, first_root_offset]]
      processed_edges = Array.new
      while (parent_head, head_offset = queue.shift)
        next if head_offset.nil? || head_offset == 0
        next if processed_edges.include?([parent_head, head_offset])
        processed_edges << [parent_head, head_offset]
        parent_record = parent_head ? record_for.call(parent_head) : nil
        offset = head_offset
        chain_seen_offsets = Array.new
        while offset != 0
          item = offset_to_item[offset]
          break unless item
          break if chain_seen_offsets.include?(offset)
          chain_seen_offsets << offset
          record = record_for.call(offset)
          if parent_record
            parent_record.add(record) unless parent_record.children.any? { |child| child.item.equal?(item) }
          else
            unless @records.any? { |root| root.item.equal?(item) }
              @records << record
              record.set_parent(nil)
            end
          end
          # Descent edge for this node's children (processed later).
          child_offset = integer_value(item[LOWER_LEVEL_RECORD_TAG])
          queue << [offset, child_offset] if child_offset != 0
          offset = integer_value(item[NEXT_RECORD_TAG])
        end
      end
    end

    # Retrieves the Directory Record Type of an Item (empty string if missing).
    #
    def record_type_of(item)
      item.exists?(RECORD_TYPE_TAG) ? item.value(RECORD_TYPE_TAG) : ''
    end

    # Determines the byte position of the start of the file meta information
    # in the encoded string (132 for files with the standard DICM preamble).
    #
    def meta_origin(binary)
      binary.length >= 132 && binary[128,4] == "DICM" ? 132 : 0
    end

    # Scans the raw DICOMDIR string for the Directory Record Sequence and
    # returns the absolute file byte positions of every record Item header.
    #
    # @param [String] binary the raw, encoded DICOMDIR string
    # @return [Array<Integer>] the absolute positions of the record Item headers
    #
    def record_item_offsets(binary)
      offsets = Array.new
      origin = meta_origin(binary)
      position = origin
      # Walk the top level data elements until the Directory Record Sequence is located.
      while position + 8 <= binary.length
        tag = decode_tag_at(binary, position)
        position += 4
        _vr, length, header_size = decode_vr_length_at(binary, position, tag)
        position += header_size
        break if tag.nil?
        if tag == DIRECTORY_RECORD_SEQUENCE_TAG
          offsets = scan_item_offsets(binary, position, length)
          break
        end
        break if position > binary.length
        if length >= 0
          position += length
        elsif tag == ITEM_TAG
          position = skip_undefined_item(binary, position, binary.length)
        elsif DELIMITER_TAGS.include?(tag)
          break
        else
          # Undefined length top level sequence (e.g. File-set Information Sequence).
          position = skip_undefined_sequence(binary, position, binary.length)
        end
      end
      return offsets
    end

    # Returns the absolute Item header positions contained in a sequence value.
    # Handles both defined length and undefined length sequence encoding.
    #
    def scan_item_offsets(binary, start, sequence_length)
      offsets = Array.new
      position = start
      boundary = sequence_length >= 0 ? start + sequence_length : binary.length
      while position + 8 <= boundary
        tag = decode_tag_at(binary, position)
        break unless tag
        position += 4
        _vr, item_length, header_size = decode_vr_length_at(binary, position, tag)
        position += header_size
        if tag == ITEM_TAG
          offsets << (position - 8)
          if item_length >= 0
            position += item_length
          else
            position = skip_undefined_item(binary, position, boundary)
          end
        elsif tag == SEQUENCE_DELIMITER
          break
        elsif tag == ITEM_DELIMITER
          break
        else
          break
        end
      end
      return offsets
    end

    # Advances past an undefined length Item, skipping its child elements
    # (including nested undefined length sequences/items), until its Item
    # delimiter is reached.
    #
    def skip_undefined_item(binary, position, boundary)
      while position + 8 <= boundary
        tag = decode_tag_at(binary, position)
        break unless tag
        position += 4
        _vr, length, header_size = decode_vr_length_at(binary, position, tag)
        position += header_size
        if tag == ITEM_DELIMITER
          break
        elsif tag == SEQUENCE_DELIMITER
          next
        elsif length >= 0
          position += length
        else
          # Undefined length nested element: sequences contain items.
          if tag == ITEM_TAG
            position = skip_undefined_item(binary, position, boundary)
          else
            position = skip_undefined_sequence(binary, position, boundary)
          end
        end
      end
      return position
    end

    # Advances past an undefined length sequence until its sequence delimiter.
    #
    def skip_undefined_sequence(binary, position, boundary)
      while position + 8 <= boundary
        tag = decode_tag_at(binary, position)
        break unless tag
        position += 4
        _vr, length, header_size = decode_vr_length_at(binary, position, tag)
        position += header_size
        if tag == SEQUENCE_DELIMITER
          break
        elsif tag == ITEM_TAG
          if length >= 0
            position += length
          else
            position = skip_undefined_item(binary, position, boundary)
          end
        else
          break
        end
      end
      return position
    end

    # Decodes a tag at the given position assuming little endian encoding.
    #
    def decode_tag_at(binary, position)
      bytes = binary[position, 4]
      return nil unless bytes && bytes.length == 4
      group, element = bytes.unpack("v2")
      format("%04X,%04X", group, element)
    end

    # Decodes VR and value length at the given position for an explicit little
    # endian data element. Returns [vr, length, header_size_consumed].
    #
    def decode_vr_length_at(binary, position, tag)
      if ITEM_TAGS.include?(tag)
        length = binary[position, 4].unpack1("V")
        return [ITEM_VR, length, 4]
      end
      vr = binary[position, 2]
      position += 2
      if %w[OB OW OF SQ UN UT].include?(vr)
        length = binary[position + 2, 4].unpack1("V")
        [vr, length, 8]
      else
        length = binary[position, 2].unpack1("v")
        [vr, length, 4]
      end
    end

    # Converts an Element's value to an Integer regardless of its encoding.
    #
    def integer_value(element)
      return 0 unless element
      case element.value
        when Integer then element.value
        when String then element.value.to_i
        when nil then element.bin ? element.bin.unpack1("V") : 0
        else element.value.to_i
      end
    end

    # Sets a top level data element to the given value, creating it if needed.
    #
    def set_top_value(tag, new_value)
      if exists?(tag)
        self[tag].value = new_value
      else
        add_element(tag, new_value)
      end
    end

    # Encodes the complete DICOMDIR to a binary string while recalculating
    # all directory record link offsets.
    #
    # @param [Hash] options the options used for encoding (see #to_binary)
    # @return [String] the encoded DICOMDIR binary string
    #
    def write_dicomdir(options={})
      @write_success = false
      prepare_for_write unless options[:ignore_meta]
      records = ordered_records(options)
      # Make sure each record carries its four mandatory link elements.
      records.each { |record| ensure_record_elements(record) }
      # Ensure the root entity offset elements exist with placeholder values
      # before measuring the prefix length (their presence affects the
      # position of the first directory record).
      set_top_value(FIRST_ROOT_RECORD_TAG, 0)
      set_top_value(LAST_ROOT_RECORD_TAG, 0)
      # Determine the position of the first record relative to the file meta
      # information origin (start of the file meta group, i.e. after preamble).
      meta = encode_meta_group
      first_item_start = meta.length + encode_group4_prefix.length + SQ_HEADER_LENGTH
      # Compute the encoded size of every record with placeholder link values.
      sizes = Hash.new
      records.each do |record|
        sizes[record] = ITEM_HEADER_LENGTH + encode_record_body(record).length
      end
      # Assign physical offsets in the chosen arrangement.
      offsets = Hash.new
      cursor = first_item_start
      records.each do |record|
        offsets[record] = cursor
        cursor += sizes[record]
      end
      # Patch the next/lower-level link values of every record.
      assign_link_offsets(records, offsets)
      finalize_root_offsets(records, offsets)
      # Rebuild the Directory Record Sequence to mirror the physical record order.
      rebuild_record_sequence(records)
      # Re-encode the prefix with the finalized root offset values.
      prefix = encode_group4_prefix
      encoded = encode_signature + meta + prefix
      encoded += encode_directory_sequence(records)
      encoded += encode_group4_suffix
      @write_success = true
      return encoded
    end

    # Ensures the mandatory meta information identifies this object as a Media
    # Storage Directory encoded with Explicit VR Little Endian.
    #
    def prepare_for_write
      set_top_value("0002,0002", MEDIA_STORAGE_DIRECTORY_SOP_CLASS)
      set_top_value("0002,0010", EXPLICIT_LITTLE_ENDIAN)
      insert_missing_meta
    end

    # Returns the physical record order to use for writing.
    #
    def ordered_records(options)
      if options[:record_order]
        ordered = Array(options[:record_order])
        if ordered.sort_by(&:object_id) != flatten_records.sort_by(&:object_id)
          raise ArgumentError, "The given record order does not contain the exact records of the directory tree."
        end
        ordered
      else
        flatten_records
      end
    end

    # Makes sure a record Item contains the four mandatory link/type elements.
    #
    def ensure_record_elements(record)
      { NEXT_RECORD_TAG => 0, RECORD_IN_USE_TAG => 65535, LOWER_LEVEL_RECORD_TAG => 0, RECORD_TYPE_TAG => record.type.to_s }.each do |tag, default|
        Element.new(tag, default, :parent => record.item) unless record.item.exists?(tag)
      end
    end

    # Assigns the next-sibling and lower-level child offsets to every record.
    #
    def assign_link_offsets(records, offsets)
      records.each do |record|
        following = record.parent ? record.next_record : @records[@records.index(record) + 1]
        record.item[NEXT_RECORD_TAG].value = following ? offsets[following] : 0
        first_child = record.children.first
        record.item[LOWER_LEVEL_RECORD_TAG].value = first_child ? offsets[first_child] : 0
      end
    end

    # Sets the root directory entity's first/last record offset elements.
    # The last root record is the final sibling of the root level chain
    # (not necessarily the physically last record, since it may have children).
    #
    def finalize_root_offsets(records, offsets)
      first_root = @records.first
      last_root = @records.last
      self[FIRST_ROOT_RECORD_TAG].value = first_root ? offsets[first_root] : 0
      self[LAST_ROOT_RECORD_TAG].value = last_root ? offsets[last_root] : 0
    end

    # Rebuilds the in-memory Directory Record Sequence so that its Items match
    # the physical record order used for writing.
    #
    def rebuild_record_sequence(records)
      delete(DIRECTORY_RECORD_SEQUENCE_TAG) if exists?(DIRECTORY_RECORD_SEQUENCE_TAG)
      sequence = Sequence.new(DIRECTORY_RECORD_SEQUENCE_TAG, :parent => self)
      records.each { |record| sequence.add_item(record.item) }
      return sequence
    end

    # Encodes the 128 byte preamble and the 'DICM' signature.
    #
    def encode_signature
      "\000" * 128 + "DICM"
    end

    # Encodes the complete file meta information group (0002,xxxx) using
    # explicit little endian encoding, including the group length element.
    #
    # @return [String] the encoded file meta group
    #
    def encode_meta_group
      elements = group(META_GROUP).reject { |element| element.tag == "0002,0000" }
      body = elements.map { |element| encode_element(element) }.join
      length_bin = encode_plain_element("0002,0000", "UL", [body.length].pack("L<"))
      return length_bin + body
    end

    # Encodes the top level group 0004 elements located before the Directory
    # Record Sequence (sorted by tag).
    #
    # @return [String] the encoded prefix elements
    #
    def encode_group4_prefix
      elements = children.select do |element|
        element.tag.group == "0004" && element.tag < DIRECTORY_RECORD_SEQUENCE_TAG
      end
      elements.map { |element| encode_element(element) }.join
    end

    # Encodes the top level elements located after the Directory Record Sequence.
    #
    # @return [String] the encoded suffix elements
    #
    def encode_group4_suffix
      elements = children.select do |element|
        element.tag.group != META_GROUP && element.tag != DIRECTORY_RECORD_SEQUENCE_TAG && element.tag > DIRECTORY_RECORD_SEQUENCE_TAG
      end
      elements.map { |element| encode_element(element) }.join
    end

    # Encodes the Directory Record Sequence header and its record Items in
    # physical order, using defined length encoding throughout.
    #
    # @return [String] the encoded Directory Record Sequence
    #
    def encode_directory_sequence(records)
      item_strings = records.map do |record|
        body = encode_record_body(record)
        encode_item_header(body.length) + body
      end
      value = item_strings.join
      header = encode_tag(DIRECTORY_RECORD_SEQUENCE_TAG) + ["SQ"].pack("a2") + "\000\000".b + [value.length].pack("L<")
      return header + value
    end

    # Encodes the data elements of a record Item, sorted by tag (the four
    # link/type elements consequently appear first).
    #
    # @return [String] the encoded record Item value
    #
    def encode_record_body(record)
      record.item.children.map { |element| encode_element(element) }.join
    end

    # Encodes an ordinary data element, sequence or item using explicit little
    # endian, defined length encoding.
    #
    # @return [String] the encoded element
    #
    def encode_element(element)
      if element.is_a?(Sequence)
        encode_sequence(element)
      elsif element.is_a?(Item)
        body = element.children.map { |child| encode_element(child) }.join
        encode_item_header(body.length) + body
      else
        encode_plain_element(element.tag, element.vr, element.bin.to_s)
      end
    end

    # Encodes a sequence (explicit VR, defined length) with all of its items.
    #
    def encode_sequence(sequence)
      body = sequence.children.map do |item|
        item_body = item.children.map { |child| encode_element(child) }.join
        encode_item_header(item_body.length) + item_body
      end.join
      vr = sequence.vr == "SQ" ? "SQ" : sequence.vr
      encode_tag(sequence.tag) + [vr].pack("a2") + "\000\000".b + [body.length].pack("L<") + body
    end

    # Encodes a leaf data element from a pre-encoded binary value.
    #
    # @return [String] the encoded data element
    #
    def encode_plain_element(tag, vr, value_bin)
      if %w[OB OW OF SQ UN UT].include?(vr)
        encode_tag(tag) + [vr].pack("a2") + "\000\000".b + [value_bin.length].pack("L<") + value_bin
      else
        encode_tag(tag) + [vr].pack("a2") + [value_bin.length].pack("S<") + value_bin
      end
    end

    # Encodes an Item header with a defined length.
    #
    def encode_item_header(length)
      encode_tag(ITEM_TAG) + [length].pack("L<")
    end

    # Encodes a tag to four little endian bytes (group then element number).
    #
    def encode_tag(tag)
      group = tag[0..3].to_i(16)
      element_number = tag[5..8].to_i(16)
      [group, element_number].pack("v2")
    end

  end

end
