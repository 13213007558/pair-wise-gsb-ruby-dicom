# encoding: UTF-8

require 'spec_helper'


module DICOM

  describe Segmentation do

    # Common test data: 2 segments & 3 frames, where the frames are
    # deliberately NOT ordered by segment or by slice position.
    let(:segments) do
      [
        {:number => 1, :label => 'Tumor', :algorithm_type => 'SEMIAUTOMATIC'},
        {:number => 2, :label => 'Organ'}
      ]
    end

    let(:references) do
      [
        {:sop_class_uid => '1.2.840.10008.5.1.4.1.1.2', :sop_instance_uid => '1.2.3.4.5.100', :frame_number => 2},
        {:sop_class_uid => '1.2.840.10008.5.1.4.1.1.2', :sop_instance_uid => '1.2.3.4.5.200', :frame_number => 1},
        {:sop_class_uid => '1.2.840.10008.5.1.4.1.1.2', :sop_instance_uid => '1.2.3.4.5.100', :frame_number => 3}
      ]
    end

    let(:positions) do
      [
        [10.0, 20.0, 5.0],
        [10.0, 20.0, 1.0],
        [10.0, 20.0, 3.0]
      ]
    end

    # Frame order in the data set: segment 2 (z=5.0), segment 1 (z=1.0), segment 2 (z=3.0).
    def build_frames(masks)
      [
        {:segment => 2, :mask => masks[0], :position => positions[0], :referenced => references[0]},
        {:segment => 1, :mask => masks[1], :position => positions[1], :referenced => references[1]},
        {:segment => 2, :mask => masks[2], :position => positions[2], :referenced => references[2]}
      ]
    end

    def roundtrip(seg, file)
      seg.write(DICOM::TMPDIR + file)
      Segmentation.read(DICOM::TMPDIR + file)
    end


    context '::new' do

      it 'should raise ArgumentError when the given DICOM object is not a segmentation' do
        expect {Segmentation.new(DObject.new)}.to raise_error(ArgumentError)
      end

      it 'should raise ArgumentError when the argument is not a DObject' do
        expect {Segmentation.new('1.2.3')}.to raise_error(ArgumentError)
      end

    end


    context '::build' do

      it 'should raise ArgumentError when a FRACTIONAL segmentation lacks a maximum fractional value' do
        expect {
          Segmentation.build(:type => 'FRACTIONAL', :rows => 2, :columns => 2,
            :segments => [{:number => 1}],
            :frames => [{:segment => 1, :mask => [[0, 1], [1, 0]]}],
            :fractional_type => 'PROBABILITY')
        }.to raise_error(ArgumentError)
      end

      it 'should raise ArgumentError when a frame references an undefined segment' do
        expect {
          Segmentation.build(:rows => 2, :columns => 2,
            :segments => [{:number => 1}],
            :frames => [{:segment => 2, :mask => [[0, 1], [1, 0]]}])
        }.to raise_error(ArgumentError)
      end

      it 'should raise ArgumentError when a frame mask does not match rows x columns' do
        expect {
          Segmentation.build(:rows => 2, :columns => 2,
            :segments => [{:number => 1}],
            :frames => [{:segment => 1, :mask => [[0, 1, 1], [1, 0, 1]]}])
        }.to raise_error(ArgumentError)
      end

    end


    context 'BINARY segmentations' do

      # 3x3 = 9 pixels per frame: each frame takes 2 bytes, i.e. the frames
      # do not fill an integral number of bytes.
      let(:masks) do
        [
          [[1, 0, 1], [0, 1, 0], [1, 0, 1]],
          [[0, 1, 0], [1, 1, 1], [0, 1, 0]],
          [[1, 1, 0], [0, 0, 1], [1, 0, 0]]
        ]
      end

      let(:seg) do
        Segmentation.build(
          :type => 'BINARY',
          :rows => 3,
          :columns => 3,
          :segments => segments,
          :frames => build_frames(masks),
          :pixel_spacing => [0.5, 0.75],
          :slice_thickness => 2.0,
          :orientation => [1, 0, 0, 0, 1, 0]
        )
      end

      it 'should bit-pack each frame to a whole number of bytes (9 pixels -> 2 bytes per frame)' do
        expect(seg.dcm['7FE0,0010'].bin.length).to eql 6
        expected = masks.collect {|m| [m.flatten.join].pack('b*') }.join
        expect(seg.dcm['7FE0,0010'].bin).to eql expected
      end

      it 'should record the image pixel attributes of a bit-packed segmentation' do
        expect(seg.dcm.value('0028,0100')).to eql 1
        expect(seg.dcm.value('0028,0101')).to eql 1
        expect(seg.dcm.value('0028,0008')).to eql '3'
        expect(seg.dcm.value('0008,0016')).to eql Segmentation::SOP_CLASS_UID
      end

      context 'after a write/read round-trip' do

        let(:rt) { roundtrip(seg, 'seg_binary.dcm') }

        it 'should preserve the segmentation type' do
          expect(rt.segmentation_type).to eql 'BINARY'
          expect(rt.maximum_fractional_value).to be_nil
          expect(rt.fractional_type).to be_nil
        end

        it 'should map frames to segments without assuming any frame ordering' do
          expect(rt.segment_numbers).to eql [1, 2]
          expect(rt.frames(1)).to eql [1]
          expect(rt.frames(2)).to eql [0, 2]
        end

        it 'should reproduce the frame masks bit by bit' do
          expect(rt.masks(1)).to eql [masks[1]]
          expect(rt.masks(2)).to eql [masks[0], masks[2]]
          expect(rt.mask(2, 0)).to eql masks[0]
          expect(rt.mask(2, 2)).to eql masks[2]
        end

        it 'should preserve the image references of each frame' do
          expect(rt.referenced_images(1)).to eql [references[1]]
          expect(rt.referenced_images(2)).to eql [references[0], references[2]]
          expect(rt.referenced_image(2, 0)).to eql references[0]
        end

        it 'should preserve the spatial information of each frame' do
          expect(rt.positions(1)).to eql [positions[1]]
          expect(rt.positions(2)).to eql [positions[0], positions[2]]
          expect(rt.position(1, 1)).to eql positions[1]
          expect(rt.orientation(1, 1)).to eql [1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
          expect(rt.orientations(2)).to eql [[1.0, 0.0, 0.0, 0.0, 1.0, 0.0]] * 2
          expect(rt.pixel_spacing).to eql [0.5, 0.75]
          expect(rt.slice_thickness).to eql 2.0
        end

        it 'should preserve the segment labels' do
          expect(rt.segment_label(1)).to eql 'Tumor'
          expect(rt.segment_label(2)).to eql 'Organ'
        end

        it 'should raise ArgumentError when querying an unknown segment' do
          expect {rt.frames(3)}.to raise_error(ArgumentError)
          expect {rt.masks(5)}.to raise_error(ArgumentError)
        end

        it 'should raise ArgumentError when querying a frame which belongs to another segment' do
          expect {rt.mask(1, 0)}.to raise_error(ArgumentError)
          expect {rt.referenced_image(2, 1)}.to raise_error(ArgumentError)
        end

      end

    end


    context 'FRACTIONAL segmentations' do

      let(:masks) do
        [
          [[0, 128, 255, 64], [32, 16, 8, 0]],
          [[255, 0, 127, 63], [31, 15, 7, 3]],
          [[1, 2, 3, 4], [5, 6, 7, 8]]
        ]
      end

      let(:seg) do
        Segmentation.build(
          :type => 'FRACTIONAL',
          :rows => 2,
          :columns => 4,
          :segments => segments,
          :frames => build_frames(masks),
          :maximum_fractional_value => 255,
          :fractional_type => 'PROBABILITY',
          :pixel_spacing => [0.5, 0.75],
          :orientation => [1, 0, 0, 0, 1, 0]
        )
      end

      context 'after a write/read round-trip' do

        let(:rt) { roundtrip(seg, 'seg_fractional.dcm') }

        it 'should preserve the maximum fractional value & fractional type' do
          expect(rt.segmentation_type).to eql 'FRACTIONAL'
          expect(rt.maximum_fractional_value).to eql 255
          expect(rt.fractional_type).to eql 'PROBABILITY'
        end

        it 'should reproduce the fractional pixel values exactly' do
          expect(rt.masks(1)).to eql [masks[1]]
          expect(rt.masks(2)).to eql [masks[0], masks[2]]
          expect(rt.mask(2, 2)).to eql masks[2]
        end

        it 'should preserve the image references of each frame' do
          expect(rt.referenced_images(1)).to eql [references[1]]
          expect(rt.referenced_images(2)).to eql [references[0], references[2]]
        end

        it 'should preserve the spatial information of each frame' do
          expect(rt.positions(2)).to eql [positions[0], positions[2]]
          expect(rt.orientation(1, 1)).to eql [1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
          expect(rt.pixel_spacing).to eql [0.5, 0.75]
        end

      end

      context 'with 16 bit pixels' do

        let(:seg) do
          Segmentation.build(
            :type => 'FRACTIONAL',
            :rows => 2,
            :columns => 2,
            :segments => [{:number => 1, :label => 'Tumor'}],
            :frames => [
              {:segment => 1, :mask => [[0, 500], [1000, 7]], :position => [0.0, 0.0, 1.0], :referenced => references[0]},
              {:segment => 1, :mask => [[1000, 0], [3, 42]], :position => [0.0, 0.0, 0.0], :referenced => references[1]}
            ],
            :maximum_fractional_value => 1000,
            :fractional_type => 'OCCUPANCY',
            :bits_allocated => 16
          )
        end

        it 'should preserve pixel values, maximum fractional value & fractional type through a round-trip' do
          rt = roundtrip(seg, 'seg_fractional_16bit.dcm')
          expect(rt.maximum_fractional_value).to eql 1000
          expect(rt.fractional_type).to eql 'OCCUPANCY'
          expect(rt.masks(1)).to eql [[[0, 500], [1000, 7]], [[1000, 0], [3, 42]]]
          expect(rt.referenced_images(1)).to eql [references[0], references[1]]
        end

      end

    end

  end

end
