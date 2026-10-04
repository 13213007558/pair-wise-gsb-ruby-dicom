# encoding: UTF-8

require 'spec_helper'


module DICOM

  describe FrameView do

    # Builds an enhanced multi-frame DObject with the given number of frames.
    # Shared functional groups: Plane Position Sequence (0020,9113).
    # Per-frame functional groups: Frame Content Sequence (0020,9111) with
    # Dimension Index Values, and Plane Orientation Sequence (0020,9116).
    def build_enhanced_dcm(frames, options={})
      dcm = DObject.new
      dcm.add(Element.new('0028,0008', frames.to_s))
      # Shared functional groups:
      shared = Sequence.new('5200,9229', :parent => dcm)
      shared_item = Item.new(:parent => shared)
      plane_position = Sequence.new('0020,9113', :parent => shared_item)
      position_item = Item.new(:parent => plane_position)
      position_item.add(Element.new('0020,0032', "0.0\\0.0\\0.0"))
      # Per-frame functional groups:
      per_frame = Sequence.new('5200,9230', :parent => dcm)
      frames.times do |i|
        frame_item = Item.new(:parent => per_frame)
        frame_content = Sequence.new('0020,9111', :parent => frame_item)
        content_item = Item.new(:parent => frame_content)
        content_item.add(Element.new('0020,9157', options[:div] ? options[:div].call(i) : [1, i + 1]))
        orientation = Sequence.new('0020,9116', :parent => frame_item)
        orientation_item = Item.new(:parent => orientation)
        orientation_item.add(Element.new('0020,0037', "1.0\\0.0\\0.0\\0.0\\1.0\\0.0"))
      end
      # Dimension Index Sequence (two dimensions):
      dimension_index = Sequence.new('0020,9222', :parent => dcm)
      dim1 = Item.new(:parent => dimension_index)
      dim1.add(Element.new('0020,9165', '0020,0032'))
      dim1.add(Element.new('0020,9167', '0020,9113'))
      dim1.add(Element.new('0020,9421', 'Position'))
      dim2 = Item.new(:parent => dimension_index)
      dim2.add(Element.new('0020,9165', '0020,0037'))
      dim2.add(Element.new('0020,9167', '0020,9116'))
      dcm
    end

    context "::new" do

      it "should raise ArgumentError when the dcm argument is not a DObject" do
        expect {FrameView.new('asdf', 0)}.to raise_error(ArgumentError)
      end

      it "should raise ArgumentError when the index argument is not an Integer" do
        dcm = build_enhanced_dcm(2)
        expect {FrameView.new(dcm, '1')}.to raise_error(ArgumentError)
      end

      it "should raise FrameViewError when the object lacks the Per-frame Functional Groups Sequence" do
        dcm = DObject.new
        dcm.add(Element.new('0028,0008', '2'))
        expect {FrameView.new(dcm, 0)}.to raise_error(FrameViewError, /5200,9230/)
      end

      it "should raise FrameViewError when Number of Frames is missing" do
        dcm = build_enhanced_dcm(2)
        dcm.delete('0028,0008')
        expect {FrameView.new(dcm, 0)}.to raise_error(FrameViewError, /0028,0008/)
      end

      it "should raise FrameViewError when the per-frame sequence length doesn't match Number of Frames" do
        dcm = build_enhanced_dcm(3)
        dcm['0028,0008'].value = '2'
        expect {FrameView.new(dcm, 0)}.to raise_error(FrameViewError, /0028,0008.*5200,9230|5200,9230.*0028,0008/)
      end

      it "should raise FrameViewError when the Shared Functional Groups Sequence contains more than one item" do
        dcm = build_enhanced_dcm(2)
        Item.new(:parent => dcm['5200,9229'])
        expect {FrameView.new(dcm, 0)}.to raise_error(FrameViewError, /5200,9229/)
      end

      it "should raise FrameViewError (localized to the frame) when the frame index is out of range" do
        dcm = build_enhanced_dcm(2)
        expect {FrameView.new(dcm, 2)}.to raise_error(FrameViewError, /Frame 2.*5200,9230/)
      end

      it "should raise FrameViewError when a Dimension Index Pointer is missing" do
        dcm = build_enhanced_dcm(2)
        dcm['0020,9222'][0].delete('0020,9165')
        expect {FrameView.new(dcm, 0)}.to raise_error(FrameViewError, /0020,9222.*0020,9165/)
      end

      it "should raise FrameViewError localized to the frame and tag when Dimension Index Values length mismatches" do
        dcm = build_enhanced_dcm(3, :div => lambda { |i| i == 1 ? [1] : [1, i + 1] })
        expect {FrameView.new(dcm, 1)}.to raise_error(FrameViewError, /Frame 1.*0020,9157/)
      end

      it "should set the dcm and index attributes" do
        dcm = build_enhanced_dcm(2)
        view = FrameView.new(dcm, 1)
        expect(view.dcm).to eql dcm
        expect(view.index).to eql 1
      end

      it "should work on an object without any pixel data (no pixel decoding required)" do
        dcm = build_enhanced_dcm(2)
        expect(dcm.exists?('7FE0,0010')).to be false
        view = FrameView.new(dcm, 0)
        expect(view.dimension_index_values).to eql [1, 1]
      end

    end

    context "::all" do

      it "should return a FrameView for each frame of the object" do
        dcm = build_enhanced_dcm(3)
        views = FrameView.all(dcm)
        expect(views.length).to eql 3
        expect(views.collect(&:index)).to eql [0, 1, 2]
      end

      it "should validate every frame" do
        dcm = build_enhanced_dcm(3, :div => lambda { |i| i == 2 ? [1] : [1, i + 1] })
        expect {FrameView.all(dcm)}.to raise_error(FrameViewError, /Frame 2/)
      end

    end

    context "::supported?" do

      it "should return true for an enhanced multi-frame object" do
        expect(FrameView.supported?(build_enhanced_dcm(1))).to be true
      end

      it "should return false for an object without per-frame functional groups" do
        expect(FrameView.supported?(DObject.new)).to be false
      end

    end

    context "#functional_groups" do

      it "should combine the shared and per-frame functional groups" do
        view = FrameView.new(build_enhanced_dcm(2), 0)
        expect(view.functional_group_tags.sort).to eql ['0020,9111', '0020,9113', '0020,9116']
      end

      it "should give access to the functional group sequence through #[]" do
        view = FrameView.new(build_enhanced_dcm(2), 0)
        expect(view['0020,9113']).to be_a(Sequence)
        expect(view['0020,9999']).to be_nil
      end

      it "should raise FrameViewError rather than silently merging when a functional group occurs in both levels" do
        dcm = build_enhanced_dcm(2)
        # Illegally add the Plane Position Sequence to the per-frame item of frame 1 as well:
        duplicate = Sequence.new('0020,9113', :parent => dcm['5200,9230'][1])
        Item.new(:parent => duplicate)
        expect {FrameView.new(dcm, 1).functional_groups}.to raise_error(FrameViewError, /Frame 1.*0020,9113.*5200,9229.*5200,9230/)
      end

      it "should not raise for a duplicate that only affects another frame" do
        dcm = build_enhanced_dcm(2)
        duplicate = Sequence.new('0020,9113', :parent => dcm['5200,9230'][1])
        Item.new(:parent => duplicate)
        expect(FrameView.new(dcm, 0).functional_group_tags.length).to eql 3
      end

    end

    context "functional group provenance" do

      it "should report a shared functional group as :shared" do
        view = FrameView.new(build_enhanced_dcm(2), 0)
        expect(view.source('0020,9113')).to eql :shared
        expect(view.shared?('0020,9113')).to be true
        expect(view.per_frame?('0020,9113')).to be false
      end

      it "should report a per-frame functional group as :per_frame" do
        view = FrameView.new(build_enhanced_dcm(2), 0)
        expect(view.source('0020,9116')).to eql :per_frame
        expect(view.per_frame?('0020,9116')).to be true
        expect(view.shared?('0020,9116')).to be false
      end

      it "should return nil for a functional group that is not present" do
        view = FrameView.new(build_enhanced_dcm(2), 0)
        expect(view.source('0028,9110')).to be_nil
      end

    end

    context "#value" do

      it "should extract an element value from a shared functional group" do
        view = FrameView.new(build_enhanced_dcm(2), 1)
        expect(view.value('0020,9113', '0020,0032')).to eql "0.0\\0.0\\0.0"
      end

      it "should extract an element value from a per-frame functional group" do
        view = FrameView.new(build_enhanced_dcm(2), 1)
        expect(view.value('0020,9116', '0020,0037')).to eql "1.0\\0.0\\0.0\\0.0\\1.0\\0.0"
      end

      it "should return nil for an unknown functional group" do
        view = FrameView.new(build_enhanced_dcm(2), 1)
        expect(view.value('0028,9110', '0018,0050')).to be_nil
      end

    end

    context "dimension index coordinates" do

      it "should give the Dimension Index Values of the frame" do
        dcm = build_enhanced_dcm(3)
        expect(FrameView.new(dcm, 0).dimension_index_values).to eql [1, 1]
        expect(FrameView.new(dcm, 2).dimension_index_values).to eql [1, 3]
      end

      it "should map the coordinates to their Dimension Index Pointer tags" do
        view = FrameView.new(build_enhanced_dcm(3), 1)
        expect(view.dimension_coordinates).to eql({'0020,0032' => 1, '0020,0037' => 2})
      end

      it "should describe each dimension with pointer, functional group, label, coordinate and value" do
        view = FrameView.new(build_enhanced_dcm(2), 0)
        dimensions = view.dimensions
        expect(dimensions.length).to eql 2
        expect(dimensions[0][:pointer]).to eql '0020,0032'
        expect(dimensions[0][:functional_group]).to eql '0020,9113'
        expect(dimensions[0][:label]).to eql 'Position'
        expect(dimensions[0][:coordinate]).to eql 1
        expect(dimensions[0][:value]).to eql "0.0\\0.0\\0.0"
        expect(dimensions[1][:pointer]).to eql '0020,0037'
        expect(dimensions[1][:coordinate]).to eql 1
        expect(dimensions[1][:value]).to eql "1.0\\0.0\\0.0\\0.0\\1.0\\0.0"
      end

      it "should handle a single dimension index value (returned as a scalar, not an array)" do
        dcm = DObject.new
        dcm.add(Element.new('0028,0008', '1'))
        per_frame = Sequence.new('5200,9230', :parent => dcm)
        frame_item = Item.new(:parent => per_frame)
        frame_content = Sequence.new('0020,9111', :parent => frame_item)
        content_item = Item.new(:parent => frame_content)
        content_item.add(Element.new('0020,9157', 5))
        dimension_index = Sequence.new('0020,9222', :parent => dcm)
        dim = Item.new(:parent => dimension_index)
        dim.add(Element.new('0020,9165', '0020,0032'))
        view = FrameView.new(dcm, 0)
        expect(view.dimension_index_values).to eql [5]
        expect(view.dimension_coordinates).to eql({'0020,0032' => 5})
      end

    end

    context "DObject frame view interface" do

      it "should create a frame view through DObject#frame_view" do
        dcm = build_enhanced_dcm(2)
        view = dcm.frame_view(1)
        expect(view).to be_a(FrameView)
        expect(view.index).to eql 1
      end

      it "should create all frame views through DObject#frame_views" do
        dcm = build_enhanced_dcm(3)
        expect(dcm.frame_views.collect(&:index)).to eql [0, 1, 2]
      end

    end

  end

end
