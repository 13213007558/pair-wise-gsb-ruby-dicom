# encoding: UTF-8

require 'spec_helper'

module DICOM

  describe RTSTRUCTMask do

    let(:axial_options) do
      {
        columns: 10,
        rows: 10,
        frames: 3,
        position: [-5.0, -5.0, 0.0],
        orientation: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0],
        spacing: [1.0, 1.0, 2.0]
      }
    end

    describe ".convert" do

      it "combines closed contours with XOR semantics so a hole remains unmasked" do
        outer = [
          [-4.0, -4.0, 0.0], [3.0, -4.0, 0.0], [3.0, 3.0, 0.0], [-4.0, 3.0, 0.0]
        ]
        inner = [
          [-1.0, -1.0, 0.0], [-1.0, 2.0, 0.0], [2.0, 2.0, 0.0], [2.0, -1.0, 0.0]
        ]

        result = RTSTRUCTMask.convert([outer, inner], axial_options)
        frame = result.mask.first

        expect(result.out_of_tolerance_contours).to be_empty
        expect(frame.flatten.count(1)).to eql 40
        expect(frame[1][1]).to eql 1
        expect(frame[3][3]).to eql 1
        expect(frame[4][4]).to eql 0
        expect(frame[6][6]).to eql 0
      end

      it "locates contours on an explicitly oriented tilted target plane" do
        s = Math.sqrt(2.0) / 2.0
        options = axial_options.merge(
          position: [-5.0, -5.0, 1.0],
          orientation: [s, 0.0, s, 0.0, 1.0, 0.0],
          spacing: [1.0, 1.0, Math.sqrt(2.0)]
        )
        # The tilted row direction changes both x and z; column follows y.
        contour = [
          [-5.0 + s, -3.0, 1.0 + s],
          [-5.0 + s, 3.0, 1.0 + s],
          [-5.0 + 7.0 * s, 3.0, 1.0 + 7.0 * s],
          [-5.0 + 7.0 * s, -3.0, 1.0 + 7.0 * s]
        ]

        result = RTSTRUCTMask.convert([contour], options)
        frame = result.mask.first

        expect(result.out_of_tolerance_contours).to be_empty
        expect(frame[2][2]).to eql 1
        expect(frame[2][7]).to eql 1
        expect(frame[6][2]).to eql 1
        expect(frame[6][7]).to eql 1
        expect(frame[0][2]).to eql 0
        expect(frame[8][2]).to eql 0
      end

      it "reports contours whose farthest point is beyond the target-plane tolerance" do
        contour = [
          [-2.0, -2.0, 0.0], [2.0, -2.0, 0.0], [2.0, 2.0, 0.6], [-2.0, 2.0, 0.0]
        ]

        result = RTSTRUCTMask.convert([contour], axial_options.merge(tolerance: 0.5))

        expect(result.mask.flatten).to all(eql 0)
        expect(result).to be_out_of_tolerance
        expect(result.out_of_tolerance_contours.first[:distance]).to be_within(1e-12).of(0.6)
      end

      it "does not infer slices from contour array order" do
        contour = [
          [-1.0, -1.0, 4.0], [1.0, -1.0, 4.0], [1.0, 1.0, 4.0], [-1.0, 1.0, 4.0]
        ]

        result = RTSTRUCTMask.convert([contour], axial_options)

        expect(result.mask[0].flatten).to all(eql 0)
        expect(result.mask[2][4][4]).to eql 1
      end

      it "uses the half-open boundary convention at voxel-center boundaries" do
        contour = [
          [-5.0, -5.0, 0.0], [-3.0, -5.0, 0.0], [-3.0, -3.0, 0.0], [-5.0, -3.0, 0.0]
        ]

        frame = RTSTRUCTMask.convert([contour], axial_options).mask.first

        expect(frame[0][0]).to eql 1
        expect(frame[0][1]).to eql 1
        expect(frame[1][0]).to eql 1
        expect(frame[1][1]).to eql 1
        expect(frame[0][2]).to eql 0
        expect(frame[2][0]).to eql 0
        expect(frame[2][2]).to eql 0
      end

      it "accepts contours whose final point repeats the first point" do
        contour = [
          [-1.0, -1.0, 4.0], [1.0, -1.0, 4.0], [1.0, 1.0, 4.0], [-1.0, 1.0, 4.0], [-1.0, -1.0, 4.0]
        ]

        result = RTSTRUCTMask.convert([contour], axial_options)

        expect(result.out_of_tolerance_contours).to be_empty
        expect(result.mask[2][4][4]).to eql 1
      end

      it "reports a contour outside the target frame range using the nearest real frame" do
        contour = [
          [-1.0, -1.0, 8.0], [1.0, -1.0, 8.0], [1.0, 1.0, 8.0], [-1.0, 1.0, 8.0]
        ]

        result = RTSTRUCTMask.convert([contour], axial_options)

        expect(result.mask.flatten).to all(eql 0)
        expect(result.out_of_tolerance_contours.first[:nearest_frame]).to eql 2
        expect(result.out_of_tolerance_contours.first[:distance]).to eql 4.0
      end

    end

    describe ".from_rtstruct" do

      it "extracts closed planar ROI contours by patient coordinates and applies XOR holes" do
        rtstruct = DObject.new
        rtstruct.add_element('0008,0060', 'RTSTRUCT')
        roi_sequence = rtstruct.add_sequence('3006,0039')
        roi_item = roi_sequence.add_item
        roi_item.add(Element.new('3006,0084', '7'))
        contour_sequence = roi_item.add_sequence('3006,0040')
        contour_item = contour_sequence.add_item
        contour_item.add(Element.new('3006,0042', 'CLOSED_PLANAR'))
        contour_item.add(Element.new('3006,0048', '42'))
        contour_item.add(Element.new('3006,0050', '-4\\-4\\0\\3\\-4\\0\\3\\3\\0\\-4\\3\\0'))
        hole_item = contour_sequence.add_item
        hole_item.add(Element.new('3006,0042', 'CLOSED_PLANAR'))
        hole_item.add(Element.new('3006,0050', '-1\\-1\\0\\-1\\2\\0\\2\\2\\0\\2\\-1\\0'))

        result = RTSTRUCTMask.from_rtstruct(rtstruct, axial_options.merge(roi_number: 7))

        expect(result.mask.first.flatten.count(1)).to eql 40
        expect(result.mask.first[4][4]).to eql 0
      end

      it "skips malformed contour data that does not contain complete triples" do
        rtstruct = DObject.new
        roi_sequence = rtstruct.add_sequence('3006,0039')
        roi_item = roi_sequence.add_item
        contour_sequence = roi_item.add_sequence('3006,0040')
        contour_item = contour_sequence.add_item
        contour_item.add(Element.new('3006,0042', 'CLOSED_PLANAR'))
        contour_item.add(Element.new('3006,0050', '1\\2\\3\\4'))

        result = RTSTRUCTMask.from_rtstruct(rtstruct, axial_options)

        expect(result.mask.flatten).to all(eql 0)
        expect(result.out_of_tolerance_contours).to be_empty
      end

      it "unions masks from different ROI numbers" do
        rtstruct = DObject.new
        roi_sequence = rtstruct.add_sequence('3006,0039')

        first_item = roi_sequence.add_item
        first_item.add(Element.new('3006,0084', '1'))
        first_contours = first_item.add_sequence('3006,0040')
        first_contour = first_contours.add_item
        first_contour.add(Element.new('3006,0042', 'CLOSED_PLANAR'))
        first_contour.add(Element.new('3006,0050', '-5\\-5\\0\\-3\\-5\\0\\-3\\-3\\0\\-5\\-3\\0'))

        second_item = roi_sequence.add_item
        second_item.add(Element.new('3006,0084', '2'))
        second_contours = second_item.add_sequence('3006,0040')
        second_contour = second_contours.add_item
        second_contour.add(Element.new('3006,0042', 'CLOSED_PLANAR'))
        second_contour.add(Element.new('3006,0050', '-4\\-4\\0\\-2\\-4\\0\\-2\\-2\\0\\-4\\-2\\0'))

        result = RTSTRUCTMask.from_rtstruct(rtstruct, axial_options)

        expect(result.mask.first[0][0]).to eql 1
        expect(result.mask.first[2][2]).to eql 1
        expect(result.mask.first[2][1]).to eql 1
        expect(result.mask.first.flatten.count(1)).to eql 7
      end

      it "ignores non-planar contour geometric types" do
        rtstruct = DObject.new
        roi_sequence = rtstruct.add_sequence('3006,0039')
        roi_item = roi_sequence.add_item
        contour_sequence = roi_item.add_sequence('3006,0040')
        contour_item = contour_sequence.add_item
        contour_item.add(Element.new('3006,0042', 'POINT'))
        contour_item.add(Element.new('3006,0050', '0\\0\\0'))

        result = RTSTRUCTMask.from_rtstruct(rtstruct, axial_options)

        expect(result.mask.flatten).to all(eql 0)
        expect(result.out_of_tolerance_contours).to be_empty
      end

    end

  end

end
