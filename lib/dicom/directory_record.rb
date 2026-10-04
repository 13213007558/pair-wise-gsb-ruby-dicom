module DICOM

  # A DirectoryRecord represents one node of the editable directory tree of a DICOMDIR file set.
  #
  # A directory record is backed by an Item of the Directory Record Sequence (0004,1220).
  # In addition to the ordinary DICOM elements carried by the item, the record knows about its
  # position in the directory tree (parent record, sibling records and child records).
  #
  # The byte offsets that link records together (0004,1400 and 0004,1420) are not kept in sync
  # while the tree is edited: They are rebuilt from the tree structure when the file set is
  # written.
  #
  class DirectoryRecord < Item

    # The FileSet this record belongs to.
    attr_accessor :file_set

    # The next record on the same hierarchy level (a sibling), or nil if this is the last one.
    attr_accessor :next_record

    # The parent directory record, or nil for records that belong to the root directory entity.
    attr_reader :parent_record

    # Creates a directory record.
    #
    # @param [Hash] options the options to use for creating the record
    # @option options [String] :type the Directory Record Type (0004,1430), e.g. 'PATIENT'
    # @option options [FileSet] :file_set the file set this record belongs to
    # @option options [DirectoryRecord] :parent_record the record one level up in the directory tree
    # @option options [Boolean] :in_use the Record In-use Flag (0004,1410); defaults to true (0xFFFF)
    #
    def initialize(options={})
      super(:name => "Directory Record")
      @file_set = options[:file_set]
      @parent_record = nil
      @next_record = nil
      @first_child = nil
      # Mandatory directory record elements (offsets are placeholders until the file set is written):
      Element.new(DIRECTORY_RECORD_NEXT_TAG, 0, :parent => self)
      Element.new(DIRECTORY_RECORD_IN_USE_TAG, options.fetch(:in_use, true) ? 0xFFFF : 0, :parent => self)
      Element.new(DIRECTORY_RECORD_LOWER_TAG, 0, :parent => self)
      self.type = options[:type] if options[:type]
      add_to_parent(options[:parent_record]) if options[:parent_record]
    end

    # Initializes a record instance around an Item that has already been parsed from a file.
    # Used internally by FileSet when reconstructing the directory tree.
    #
    # @param [Item] item the parsed directory record item
    # @param [FileSet] file_set the owning file set
    #
    def initialize_as_record(item, file_set)
      initialize_parent
      @tag = ITEM_TAG
      @value = nil
      @bin = nil
      @vr = ITEM_VR
      @name = "Directory Record"
      @length = -1
      @file_set = file_set
      @parent_record = nil
      @next_record = nil
      @first_child = nil
      # Transfer the already parsed elements from the plain item to this record:
      item.children.each do |element|
        @tags[element.tag] = element
        element.set_parent(self)
      end
      # Ensure the structural elements exist even for non-conforming files:
      [DIRECTORY_RECORD_NEXT_TAG, DIRECTORY_RECORD_IN_USE_TAG, DIRECTORY_RECORD_LOWER_TAG].each do |tag|
        Element.new(tag, 0, :parent => self) unless exists?(tag)
      end
    end

    # Adds a child record as the last record of the next (lower) directory level.
    #
    # @param [DirectoryRecord] record the child record to attach
    # @return [DirectoryRecord] the record that was attached
    #
    def add_record(record)
      record.remove if record.parent_record
      record.set_parent_record(self)
      if @first_child
        child_records.last.next_record = record
      else
        @first_child = record
      end
      return record
    end

    # Gives all records on the level directly below this record, in order.
    #
    # @return [Array<DirectoryRecord>] the child records (empty array if childless)
    #
    def child_records
      records = Array.new
      record = @first_child
      while record
        records << record
        record = record.next_record
      end
      return records
    end

    # Returns self. Allows DirectoryRecord and Item instances to be treated uniformly.
    #
    # @return [DirectoryRecord] self
    #
    def to_directory_record
      self
    end

    # The Referenced File ID as an array of file ID components within the file set.
    #
    # File IDs are component sequences (PS3.10, Section 7): They must never be assembled
    # with arbitrary operating system separators. Use FileSet#path_for to build a local
    # file system path.
    #
    # @return [Array<String>] the file ID components (empty array if no file is referenced)
    #
    def file_id
      element = self[REFERENCED_FILE_ID_TAG]
      return Array.new unless element && element.value && element.value.length > 0
      return element.value.split(COMPONENT_SEPARATOR)
    end

    # Sets the Referenced File ID from an array of file ID components.
    #
    # @param [Array<String>] components the components of the file ID
    # @return [Array<String>] the components that were assigned
    #
    def file_id=(components)
      components = Array(components)
      components.each do |component|
        valid = component.is_a?(String) && component.length > 0 && component !~ /[^A-Z0-9_]/
        raise ArgumentError, "Invalid File ID component: #{component.inspect}. Components must be non-empty strings made up of uppercase letters, digits and underscore." unless valid
      end
      if components.empty?
        delete(REFERENCED_FILE_ID_TAG)
      else
        value = components.join(COMPONENT_SEPARATOR)
        if exists?(REFERENCED_FILE_ID_TAG)
          self[REFERENCED_FILE_ID_TAG].value = value
        else
          Element.new(REFERENCED_FILE_ID_TAG, value, :parent => self)
        end
      end
      return components
    end

    # Iterates this record and every record below it in pre-order (depth first).
    #
    # @yield [DirectoryRecord] each record of the subtree
    #
    def each_record
      yield self
      child_records.each { |child| child.each_record { |record| yield record } }
    end

    # The first record on the level below this record, or nil if there are no child records.
    #
    # @return [DirectoryRecord, NilClass] the first child record
    #
    def first_child_record
      @first_child
    end

    # Checks whether the record carries the in-use flag (0xFFFF).
    #
    # @return [Boolean] true if the record is marked as in use
    #
    def in_use?
      element = self[DIRECTORY_RECORD_IN_USE_TAG]
      element ? element.value == 0xFFFF : true
    end

    # Marks the record as in use (0xFFFF) or released (0x0000).
    #
    # @param [Boolean] status the desired in-use status
    #
    def in_use=(status)
      value = status ? 0xFFFF : 0
      if exists?(DIRECTORY_RECORD_IN_USE_TAG)
        self[DIRECTORY_RECORD_IN_USE_TAG].value = value
      else
        Element.new(DIRECTORY_RECORD_IN_USE_TAG, value, :parent => self)
      end
    end

    # Inserts a new sibling record immediately after this record.
    #
    # @param [DirectoryRecord] record the sibling record to insert
    # @return [DirectoryRecord] the record that was inserted
    #
    def insert_after(record)
      record.remove if record.parent_record
      record.set_parent_record(@parent_record)
      record.next_record = @next_record
      @next_record = record
      return record
    end

    # The byte offset of the first lower-level record (0004,1420).
    #
    # @return [Integer] the lower-level offset as last read from file (0 until written/rewritten)
    #
    def lower_offset
      self[DIRECTORY_RECORD_LOWER_TAG] ? self[DIRECTORY_RECORD_LOWER_TAG].value : 0
    end

    # The byte offset of the next sibling record (0004,1400).
    #
    # @return [Integer] the next-record offset as last read from file (0 until written/rewritten)
    #
    def next_offset
      self[DIRECTORY_RECORD_NEXT_TAG] ? self[DIRECTORY_RECORD_NEXT_TAG].value : 0
    end

    # Detaches this record (and its subtree) from the directory tree.
    #
    # The record itself and all of its descendants are returned for the caller to keep or discard.
    #
    # @return [DirectoryRecord] the detached record
    #
    def remove
      if @parent_record
        siblings = @parent_record.child_records
        index = siblings.index(self)
        raise "Directory record tree is inconsistent." unless index
        if index == 0
          @parent_record.set_first_child(@next_record)
        else
          siblings[index - 1].next_record = @next_record
        end
      elsif @file_set
        @file_set.remove_root(self)
      end
      @parent_record = nil
      @next_record = nil
      return self
    end

    # Gives every record in the subtree as a flat array in pre-order.
    #
    # @return [Array<DirectoryRecord>] the records of the subtree
    #
    def subtree_records
      records = Array.new
      each_record { |record| records << record }
      return records
    end

    # The Directory Record Type (0004,1430), e.g. PATIENT, STUDY, SERIES or IMAGE.
    #
    # @return [String, NilClass] the record type
    #
    def type
      self[DIRECTORY_RECORD_TYPE_TAG] ? self[DIRECTORY_RECORD_TYPE_TAG].value : nil
    end

    # Sets the Directory Record Type (0004,1430).
    #
    # @param [String] new_type the record type
    #
    def type=(new_type)
      if exists?(DIRECTORY_RECORD_TYPE_TAG)
        self[DIRECTORY_RECORD_TYPE_TAG].value = new_type
      else
        Element.new(DIRECTORY_RECORD_TYPE_TAG, new_type, :parent => self)
      end
    end

    protected

    # Walks the sibling chain starting at this record and assigns this record as the parent
    # record of each lower-level entry. Used when rebuilding a tree from on-disk offsets.
    #
    def assign_parents_from_links
      child = @first_child
      while child
        # Siblings share this parent; each sibling then assigns parents within its own subtree:
        child.send(:set_parent_record, self)
        child.first_child_record.send(:assign_parents_from_links) if child.first_child_record
        child = child.next_record
      end
    end

    # Stores the lower-level and sibling links decoded from a file.
    #
    def link_pointers(child, sibling)
      @first_child = child
      @next_record = sibling
    end

    # Links this record to a new parent without modifying the parent's child chain.
    # Used internally while restructuring the tree.
    #
    def set_parent_record(record)
      @parent_record = record
      @file_set ||= record.file_set if record
    end

    # Replaces the first child pointer. Used internally while restructuring the tree.
    #
    def set_first_child(record)
      @first_child = record
    end

    private

    # Appends this record to the child chain of the given parent.
    #
    def add_to_parent(parent)
      parent.add_record(self)
    end

  end

end
