# encoding: UTF-8

require 'spec_helper'

module DICOM

  describe DicomDir do

    LONG_VRS = %w[OB OW OF SQ UN UT].freeze

    # Independent, minimal parser for the parts of a written DICOMDIR that
    # matter for offset verification. It does not use the library's own DICOM
    # reader, so an encoder bug can not be masked by a matching reader bug.
    class RawDicomDir

      def initialize(binary)
        @bin = binary
        @origin = binary.length >= 132 && binary[128, 4] == "DICM" ? 132 : 0
        @top = Hash.new
        @records = Array.new
        parse_top_level
      end

      attr_reader :records

      def first_root_offset
        @top["0004,1200"]
      end

      def last_root_offset
        @top["0004,1202"]
      end

      def top_value(tag)
        @top[tag]
      end

      # All link/root offsets must land exactly on an Item header (FFFE,E000).
      def offsets_point_at_item_headers?
        offsets = records.flat_map { |record| [record[:next], record[:lower]] }
        offsets << first_root_offset
        offsets << last_root_offset
        offsets.uniq.reject { |offset| offset == 0 }.all? do |offset|
          tag_at(@origin + offset) == ITEM_TAG
        end
      end

      # Every linked offset must resolve to one of the actual record offsets.
      def links_resolve_to_records?
        valid = records.map { |record| record[:offset] }
        records.all? do |record|
          (record[:next] == 0 || valid.include?(record[:next])) &&
            (record[:lower] == 0 || valid.include?(record[:lower]))
        end && (first_root_offset == 0 || valid.include?(first_root_offset))
      end

      # Follows next/lower links and returns [type, file_id] pairs in tree order.
      def linked_tree
        by_offset = Hash[records.map { |record| [record[:offset], record] }]
        result = Array.new
        collect(first_root_offset, by_offset, result)
        result
      end

      private

      def collect(offset, by_offset, result)
        while offset != 0 && record = by_offset[offset]
          result << [record[:type], record[:file_id]]
          collect(record[:lower], by_offset, result) unless record[:lower] == 0
          offset = record[:next]
        end
      end

      def tag_at(position)
        group, element = @bin[position, 4].unpack("v2")
        format("%04X,%04X", group, element)
      end

      # Reads one explicit little endian data element header at position.
      # Returns [tag, vr, length, header_size, value_position].
      def read_header(position)
        tag = tag_at(position)
        if ITEM_TAGS.include?(tag)
          length = @bin[position + 4, 4].unpack1("V")
          return [tag, "  ", length, 8, position + 8]
        end
        vr = @bin[position + 4, 2]
        if LONG_VRS.include?(vr)
          length = @bin[position + 8, 4].unpack1("V")
          [tag, vr, length, 12, position + 12]
        else
          length = @bin[position + 6, 2].unpack1("v")
          [tag, vr, length, 8, position + 8]
        end
      end

      def parse_top_level
        _tag, _vr, group_length, _h, position = read_header(@origin)
        position += group_length
        while position + 8 <= @bin.length
          tag, vr, length, _h, value_position = read_header(position)
          if tag == DIRECTORY_RECORD_SEQUENCE_TAG
            parse_records(value_position, length)
            break
          end
          if vr == "SQ"
            position = length >= 0 ? value_position + length : skip_undefined_sequence(value_position)
          else
            @top[tag] = decode_value(@bin[value_position, length], vr)
            position = value_position + length
          end
        end
      end

      def skip_undefined_sequence(position)
        loop do
          tag, _vr, length, _h, value_position = read_header(position)
          break if tag == SEQUENCE_DELIMITER
          position = length >= 0 ? value_position + length : skip_undefined_item(value_position)
        end
        position
      end

      def skip_undefined_item(position)
        loop do
          tag, vr, length, _h, value_position = read_header(position)
          break if tag == ITEM_DELIMITER
          position = vr == "SQ" && length < 0 ? skip_undefined_sequence(value_position) : value_position + [length, 0].max
        end
        position
      end

      def parse_records(start, sequence_length)
        position = start
        boundary = sequence_length >= 0 ? start + sequence_length : @bin.length
        while position + 8 <= boundary
          tag, _vr, item_length, _h, value_position = read_header(position)
          break unless tag == ITEM_TAG
          record = { :offset => position - @origin, :next => 0, :lower => 0, :type => nil, :file_id => nil }
          fill_record(value_position, item_length, record)
          @records << record
          position = value_position + item_length
        end
      end

      def fill_record(start, item_length, record)
        position = start
        boundary = start + item_length
        while position + 8 <= boundary
          tag, vr, length, _h, value_position = read_header(position)
          case tag
            when NEXT_RECORD_TAG then record[:next] = @bin[value_position, 4].unpack1("V")
            when LOWER_LEVEL_RECORD_TAG then record[:lower] = @bin[value_position, 4].unpack1("V")
            when RECORD_TYPE_TAG then record[:type] = @bin[value_position, length].rstrip
            when REFERENCED_FILE_ID_TAG then record[:file_id] = @bin[value_position, length].rstrip
          end
          position = value_position + length
        end
      end

      def decode_value(bin, vr)
        case vr
          when "UL" then bin.unpack1("V")
          when "US" then bin.unpack1("v")
          else bin.to_s.rstrip
        end
      end

    end

    # Builds a multi-level DICOMDIR tree:
    # PATIENT
    #   STUDY (S1)
    #     SERIES (S1/SER1)
    #       IMAGE (S1/SER1/IMG1)
    #       IMAGE (S1/SER1/IMG2)
    #   STUDY (S2)
    #     SERIES (S2/SER1)
    def build_directory
      dir = DicomDir.new
      dir.file_set_id = "RUBY_DICOM_TEST"
      patient = dir.add_record("PATIENT")
      patient.set_value("0010,0020", "PAT001")
      study1 = patient.add_record("STUDY")
      study1.file_id = ["S1"]
      series1 = study1.add_record("SERIES")
      series1.file_id = ["S1", "SER1"]
      image1 = series1.add_record("IMAGE")
      image1.file_id = ["S1", "SER1", "IMG1"]
      image1.set_value("0004,1511", "1.2.3.4.5.6")
      image2 = series1.add_record("IMAGE")
      image2.file_id = ["S1", "SER1", "IMG2"]
      study2 = patient.add_record("STUDY")
      study2.file_id = ["S2"]
      study2.add_record("SERIES").file_id = ["S2", "SER1"]
      dir
    end

    TREE_TYPES = %w[PATIENT STUDY SERIES IMAGE IMAGE STUDY SERIES].freeze
    TREE_FILE_IDS = [
      nil,
      "S1",
      "S1\\SER1",
      "S1\\SER1\\IMG1",
      "S1\\SER1\\IMG2",
      "S2",
      "S2\\SER1"
    ].freeze

    describe "::new" do

      it "should create an empty DICOMDIR with no records" do
        dir = DicomDir.new
        expect(dir.records).to eql Array.new
        expect(dir.record_count).to eql 0
      end

      it "should parse a DICOMDIR binary string and rebuild the directory tree" do
        dir = build_directory
        rebuilt = DicomDir.parse(dir.to_binary)
        expect(rebuilt).to be_a DicomDir
        expect(rebuilt.record_count).to eql 7
        expect(rebuilt.records.map(&:type)).to eql ["PATIENT"]
      end

    end

    describe "::read" do

      it "should read a written DICOMDIR file and return a DicomDir instance" do
        dir = build_directory
        file = DICOM::TMPDIR + "read_dir"
        dir.write(file)
        loaded = DicomDir.read(file)
        expect(loaded).to be_a DicomDir
        expect(loaded.read?).to be_truthy
        expect(loaded.record_count).to eql 7
      end

    end

    describe "DObject compatibility" do

      it "should be returned as a DicomDir when a DICOMDIR binary is parsed through DObject.parse" do
        binary = build_directory.to_binary
        dcm = DObject.parse(binary)
        expect(dcm).to be_a DicomDir
      end

      it "should identify itself with the Media Storage Directory SOP Class UID" do
        dcm = DObject.parse(build_directory.to_binary)
        expect(dcm.value("0002,0002")).to eql MEDIA_STORAGE_DIRECTORY_SOP_CLASS
      end

      it "should still return a plain DObject for a regular DICOM file" do
        dcm = DObject.read(DICOM::DCM_IMPLICIT_MR_16BIT_MONO2)
        expect(dcm.class).to eql DObject
      end

    end

    describe "directory tree" do

      before do
        @dir = DicomDir.parse(build_directory.to_binary)
      end

      it "should rebuild the correct root and lower-level hierarchy regardless of physical record order" do
        patient = @dir.records.first
        expect(patient.type).to eql "PATIENT"
        expect(patient.children.map(&:type)).to eql %w[STUDY STUDY]
        studies = patient.children
        expect(studies.first.children.map(&:type)).to eql ["SERIES"]
        series = studies.first.children.first
        expect(series.children.map(&:type)).to eql %w[IMAGE IMAGE]
        expect(studies.last.children.first.type).to eql "SERIES"
        expect(studies.last.children.first.children).to eql Array.new
      end

      it "should connect each record to the next sibling through the tree" do
        patient = @dir.records.first
        studies = patient.children
        expect(studies.first.next_record).to equal studies.last
        expect(studies.last.next_record).to be_nil
        images = studies.first.children.first.children
        expect(images.first.next_record).to equal images.last
      end

      it "should flatten the tree in depth-first order" do
        expect(@dir.flatten_records.map(&:type)).to eql TREE_TYPES
        expect(@dir.records_by_type("IMAGE").length).to eql 2
      end

    end

    describe "Referenced File ID" do

      before do
        @dir = DicomDir.parse(build_directory.to_binary)
      end

      it "should expose the Referenced File ID as a sequence of components, never as a system path" do
        image = @dir.records_by_type("IMAGE").first
        expect(image.file_id).to eql ["S1", "SER1", "IMG1"]
        expect(image.file_id).not_to include File::SEPARATOR
      end

      it "should round-trip a multi-component File ID with the backslash separator" do
        expect(@dir.records_by_type("IMAGE").last.file_id).to eql ["S1", "SER1", "IMG2"]
        expect(@dir.records_by_type("STUDY").first.file_id).to eql ["S1"]
      end

      it "should set the File ID from a component array using the DICOM backslash separator" do
        image = @dir.records_by_type("IMAGE").first
        image.file_id = ["NEW", "PATH", "FILE"]
        expect(image.item.value(REFERENCED_FILE_ID_TAG)).to eql "NEW\\PATH\\FILE"
        reread = DicomDir.parse(@dir.to_binary)
        expect(reread.records_by_type("IMAGE").first.file_id).to eql ["NEW", "PATH", "FILE"]
      end

      it "should return an empty array for a record without a Referenced File ID" do
        patient = @dir.records.first
        expect(patient.file_id).to eql Array.new
      end

    end

    describe "inserting records" do

      before do
        @dir = DicomDir.parse(build_directory.to_binary)
      end

      it "should insert a new root record" do
        @dir.add_record("PATIENT")
        expect(@dir.records.length).to eql 2
        reread = DicomDir.parse(@dir.to_binary)
        expect(reread.records.map(&:type)).to eql %w[PATIENT PATIENT]
      end

      it "should insert a child record and link it through the lower-level offset" do
        series = @dir.records_by_type("SERIES").last
        image = series.add_record("IMAGE")
        image.file_id = ["S2", "SER1", "NEW"]
        reread = DicomDir.parse(@dir.to_binary)
        last_series = reread.records.first.children.last.children.first
        expect(last_series.children.map(&:type)).to eql ["IMAGE"]
        expect(last_series.children.first.file_id).to eql ["S2", "SER1", "NEW"]
      end

      it "should insert at an explicit position among siblings" do
        patient = @dir.records.first
        extra = DirectoryRecord.new("STUDY")
        patient.add(extra, :index => 1)
        expect(patient.children.map(&:type)).to eql %w[STUDY STUDY STUDY]
        expect(patient.children[1]).to equal extra
      end

    end

    describe "deleting records" do

      before do
        @dir = DicomDir.parse(build_directory.to_binary)
      end

      it "should delete a leaf record and relink the siblings" do
        series = @dir.records.first.children.first.children.first
        images = series.children
        series.delete(images.last)
        reread = DicomDir.parse(@dir.to_binary)
        image_count = reread.records_by_type("IMAGE").length
        expect(image_count).to eql 1
        expect(reread.record_count).to eql 6
      end

      it "should delete a whole subtree by default" do
        patient = @dir.records.first
        first_study = patient.children.first
        patient.delete(first_study)
        reread = DicomDir.parse(@dir.to_binary)
        # The first study subtree (STUDY, SERIES, IMAGE, IMAGE) is removed,
        # leaving PATIENT and the second study subtree (STUDY, SERIES).
        expect(reread.record_count).to eql 3
        expect(reread.records.first.children.map(&:type)).to eql ["STUDY"]
      end

      it "should promote child records when deleting with keep_children" do
        patient = @dir.records.first
        first_study = patient.children.first
        patient.delete(first_study, :keep_children => true)
        reread = DicomDir.parse(@dir.to_binary)
        expect(patient.children.map(&:type)).to eql %w[SERIES STUDY]
        expect(reread.record_count).to eql 6
      end

    end

    describe "writing link offsets" do

      before do
        @dir = build_directory
      end

      it "should set the first and last root record offsets of the written file" do
        raw = RawDicomDir.new(@dir.to_binary)
        expect(raw.first_root_offset).to be > 0
        expect(raw.last_root_offset).to eql raw.first_root_offset
        expect(raw.top_value(FILE_SET_ID_TAG)).to eql "RUBY_DICOM_TEST"
      end

      it "should make every next/lower-level/root offset land on an Item header" do
        raw = RawDicomDir.new(@dir.to_binary)
        expect(raw.records.length).to eql 7
        expect(raw.offsets_point_at_item_headers?).to be_truthy
        expect(raw.links_resolve_to_records?).to be_truthy
      end

      it "should produce offsets that reconstruct the edited hierarchy" do
        raw = RawDicomDir.new(@dir.to_binary)
        expect(raw.linked_tree.map { |type, _| type }).to eql TREE_TYPES
        expect(raw.linked_tree.map { |_, file_id| file_id }).to eql TREE_FILE_IDS
      end

      it "should write zero root offsets for an empty file-set" do
        empty = DicomDir.new
        raw = RawDicomDir.new(empty.to_binary)
        expect(raw.first_root_offset).to eql 0
        expect(raw.last_root_offset).to eql 0
        expect(raw.records).to eql Array.new
      end

    end

    describe "shuffled physical record arrangement" do

      before do
        @dir = build_directory
      end

      it "should rebuild the tree from links even when records are physically shuffled" do
        shuffled = @dir.flatten_records.shuffle(random: Random.new(7))
        binary = @dir.to_binary(:record_order => shuffled)
        # The physical Item order really is shuffled.
        raw = RawDicomDir.new(binary)
        expect(raw.records.map { |record| record[:type] }).not_to eql TREE_TYPES
        # But the links still reconstruct the correct hierarchy.
        expect(raw.linked_tree.map { |type, _| type }).to eql TREE_TYPES
        expect(raw.linked_tree.map { |_, file_id| file_id }).to eql TREE_FILE_IDS
        expect(raw.offsets_point_at_item_headers?).to be_truthy
        expect(raw.links_resolve_to_records?).to be_truthy
        # And the high level reader restores the same editable tree.
        reread = DicomDir.parse(binary)
        expect(reread.record_count).to eql 7
        patient = reread.records.first
        expect(patient.children.length).to eql 2
        expect(patient.children.first.children.first.children.length).to eql 2
      end

      it "should verify each shuffled offset points exactly at the corresponding Item header" do
        orders = (1..5).map { |seed| @dir.flatten_records.shuffle(random: Random.new(seed)) }
        orders.each do |order|
          raw = RawDicomDir.new(@dir.to_binary(:record_order => order))
          expect(raw.offsets_point_at_item_headers?).to be_truthy
          expect(raw.linked_tree.map { |type, _| type }).to eql TREE_TYPES
        end
      end

    end

    describe "undefined length sequence" do

      it "should read a Directory Record Sequence encoded with undefined length" do
        binary = build_directory.to_binary
        drs_index = binary.index([0x0004, 0x1220].pack("v2"))
        length_position = drs_index + 8
        original_length = binary[length_position, 4].unpack1("V")
        undefined = binary.dup
        undefined[length_position, 4] = [0xFFFFFFFF].pack("V")
        delimiter = [0xFFFE, 0xE0DD].pack("v2") + [0].pack("V")
        insert_at = length_position + 4 + original_length
        undefined = undefined[0...insert_at] + delimiter + undefined[insert_at..-1]
        loaded = DicomDir.parse(undefined)
        expect(loaded.record_count).to eql 7
        expect(loaded.records.first.children.length).to eql 2
        # Rewriting normalizes back to a defined length sequence.
        rewritten = RawDicomDir.new(loaded.to_binary)
        expect(rewritten.linked_tree.map { |type, _| type }).to eql TREE_TYPES
      end

    end

  end

end
