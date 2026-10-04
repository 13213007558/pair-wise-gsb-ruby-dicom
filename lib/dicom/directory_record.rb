module DICOM

  # The DirectoryRecord class represents a single node of the directory tree
  # stored in the Directory Record Sequence (0004,1220) of a DICOMDIR file.
  #
  # A directory record is an Item in the Directory Record Sequence, but in
  # contrast to a plain Sequence, its records are physically flattened in the
  # DICOMDIR file and linked together by byte offsets:
  # * Offset of the Next Directory Record (0004,1400) links sibling records.
  # * Offset of Referenced Lower-Level Directory Entity (0004,1420) links
  #   a record to the first record of its child level.
  #
  # DirectoryRecord instances rebuild these links into an editable tree
  # (accessible through #children/#parent). When the DICOMDIR is written,
  # the links are flattened again and the offsets are recalculated from the
  # physical layout of the output file.
  #
  class DirectoryRecord

    # The record type string (Directory Record Type, 0004,1430), e.g. 'PATIENT'.
    attr_reader :type
    # The parent DirectoryRecord (nil for records at the root directory entity level).
    attr_reader :parent
    # The Item instance which carries the remaining data elements of this record.
    attr_reader :item

    # Creates a DirectoryRecord instance.
    #
    # @param [String] type the Directory Record Type (0004,1430), e.g. 'PATIENT', 'STUDY', 'SERIES' or 'IMAGE'
    # @param [Hash] options the options to use for creating the record
    # @option options [Item] :item an existing Item whose elements this record shall represent
    # @option options [DirectoryRecord] :parent the parent record of this new record
    # @example Create a patient level record
    #   patient = DICOM::DirectoryRecord.new('PATIENT')
    #
    def initialize(type, options={})
      @type = type
      @children = Array.new
      @parent = nil
      if options[:item]
        @item = options[:item]
        sync_type
      else
        @item = build_item
      end
      add_to_parent(options[:parent]) if options[:parent]
    end

    # Adds an existing DirectoryRecord as the last child record of self.
    #
    # @param [DirectoryRecord] record the child record to attach
    # @param [Hash] options the options to use when adding the child
    # @option options [Integer] :index if specified, inserts the child at this position among the children
    # @return [DirectoryRecord] the record that was added
    #
    def add(record, options={})
      raise ArgumentError, "Expected DirectoryRecord, got #{record.class}." unless record.is_a?(DirectoryRecord)
      record.parent.delete(record) if record.parent && record.parent != self
      index = options[:index]
      if index
        # The record may already be present (e.g. when it was created with self
        # as its parent). Remove that implicit placement before reinserting.
        @children.delete(record) if index
        raise ArgumentError, "The specified index (#{index}) is out of range." if index < 0 or index > @children.length
        @children.insert(index, record)
      else
        @children << record unless @children.include?(record)
      end
      record.set_parent(self)
      return record
    end

    # Creates and attaches a child record.
    #
    # @param [String] type the Directory Record Type of the new child record
    # @param [Hash] options the options to use for creating the child record (see DirectoryRecord.new)
    # @return [DirectoryRecord] the newly created child record
    # @example Add a study record to a patient record
    #   study = patient.add_record('STUDY')
    #
    def add_record(type, options={})
      index = options[:index]
      record_options = options.dup
      record_options.delete(:index)
      record_options[:parent] = self
      record = DirectoryRecord.new(type, record_options)
      if index
        @children.delete(record)
        add(record, :index => index)
      end
      record
    end

    # Retrieves all child records of self (records of the lower level).
    #
    # @return [Array<DirectoryRecord>] the child records (an empty array if self is childless)
    #
    def children
      @children.dup
    end

    # Checks if the record has any child records.
    #
    # @return [Boolean] true if at least one child record exists
    #
    def children?
      @children.length > 0
    end

    # Gives the number of child records directly attached to self.
    #
    # @return [Integer] the number of child records
    #
    def count
      @children.length
    end

    # Gives the total number of records in the subtree rooted at self (including self).
    #
    # @return [Integer] the number of records in the subtree
    #
    def count_all
      total = 1
      @children.each { |child| total += child.count_all }
      return total
    end

    # Retrieves the child records matching a specific record type.
    #
    # @param [String] type the Directory Record Type to match (case insensitive), e.g. 'SERIES'
    # @return [Array<DirectoryRecord>] the matching child records
    #
    def children_by_type(type)
      @children.select { |child| child.type.to_s.upcase == type.to_s.upcase }
    end

    # Removes a child record (and, by default, the complete subtree below it).
    #
    # @param [DirectoryRecord] record the child record to remove
    # @param [Hash] options the options to use when removing the record
    # @option options [Boolean] :keep_children when true, the child records of the removed record are reattached to self instead of being discarded
    # @return [DirectoryRecord, nil] the removed record, or nil if no match was made
    #
    def delete(record, options={})
      insertion_index = @children.index(record)
      removed = @children.delete(record)
      if removed
        if options[:keep_children]
          grandchildren = removed.children
          grandchildren.each { |grandchild| grandchild.set_parent(self) }
          @children.insert(insertion_index, *grandchildren)
        else
          record.detach_subtree
        end
        record.set_parent(nil)
      end
      return removed
    end

    # Iterates over the child records.
    #
    def each(&block)
      @children.each(&block)
    end

    # Iterates over every record in the subtree rooted at self in pre-order
    # (depth-first), yielding self before each of its descendants.
    #
    def each_record
      yield self
      @children.each { |child| child.each_record { |record| yield record } }
      return nil
    end

    # Flattens the subtree rooted at self into an array, in pre-order
    # (depth-first) traversal order. This is the physical record order used
    # in the Directory Record Sequence of a DICOMDIR file.
    #
    # @return [Array<DirectoryRecord>] the records of the subtree in physical order
    #
    def flatten
      records = [self]
      @children.each { |child| records.concat(child.flatten) }
      return records
    end

    # Retrieves the Referenced File ID (0004,1500) as an array of file-set
    # path components. The Referenced File ID identifies a file relative to
    # the file-set root using backslash (\\) as separator. It is deliberately
    # returned as a component sequence instead of an operating system path.
    #
    # @return [Array<String>] the file ID components (an empty array if no file is referenced)
    #
    def file_id
      raw = value(REFERENCED_FILE_ID_TAG)
      raw ? raw.to_s.split('\\') : Array.new
    end

    # Sets the Referenced File ID (0004,1500) from an array of file-set path
    # components. The components are joined with the backslash (\\) separator
    # mandated by the DICOM standard, without involving any operating system
    # specific path separators.
    #
    # @param [Array<String>, String] components a sequence of file ID components, or a raw file ID string
    # @return [Array<String>] the file ID components that were assigned
    # @example Point a record at a DICOM file in the file-set
    #   image.file_id = ['STUDY01', 'SERIES01', 'IMAGE01']
    #
    def file_id=(components)
      raw = case components
        when Array then components.join('\\')
        when String then components
        else raise ArgumentError, "Expected Array or String, got #{components.class}."
      end
      set_value(REFERENCED_FILE_ID_TAG, raw)
      return file_id
    end

    # Retrieves the next sibling record in the directory tree (or nil if self is the last sibling).
    #
    # @return [DirectoryRecord, nil] the following sibling record
    #
    def next_record
      if @parent
        siblings = @parent.children
        index = siblings.index(self)
        return siblings[index + 1]
      else
        return nil
      end
    end

    # Gives the index of self among its parent's child records.
    #
    # @return [Integer] the zero based index (0 for records at the root level)
    #
    def level_index
      @parent ? @parent.children.index(self) : 0
    end

    # Gives the root records reached through the lower-level link of self,
    # which is the same as #children.
    #
    # @return [Array<DirectoryRecord>] the lower level records
    #
    def lower_level
      children
    end

    # Sets the Directory Record Type (0004,1430).
    #
    # @param [String] new_type the new record type string
    #
    def type=(new_type)
      @type = new_type
      set_value(RECORD_TYPE_TAG, new_type)
    end

    # Retrieves the value of a data element belonging to this record's Item.
    #
    # @param [String] tag a ruby-dicom element tag string
    # @return [String, Integer, Float, NilClass] the element value (or nil)
    #
    def value(tag)
      @item.exists?(tag) ? @item.value(tag) : nil
    end

    # Adds or updates a data element on this record's Item.
    #
    # @param [String] tag a ruby-dicom element tag string
    # @param [String, Integer, Float] new_value the value to assign to the element
    # @return [Element] the data element that was created or updated
    #
    def set_value(tag, new_value)
      if @item.exists?(tag)
        @item[tag].value = new_value
        element = @item[tag]
      else
        element = Element.new(tag, new_value, :parent => @item)
      end
      @type = new_value if tag == RECORD_TYPE_TAG
      return element
    end


    # Sets the parent reference of self without modifying the parent's child array.
    # This is intended for internal tree management.
    #
    # @param [DirectoryRecord, nil] new_parent the new parent record
    #
    def set_parent(new_parent)
      @parent = new_parent
    end

    # Detaches the subtree rooted at self from its parent. The internal
    # structure of the detached subtree (self and all descendants) is kept
    # intact so that a removed record remains a coherent subtree (and can be
    # reattached elsewhere).
    #
    def detach_subtree
      @parent = nil
    end


    private

    # Attaches self to a parent record at initialization.
    #
    def add_to_parent(parent)
      parent.add(self)
    end

    # Builds a brand new Item carrying the four mandatory directory record
    # data elements (with zero/empty default link values).
    #
    # @return [Item] the created Item
    #
    def build_item
      item = Item.new
      Element.new(NEXT_RECORD_TAG, 0, :parent => item)
      Element.new(RECORD_IN_USE_TAG, 65535, :parent => item)
      Element.new(LOWER_LEVEL_RECORD_TAG, 0, :parent => item)
      Element.new(RECORD_TYPE_TAG, @type.to_s, :parent => item)
      return item
    end

    # Refreshes the record type attribute from the underlying Item's Directory Record Type element.
    #
    def sync_type
      @type = value(RECORD_TYPE_TAG)
    end

  end

end
