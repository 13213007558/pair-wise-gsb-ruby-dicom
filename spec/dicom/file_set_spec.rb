# encoding: ASCII-8BIT

require 'spec_helper'

module DICOM

  describe FileSet do

    # Encodes an ordinary Explicit VR Little Endian data element.
    def element_bin(tag, vr, value)
      group, element_number = tag.split(',').map { |part| part.to_i(16) }
      bin = [group, element_number].pack('v2') + vr
      if %w(OB OW OF SQ UN UT).include?(vr)
        bin + "\x00\x00" + [value.length].pack('L<') + value
      else
        bin + [value.length].pack('v') + value
      end
    end

    def ul(value)
      [value].pack('L<')
    end

    def us(value)
      [value].pack('v')
    end

    # Builds the encoded body (elements 0004,1400/1410/1420/1430 and optional Referenced File ID)
    # of a single directory record.
    def record_body(type, file_id, next_offset, lower_offset)
      body = element_bin('0004,1400', 'UL', ul(next_offset))
      body << element_bin('0004,1410', 'US', us(0xFFFF))
      body << element_bin('0004,1420', 'UL', ul(lower_offset))
      body << element_bin('0004,1430', 'CS', type.ljust(8))
      if file_id
        value = file_id.join('\\')
        value << ' ' if value.length.odd?
        body << element_bin('0004,1500', 'CS', value)
      end
      body
    end

    def undefined_item(body)
      ITEM_HEADER_BIN + ul(-1) + body + ITEM_DELIMITER_HEADER_BIN + ul(0)
    end

    ITEM_HEADER_BIN = "\xFE\xFF\x00\xE0"
    ITEM_DELIMITER_HEADER_BIN = "\xFE\xFF\x0D\xE0"
    SEQUENCE_DELIMITER_HEADER_BIN = "\xFE\xFF\xDD\xE0"

    # Creates a DICOMDIR binary where the records are deliberately placed in a physical
    # order that differs from the logical directory tree. Offsets are still valid.
    def shuffled_dicomdir
      meta_ts = '1.2.840.10008.1.2.1'
      meta = element_bin('0002,0002', 'UI', '1.2.840.10008.1.3.10')
      meta << element_bin('0002,0010', 'UI', meta_ts.ljust(20, "\x00"))

      keys = [:image, :patient2, :study, :patient]
      info = {
        :image => ['IMAGE', ['DIR1', 'IMG1']],
        :patient2 => ['PATIENT', nil],
        :study => ['STUDY', nil],
        :patient => ['PATIENT', nil],
      }
      # A first pass with zero pointers gives every item its physical size.
      sizes = {}
      keys.each do |key|
        type, file_id = info[key]
        sizes[key] = undefined_item(record_body(type, file_id, 0, 0)).length
      end
      file_set_elements_placeholder = element_bin('0004,1200', 'UL', ul(0))
      file_set_elements_placeholder << element_bin('0004,1202', 'UL', ul(0))
      file_set_elements_placeholder << element_bin('0004,1212', 'US', us(0))
      sequence_header = [0x0004, 0x1220].pack('v2') + "SQ\x00\x00" + ul(-1)
      drs_content_start = meta.length + file_set_elements_placeholder.length + sequence_header.length

      positions = {}
      cursor = drs_content_start
      keys.each do |key|
        positions[key] = cursor
        cursor += sizes[key]
      end
      pointers = {
        :patient => [positions[:patient2], positions[:study]],
        :study => [0, positions[:image]],
        :image => [0, 0],
        :patient2 => [0, 0],
      }
      file_set_elements = element_bin('0004,1200', 'UL', ul(positions[:patient]))
      file_set_elements << element_bin('0004,1202', 'UL', ul(positions[:patient2]))
      file_set_elements << element_bin('0004,1212', 'US', us(0))
      items = ''.b
      keys.each do |key|
        type, file_id = info[key]
        nxt, lower = pointers[key]
        items << undefined_item(record_body(type, file_id, nxt, lower))
      end
      preamble = "\x00" * 128 + 'DICM'
      preamble + meta + file_set_elements + sequence_header + items + SEQUENCE_DELIMITER_HEADER_BIN + ul(0)
    end

    describe "::new" do

      it "should create an empty file set without root records" do
        fs = FileSet.new
        expect(fs.root_records).to be_empty
        expect(fs.records).to be_empty
      end

    end

    describe "::read / ::parse errors" do

      it "should reject a non-DICOMDIR DICOM object" do
        expect { FileSet.read(DICOM::DCM_IMPLICIT_MR_16BIT_MONO2) }.to raise_error(RuntimeError)
      end

      it "should reject invalid argument types" do
        expect { FileSet.read(42) }.to raise_error(ArgumentError)
        expect { FileSet.parse(42) }.to raise_error(ArgumentError)
      end

    end

    describe "#new_record" do

      it "should add a root record when no parent is given" do
        fs = FileSet.new
        record = fs.new_record('PATIENT')
        expect(record).to be_a DirectoryRecord
        expect(fs.root_records).to eq [record]
        expect(record.parent_record).to be_nil
      end

      it "should add a lower level record when a parent is given" do
        fs = FileSet.new
        patient = fs.new_record('PATIENT')
        study = fs.new_record('STUDY', patient)
        expect(patient.child_records).to eq [study]
        expect(study.parent_record).to eq patient
      end

    end

    describe "reading hierarchy" do

      it "should rebuild the tree even when records are physically shuffled" do
        fs = FileSet.parse(shuffled_dicomdir)
        expect(fs.root_records.map(&:type)).to eq %w(PATIENT PATIENT)
        expect(fs.records.map(&:type)).to eq %w(PATIENT STUDY IMAGE PATIENT)
        patient = fs.root_records.first
        study = patient.child_records.first
        expect(study.type).to eq 'STUDY'
        image = study.child_records.first
        expect(image.type).to eq 'IMAGE'
        expect(image.file_id).to eq ['DIR1', 'IMG1']
      end

    end

    describe "File ID" do

      it "should keep the Referenced File ID as a sequence of components" do
        fs = FileSet.new
        image = fs.new_record('IMAGE')
        image.file_id = ['SUBDIR1', 'SUBDIR2', 'IMAGE1']
        expect(image.file_id).to eq ['SUBDIR1', 'SUBDIR2', 'IMAGE1']
        expect(image['0004,1500'].value).to eq 'SUBDIR1\\SUBDIR2\\IMAGE1'
      end

      it "should reject components containing the component separator" do
        fs = FileSet.new
        image = fs.new_record('IMAGE')
        expect { image.file_id = ['A', 'B\\C'] }.to raise_error(ArgumentError)
      end

      it "should join components with the local file separator through #path_for" do
        fs = FileSet.new
        path = fs.path_for(['SUBDIR1', 'IMAGE1'], '/tmp/fileset')
        expect(path).to eq File.join('/tmp/fileset', 'SUBDIR1', 'IMAGE1')
      end

      it "should reject path separator characters in File ID components" do
        fs = FileSet.new
        expect { fs.path_for(['..', 'IMAGE1']) }.to raise_error(ArgumentError)
      end

    end

    describe "#write / offsets" do

      before do
        @fs = FileSet.new
        @fs.id = 'FILESET1'
        patient = @fs.new_record('PATIENT')
        patient.add_element('0010,0020', 'PAT001')
        study = @fs.new_record('STUDY', patient)
        series = @fs.new_record('SERIES', study)
        @image = @fs.new_record('IMAGE', series)
        @image.file_id = ['SUBDIR1', 'IMG1']
        @image2 = @fs.new_record('IMAGE', series)
        @image2.file_id = ['SUBDIR1', 'IMG2']
        @patient2 = @fs.new_record('PATIENT')
        @bin = @fs.to_binary
      end

      it "should encode a file beginning with the DICOM signature" do
        expect(@bin[0, 132]).to eq ("\x00" * 128 + 'DICM')
      end

      it "should place the root offsets on Item headers of root records" do
        scan = DirectoryScanner.scan(@bin)
        first = dcm_value(@bin, '0004,1200') + 132
        last = dcm_value(@bin, '0004,1202') + 132
        expect(first).to eq scan.item_offsets.first
        expect(last).to eq scan.item_offsets.last
        expect(@bin[first, 4]).to eq ITEM_HEADER_BIN
        expect(@bin[last, 4]).to eq ITEM_HEADER_BIN
      end

      it "should place next/lower offsets exactly on Item headers" do
        scan = DirectoryScanner.scan(@bin)
        dcm = DObject.parse(@bin)
        items = dcm['0004,1220'].children
        scan.item_offsets.each_with_index do |item_start, index|
          item = items[index]
          nxt = item.value('0004,1400')
          lower = item.value('0004,1420')
          if nxt > 0
            expect(@bin[nxt + 132, 4]).to eq ITEM_HEADER_BIN
            expect(scan.item_offsets).to include(nxt + 132)
          end
          if lower > 0
            expect(@bin[lower + 132, 4]).to eq ITEM_HEADER_BIN
            expect(scan.item_offsets).to include(lower + 132)
          end
        end
      end

      it "should write records in depth-first order with a correct hierarchy" do
        reread = FileSet.parse(@bin)
        expect(reread.records.map(&:type)).to eq %w(PATIENT STUDY SERIES IMAGE IMAGE PATIENT)
        expect(reread.root_records.size).to eq 2
        first = reread.root_records.first
        series_records = first.child_records.first.child_records.first
        expect(series_records.child_records.map(&:type)).to eq %w(IMAGE IMAGE)
        expect(series_records.child_records.first).to eq reread.records[3]
      end

      it "should normalize a shuffled physical layout on rewrite" do
        shuffled = FileSet.parse(shuffled_dicomdir)
        normalized = shuffled.to_binary
        reread = FileSet.parse(normalized)
        expect(reread.records.map(&:type)).to eq %w(PATIENT STUDY IMAGE PATIENT)
        expect(reread.records[2].file_id).to eq ['DIR1', 'IMG1']
      end

      it "should update offsets after inserting a sibling record" do
        reread = FileSet.parse(@bin)
        new_image = DirectoryRecord.new(:type => 'IMAGE', :file_set => reread)
        new_image.file_id = ['SUBDIR1', 'IMGMID']
        reread.records[3].insert_after(new_image)
        bin2 = reread.to_binary
        reread2 = FileSet.parse(bin2)
        series = reread2.root_records.first.child_records.first.child_records.first
        expect(series.child_records.map(&:file_id)).to eq [['SUBDIR1', 'IMG1'], ['SUBDIR1', 'IMGMID'], ['SUBDIR1', 'IMG2']]
        # The inserted next pointer must land on an Item header:
        dcm = DObject.parse(bin2)
        image_item = dcm['0004,1220'].children[3]
        expect(bin2[image_item.value('0004,1400') + 132, 4]).to eq ITEM_HEADER_BIN
      end

      it "should update offsets after removing a record subtree" do
        reread = FileSet.parse(@bin)
        reread.remove_record(reread.root_records.first)
        bin2 = reread.to_binary
        reread2 = FileSet.parse(bin2)
        expect(reread2.records.map(&:type)).to eq %w(PATIENT)
        expect(dcm_value(bin2, '0004,1200')).to eq dcm_value(bin2, '0004,1202')
      end

    end

    # Small helper that decodes a top-level UL/US element directly from the binary string.
    def dcm_value(bin, wanted_tag)
      scan = DirectoryScanner.scan(bin)
      position = wanted_tag == '0004,1200' ? scan.root_first_position : scan.root_last_position
      bin[position, 4].unpack('L<')[0]
    end

  end

end
