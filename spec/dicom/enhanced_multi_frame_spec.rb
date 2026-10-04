# encoding: UTF-8

require 'spec_helper'

module DICOM

  describe EnhancedMultiFrame do

    def build_enhanced_dcm(options={})
      dcm = DObject.new
      Element.new('0028,0008', options.fetch(:number_of_frames, 2).to_s, :parent => dcm)

      shared = Sequence.new('5200,9229', :parent => dcm)
      shared_item = Item.new(:parent => shared)
      unless options[:without_shared]
        pixel_measures = Sequence.new('0028,9110', :parent => shared_item)
        pixel_measures_item = Item.new(:parent => pixel_measures)
        Element.new('0028,0030', '0.5\\0.5', :parent => pixel_measures_item)
      end

      per_frame = Sequence.new('5200,9230', :parent => dcm)
      options.fetch(:per_frame_count, 2).times do |frame_index|
        frame_item = Item.new(:parent => per_frame)
        frame_content = Sequence.new('0020,9111', :parent => frame_item)
        frame_content_item = Item.new(:parent => frame_content)
        Element.new('0020,9453', "FRAME-#{frame_index + 1}", :parent => frame_content_item)
        index_value = options[:wrong_index_frame] == frame_index ? 99 : frame_index + 1
        Element.new('0020,9157', [index_value], :vr => 'UL', :parent => frame_content_item)
        Element.new('0020,9128', [frame_index + 1], :vr => 'UL', :parent => frame_content_item)

        plane_position = Sequence.new('0020,9113', :parent => frame_item)
        plane_position_item = Item.new(:parent => plane_position)
        Element.new('0020,0032', "0\\0\\#{frame_index + 1}", :parent => plane_position_item)

        if options[:overlapping_group]
          overlapping = Sequence.new('0028,9110', :parent => frame_item)
          Item.new(:parent => overlapping)
        end
      end

      unless options[:without_dimension_index]
        dimensions = Sequence.new('0020,9222', :parent => dcm)
        options.fetch(:dimension_count, 1).times do
          dimension_item = Item.new(:parent => dimensions)
          unless options[:missing_dimension_pointer]
            Element.new('0020,9165', '0020,9128', :vr => 'AT', :parent => dimension_item)
          end
          Element.new('0020,9167', '0020,9111', :vr => 'AT', :parent => dimension_item)
        end
      end
      dcm
    end

    describe "#enhanced_multi_frame" do

      it "provides frame views without decoding pixel data" do
        dcm = build_enhanced_dcm
        frames = dcm.frame_views

        expect(frames.length).to eql 2
        expect(dcm.exists?('7FE0,0010')).to be_falsey
        expect(frames.map(&:index)).to eql [0, 1]
      end

      it "reports whether each functional group is shared or per-frame" do
        frame = build_enhanced_dcm.enhanced_multi_frame.frame(1)

        expect(frame.source_for('0028,9110')).to eql :shared
        expect(frame.source_for('0020,9111')).to eql :per_frame
        expect(frame['0028,9110']).to be_shared
        expect(frame['0020,9111']).to be_per_frame
        expect(frame.shared_functional_groups.keys).to eql ['0028,9110']
        expect(frame.per_frame_functional_groups.keys).to eql ['0020,9111', '0020,9113']
      end

      it "exposes functional group contents from the original DICOM items" do
        frame = build_enhanced_dcm.enhanced_multi_frame.frame(0)

        expect(frame['0028,9110'].value('0028,0030')).to eql '0.5\\0.5'
        expect(frame.frame_label).to eql 'FRAME-1'
        expect(frame['0020,9113'].item['0020,0032'].value).to eql '0\\0\\1'
        expect(frame.functional_group_content('0020,9113').value('0020,0032')).to eql '0\\0\\1'
        expect(frame.functional_group_source('0020,9111')).to eql :per_frame
      end

      it "resolves dimension index coordinates through the index pointers" do
        frame = build_enhanced_dcm.enhanced_multi_frame.frame(1)

        expect(frame.dimension_index).to eql [2]
        expect(frame.dimension_index_coordinates).to eql '0020,9128' => 2
        expect(frame.dimension_index_values).to eql [['0020,9128', 2]]
      end

      it "supports enhanced frames without a dimension index sequence" do
        frame = build_enhanced_dcm(:without_dimension_index => true).enhanced_multi_frame.frame(0)

        expect(frame.dimension_index).to eql []
        expect(frame.dimension_index_coordinates).to eql Hash.new
        expect(frame.source_for('0028,9110')).to eql :shared
        expect(frame.source_for('0020,9113')).to eql :per_frame
      end

    end

    describe "validation" do

      it "rejects a mismatch between Number of Frames and the per-frame sequence length" do
        dcm = build_enhanced_dcm(:number_of_frames => 2, :per_frame_count => 3)

        expect { dcm.enhanced_multi_frame }.to raise_error(
          EnhancedMultiFrameError,
          /Per-frame Functional Groups Sequence \(5200,9230\) has 3 items but Number of Frames \(0028,0008\) is 2/
        )
      end

      it "rejects the same functional group in shared and per-frame items" do
        dcm = build_enhanced_dcm(:overlapping_group => true)

        expect { dcm.enhanced_multi_frame }.to raise_error(
          EnhancedMultiFrameError,
          /Frame 0: functional group 0028,9110 \(Pixel Measures Sequence\) appears in both/
        )
      end

      it "locates a dimension coordinate mismatch by frame and pointer" do
        dcm = build_enhanced_dcm(:wrong_index_frame => 1)

        expect { dcm.enhanced_multi_frame }.to raise_error(
          EnhancedMultiFrameError,
          /Frame 1: Dimension Index Pointer 0020,9128 from Dimension Index Sequence item 0 has value 2.*Dimension Index Values.*99/
        )
      end

      it "locates a missing dimension index pointer by descriptor item" do
        dcm = build_enhanced_dcm(:missing_dimension_pointer => true)

        expect { dcm.enhanced_multi_frame }.to raise_error(
          EnhancedMultiFrameError,
          /Dimension Index Sequence item 0: 0020,9165 \(Dimension Index Pointer\) is missing/
        )
      end

      it "locates a malformed functional group sequence by frame and tag" do
        dcm = build_enhanced_dcm
        Sequence.new('0018,9472', :parent => dcm['5200,9230'][0])

        expect { dcm.enhanced_multi_frame }.to raise_error(
          EnhancedMultiFrameError,
          /5200,9230 frame 0: functional group 0018,9472 \(Frame Display Shutter Sequence\) must contain exactly one item, got 0/
        )
      end

      it "rejects a request for a frame outside the validated range" do
        enhanced = build_enhanced_dcm.enhanced_multi_frame

        expect { enhanced.frame(2) }.to raise_error(
          EnhancedMultiFrameError,
          /Frame 2 is out of range. Expected 0 to 1/
        )
      end

    end

  end

end
