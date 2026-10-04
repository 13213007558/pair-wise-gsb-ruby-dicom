module DICOM

  # A FileSet provides read and write support for DICOMDIR files (the Media Storage Directory).
  #
  # The flat Directory Record Sequence (0004,1220) of a parsed DICOMDIR is recreated as an
  # editable tree of DirectoryRecord instances. Records can be inserted and removed freely;
  # when the file set is written, the directory records are serialized in depth-first order
  # and every next-record pointer (0004,1400), lower-level pointer (0004,1420) and root
  # directory entity pointer (0004,1200/0004,1202) is recomputed from the tree.
  #
  # @example Read a DICOMDIR, add an image record and write it back
  #   fs = DICOM::FileSet.read('DICOMDIR')
  #   series = fs.records.find { |r| r.type == 'SERIES' }
  #   image = DICOM::DirectoryRecord.new(:type => 'IMAGE', :parent_record => series)
  #   image.file_id = ['SUBDIR1', 'SUBDIR2', 'IMAGE1']
  #   fs.write('DICOMDIR')
  #
  class FileSet

    include Logging

    # The underlying DObject holding the file meta information and file set identification elements.
    attr_reader :dcm

    # Creates a FileSet instance by reading and parsing a DICOMDIR file.
    #
    # The physical order of the directory records in the file is irrelevant: The hierarchy is
    # always reconstructed from the next/lower-level byte offsets.
    #
    # @param [String] file the path of the DICOMDIR file to read
    # @return [FileSet] the parsed file set
    #
    def self.read(file)
      raise ArgumentError, "Invalid argument 'file'. Expected String, got #{file.class}." unless file.is_a?(String)
      dcm = DObject.read(file)
      raise "Failed to read DICOMDIR file: #{file}" unless dcm.read?
      raise "The file #{file} is not a DICOMDIR (Media Storage Directory)." unless dcm.value('0002,0002') == MEDIA_STORAGE_DIRECTORY_SOP_CLASS
      bin = File.open(file, 'rb') { |f| f.read }
      fs = self.new(:dcm => dcm)
      fs.send(:build_tree, bin)
      return fs
    end

    # Creates a FileSet from an encoded DICOMDIR binary string.
    #
    # @param [String] string the DICOMDIR binary string
    # @return [FileSet] the parsed file set
    #
    def self.parse(string)
      raise ArgumentError, "Invalid argument 'string'. Expected String, got #{string.class}." unless string.is_a?(String)
      dcm = DObject.parse(string)
      raise "Failed to parse this string as a DICOMDIR." unless dcm.read?
      raise "This string is not a DICOMDIR (Media Storage Directory)." unless dcm.value('0002,0002') == MEDIA_STORAGE_DIRECTORY_SOP_CLASS
      fs = self.new(:dcm => dcm)
      fs.send(:build_tree, string)
      return fs
    end

    # Creates an empty file set, optionally taking ownership of an existing DICOMDIR DObject.
    #
    # @param [Hash] options the options to use for creating the file set
    # @option options [DObject] :dcm an existing DObject to use as the file set carrier
    #
    def initialize(options={})
      @dcm = options[:dcm] || DObject.new
      @roots = Array.new
    end

    # Appends a record as the last root-level record of the directory tree.
    #
    # @param [DirectoryRecord] record the record to add at root level
    # @return [DirectoryRecord] the record that was added
    #
    def add_record(record)
      raise ArgumentError, "Invalid argument 'record'. Expected DirectoryRecord, got #{record.class}." unless record.is_a?(DirectoryRecord)
      record.remove if record.parent_record
      record.send(:set_parent_record, nil)
      record.file_set = self
      @roots.last.next_record = record if @roots.any?
      @roots << record
      return record
    end

    # The File-set ID (0004,1130), if defined.
    #
    # @return [String, NilClass] the file set ID
    #
    def id
      @dcm.value(FILE_SET_ID_TAG)
    end

    # Sets the File-set ID (0004,1130).
    #
    # @param [String] new_id the file set ID
    #
    def id=(new_id)
      set_file_set_element(FILE_SET_ID_TAG, new_id)
    end

    # Creates a DirectoryRecord and adds it to the tree.
    #
    # @param [String] type the Directory Record Type (0004,1430), e.g. 'PATIENT'
    # @param [DirectoryRecord, NilClass] parent the parent record, or nil for a root-level record
    # @return [DirectoryRecord] the newly created record
    #
    def new_record(type, parent=nil)
      record = DirectoryRecord.new(:type => type, :file_set => self)
      if parent
        parent.add_record(record)
      else
        add_record(record)
      end
      return record
    end

    # Joins file ID components into a path for the local file system.
    #
    # The Referenced File ID is a sequence of components within the file set and must not be
    # confused with an operating system path. Components are validated and joined using the
    # local file separator; the root of the file set can be supplied separately.
    #
    # @param [Array<String>] components the file ID components
    # @param [String] root an optional local directory that the file set is rooted in
    # @return [String] a local file system path
    #
    def path_for(components, root=nil)
      components = Array(components)
      components.each do |component|
        valid = component.is_a?(String) && component.length > 0 && component !~ /[^A-Z0-9_]/
        raise ArgumentError, "Invalid File ID component: #{component.inspect}. Only uppercase letters, digits and underscore are allowed within the file set." unless valid
      end
      File.join(*([root].compact + components))
    end

    # Gives all records of the directory tree in pre-order (root records first, depth first).
    #
    # @return [Array<DirectoryRecord>] every record reachable from the root directory entity
    #
    def records
      all = Array.new
      @roots.each { |record| record.subtree_records.each { |r| all << r } }
      return all
    end

    # Removes a record (along with its subtree) from the directory tree.
    #
    # @param [DirectoryRecord] record the record to remove
    # @return [DirectoryRecord] the removed record
    #
    def remove_record(record)
      raise ArgumentError, "Invalid argument 'record'. Expected DirectoryRecord, got #{record.class}." unless record.is_a?(DirectoryRecord)
      record.remove
    end

    # Removes the given record from the root-level chain. Called by DirectoryRecord#remove.
    #
    # @param [DirectoryRecord] record the root record to remove
    #
    def remove_root(record)
      index = @roots.index(record)
      if index
        previous = index > 0 ? @roots[index - 1] : nil
        following = @roots[index + 1]
        previous.next_record = following if previous
        @roots.delete_at(index)
      end
    end

    # Gives the records attached directly to the root directory entity, in order.
    #
    # @return [Array<DirectoryRecord>] the root records
    #
    def root_records
      @roots.dup
    end

    # Encodes the file set to a DICOMDIR binary string.
    #
    # All directory record offsets are recomputed from the current tree structure.
    #
    # @return [String] the encoded DICOMDIR binary string
    #
    def to_binary
      ordered = records
      rebuild_sequence(ordered)
      prepare_meta
      bin = @dcm.send(:encode_in_segments, 1 << 28, :syntax => EXPLICIT_LITTLE_ENDIAN).first
      # Prepend the 128 byte preamble and 'DICM' prefix (directory offsets are measured relative
      # to the first byte after this prefix):
      bin = SIGNATURE + bin
      patch_offsets(bin, ordered)
      return bin
    end

    # Writes the file set to a DICOMDIR file.
    #
    # @param [String] file_name the path of the file to write
    # @return [Boolean] true if the file was written successfully
    #
    def write(file_name)
      raise ArgumentError, "Invalid file_name. Expected String, got #{file_name.class}." unless file_name.is_a?(String)
      File.open(file_name, 'wb') { |f| f.write(to_binary) }
      @dcm.source = file_name
      return true
    end

    private

    # The 128 zero bytes followed by 'DICM' that introduce every DICOM file.
    SIGNATURE = ("\x00" * 128) + "DICM"

    # Reconstructs the editable record tree from the next/lower-level offsets of an encoded DICOMDIR.
    #
    # @param [String] bin the encoded DICOMDIR binary string
    #
    def build_tree(bin)
      sequence = @dcm[DIRECTORY_RECORD_SEQUENCE_TAG]
      return unless sequence && sequence.children?
      scan = DirectoryScanner.scan(bin)
      # On-disk offsets are relative to the byte after the 'DICM' prefix (byte 132 of the file):
      offset_base = bin.slice(128, 4) == 'DICM' ? 132 : 0
      items = sequence.children
      records = Hash.new
      items.each_with_index do |item, index|
        record = DirectoryRecord.allocate
        record.send(:initialize_as_record, item, self)
        records[scan.item_offsets[index]] = record
      end
      # Rebuild the tree from the pointer offsets. Physical item order is irrelevant:
      items.each_with_index do |item, index|
        record = records[scan.item_offsets[index]]
        lower = item.value(DIRECTORY_RECORD_LOWER_TAG) || 0
        nxt = item.value(DIRECTORY_RECORD_NEXT_TAG) || 0
        record.send(:link_pointers, records[lower == 0 ? nil : lower + offset_base], records[nxt == 0 ? nil : nxt + offset_base])
      end
      # Second pass: Now that every sibling chain is connected, parent records can be assigned:
      items.each_with_index do |item, index|
        record = records[scan.item_offsets[index]]
        record.send(:assign_parents_from_links)
      end
      # The root chain starts at the first root directory entity offset (0004,1200):
      first_root_offset = @dcm.value(ROOT_RECORD_FIRST_TAG)
      record = records[first_root_offset == 0 ? nil : first_root_offset + offset_base]
      while record
        @roots << record
        record.send(:set_parent_record, nil)
        record = record.next_record
      end
    end

    # Directory offsets are measured from the first byte following the 128 byte preamble and
    # the 4-byte 'DICM' prefix.
    PREAMBLE_LENGTH = 132

    # Patches the next/lower-level/root pointer values in the encoded binary string.
    #
    # @param [String] bin the encoded DICOMDIR binary string (mutated in place)
    # @param [Array<DirectoryRecord>] ordered the records in their physical (pre-order) order
    #
    def patch_offsets(bin, ordered)
      scan = DirectoryScanner.scan(bin)
      offset_by_record = Hash.new
      # Key on object identity: DirectoryRecord inherits Item's state-based hash, which changes
      # as pointer values are updated and therefore cannot serve as a stable Hash key here.
      ordered.each_with_index { |record, index| offset_by_record[record.object_id] = scan.item_offsets[index] }
      ordered.each_with_index do |record, index|
        item_offset = scan.item_offsets[index]
        next_offset = record.next_record ? relative(offset_by_record[record.next_record.object_id]) : 0
        lower_offset = record.first_child_record ? relative(offset_by_record[record.first_child_record.object_id]) : 0
        patch_value(bin, scan.value_offsets[item_offset][DIRECTORY_RECORD_NEXT_TAG], next_offset)
        patch_value(bin, scan.value_offsets[item_offset][DIRECTORY_RECORD_LOWER_TAG], lower_offset)
        record[DIRECTORY_RECORD_NEXT_TAG].value = next_offset
        record[DIRECTORY_RECORD_LOWER_TAG].value = lower_offset
      end
      first_root_position = @roots.first ? offset_by_record[@roots.first.object_id] : nil
      last_root_position = @roots.last ? offset_by_record[@roots.last.object_id] : nil
      patch_value(bin, scan.root_first_position, first_root_position ? relative(first_root_position) : 0)
      patch_value(bin, scan.root_last_position, last_root_position ? relative(last_root_position) : 0)
      set_file_set_element(ROOT_RECORD_FIRST_TAG, first_root_position ? relative(first_root_position) : 0)
      set_file_set_element(ROOT_RECORD_LAST_TAG, last_root_position ? relative(last_root_position) : 0)
    end

    # Overwrites a 4-byte UL value at the given binary position.
    #
    # @param [String] bin the binary string to modify
    # @param [Integer] position byte offset of the value within the binary string
    # @param [Integer] value the new UL value
    #
    def patch_value(bin, position, value)
      raise "Unable to locate directory pointer while writing DICOMDIR." unless position
      bin[position, 4] = [value || 0].pack('L<')
    end

    # Converts an absolute file byte position to a directory offset (relative to File Meta Information).
    #
    # @param [Integer, NilClass] position absolute byte position
    # @return [Integer] the relative directory offset
    #
    def relative(position)
      position - PREAMBLE_LENGTH
    end

    # Ensures the file meta information identifies this object as a Media Storage Directory.
    #
    def prepare_meta
      @dcm.add_element('0002,0002', MEDIA_STORAGE_DIRECTORY_SOP_CLASS) unless @dcm.exists?('0002,0002')
      @dcm.add_element('0002,0003', "#{UID_ROOT}.#{$$}.#{Time.now.to_i}.#{rand(0xFFFFFF)}") unless @dcm.exists?('0002,0003')
      @dcm.transfer_syntax = EXPLICIT_LITTLE_ENDIAN
      @dcm.send(:insert_missing_meta)
    end

    # Rebuilds the flat Directory Record Sequence in the physical (pre-order) layout.
    #
    # @param [Array<DirectoryRecord>] ordered the records in pre-order
    # @return [Sequence] the rebuilt sequence
    #
    def rebuild_sequence(ordered)
      @dcm.delete(DIRECTORY_RECORD_SEQUENCE_TAG)
      ensure_file_set_elements
      sequence = Sequence.new(DIRECTORY_RECORD_SEQUENCE_TAG, :parent => @dcm)
      ordered.each do |record|
        # Reset pointer values to placeholder zeros: The real offsets are patched in after encoding.
        record[DIRECTORY_RECORD_NEXT_TAG].value = 0
        record[DIRECTORY_RECORD_LOWER_TAG].value = 0
        record.set_parent(nil)
        record.index = nil
        sequence.add_item(record)
      end
      return sequence
    end

    # Ensures the mandatory file set elements around the Directory Record Sequence exist.
    #
    def ensure_file_set_elements
      set_file_set_element(FILE_SET_CONSISTENCY_TAG, 0) unless @dcm.exists?(FILE_SET_CONSISTENCY_TAG)
      set_file_set_element(ROOT_RECORD_FIRST_TAG, 0) unless @dcm.exists?(ROOT_RECORD_FIRST_TAG)
      set_file_set_element(ROOT_RECORD_LAST_TAG, 0) unless @dcm.exists?(ROOT_RECORD_LAST_TAG)
    end

    # Sets or creates a plain file set identification element on the underlying DObject.
    #
    # @param [String] tag the element tag
    # @param [Object] value the element value
    #
    def set_file_set_element(tag, value)
      if @dcm.exists?(tag)
        @dcm[tag].value = value
      else
        @dcm.add_element(tag, value)
      end
    end

  end

end
