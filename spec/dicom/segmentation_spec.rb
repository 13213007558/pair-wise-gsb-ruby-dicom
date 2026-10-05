# encoding: UTF-8

require 'spec_helper'

module DICOM

  describe Segmentation do

    let(:reference_one) { reference_image('1.2.3.1', 3.0) }
    let(:reference_two) { reference_image('1.2.3.2', 7.0) }

    def reference_image(instance_uid, z_position)
      dcm = DObject.new
      {
        '0008,0016' => ['1.2.840.10008.5.1.4.1.1.2', 'UI'],
        '0008,0018' => [instance_uid, 'UI'],
        '0020,000D' => ['1.2.3.study', 'UI'],
        '0020,000E' => ['1.2.3.series', 'UI'],
        '0020,0052' => ['1.2.3.frame-of-reference', 'UI'],
        '0028,0010' => [3, 'US'],
        '0028,0011' => [5, 'US']
      }.each do |tag, (value, vr)|
        dcm.add(Element.new(tag, value, :vr => vr))
      end
      dcm.add(Element.new('0020,0032', "0\\0\\#{z_position}", :vr => 'DS'))
      dcm.add(Element.new('0020,0037', '1\\0\\0\\0\\1\\0', :vr => 'DS'))
      dcm.add(Element.new('0028,0030', '0.5\\0.25', :vr => 'DS'))
      dcm
    end

    def roundtrip(segmentation, references)
      written = segmentation.to_dcm
      path = File.join(DICOM::TMPDIR, "segmentation-#{object_id}-#{segmentation.object_id}.dcm")
      written.write(path)
      read = DObject.read(path)
      Segmentation.new(read, nil, :references => references)
    end

    it 'preserves shuffled binary frames, padding bits and source references' do
      masks = [
        [1,0,1, 0,1,0, 1,1,0, 0,0,1, 1,0,0],
        [0,1,0, 1,0,1, 0,0,1, 1,1,0, 0,1,0],
        [1,1,0, 0,0,1, 1,0,0, 0,1,0, 1,0,1]
      ]
      frames = [
        { :segment_number => 2, :mask => masks[0], :reference => reference_one },
        { :segment_number => 1, :mask => masks[1], :reference => reference_two },
        { :segment_number => 2, :mask => masks[2], :reference => reference_one, :reference_frame_number => 2 }
      ]
      segmentation = Segmentation.build(frames, :type => 'BINARY')
      expect(segmentation.binary_mask(2, 0)).to eq masks[0].map { |value| value == 1 }
      reparsed = roundtrip(segmentation, [reference_one, reference_two])

      expect(reparsed.type).to eq 'BINARY'
      expect(reparsed.frames.map(&:segment_number)).to eq [2, 1, 2]
      expect(reparsed.mask(2, 0)).to eq masks[0]
      expect(reparsed.mask(1, 0)).to eq masks[1]
      expect(reparsed.mask(2, 1)).to eq masks[2]
      expect(reparsed[2].map(&:frame_number)).to eq [1, 3]
      expect(reparsed.reference_image(2, 0)).to eq reference_one
      expect(reparsed.reference_image(1, 0)).to eq reference_two
      expect(reparsed.frames[2].reference_frame_number).to eq 2
      expect(reparsed.spatial_info(1, 0)).to include(
        :rows => 3,
        :columns => 5,
        :pixel_spacing => [0.5, 0.25],
        :image_position => [0.0, 0.0, 7.0],
        :image_orientation => [1.0, 0.0, 0.0, 0.0, 1.0, 0.0]
      )
      expect(reparsed.to_dcm['7FE0,0010'].bin.bytes).to eq [171, 24, 84, 228, 198, 42]
    end

    it 'preserves fractional values, maximum value and fractional type without sorting' do
      masks = [
        [0, 51, 127, 204, 255, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
        [255, 204, 127, 51, 0, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0],
        [10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150]
      ]
      frames = [
        { :segment_number => 1, :mask => masks[2], :reference => reference_one },
        { :segment_number => 2, :mask => masks[0], :reference => reference_two },
        { :segment_number => 1, :mask => masks[1], :reference => reference_one, :reference_frame_number => 3 }
      ]
      segmentation = Segmentation.build(
        frames,
        :type => 'FRACTIONAL',
        :fractional_type => Segmentation::PROBABILITY,
        :maximum_fractional_value => 255
      )
      reparsed = roundtrip(segmentation, [reference_one, reference_two])

      expect(reparsed.type).to eq 'FRACTIONAL'
      expect(reparsed.fractional_type).to eq 'PROBABILITY'
      expect(reparsed.maximum_fractional_value).to eq 255
      expect(reparsed.segment(1)[:maximum_fractional_value]).to eq 255
      expect(reparsed.frames.map(&:segment_number)).to eq [1, 2, 1]
      expect(reparsed.mask(1, 0)).to eq masks[2]
      expect(reparsed.mask(2, 0)).to eq masks[0]
      expect(reparsed.mask(1, 1)).to eq masks[1]
      expect(reparsed.fraction(1, 0).first(5)).to eq [10.0/255, 20.0/255, 30.0/255, 40.0/255, 50.0/255]
      expect(reparsed.reference_image(1, 1)).to eq reference_one
      expect(reparsed.spatial_info(2, 0)[:image_position]).to eq [0.0, 0.0, 7.0]
      expect(reparsed.to_dcm['7FE0,0010'].bin.bytes.first(15)).to eq masks[2]
    end

  end

end
