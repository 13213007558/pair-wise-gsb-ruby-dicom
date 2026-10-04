# encoding: UTF-8

require 'spec_helper'
require 'numo/narray'


module DICOM

  describe ImageItem do

    before :context do
      DICOM.logger = Logger.new(STDOUT)
      DICOM.logger.level = Logger::FATAL
    end


    describe "#add_element" do

      it "should add an Element (as specified) to a DObject instance" do
        dcm = DObject.new
        e = dcm.add_element('0011,0011', 'Rex', :vr => 'PN')
        expect(e.tag).to eql '0011,0011'
        expect(e.value).to eql 'Rex'
        expect(e.vr).to eql 'PN'
        expect(e.parent).to eql dcm
        expect(dcm.exists?('0011,0011')).to be_truthy
      end

      it "should add an Element (as specified) to the Item instance" do
        i = Item.new
        e = i.add_element('0011,0011', 'Rex', :name => 'Pet Name')
        expect(e.tag).to eql '0011,0011'
        expect(e.value).to eql 'Rex'
        expect(e.name).to eql 'Pet Name'
        expect(e.parent).to eql i
        expect(i.exists?('0011,0011')).to be_truthy
      end

      it "should give a NoMethodError if called on a Sequence" do
        s = Sequence.new('0008,0082')
        expect{s.add_element('0011,0011', 'Rex')}.to raise_error(NoMethodError)
      end

      it "should give a NoMethodError if called on an Element" do
        e = Element.new('0010,0010', 'John Doe')
        expect{e.add_element('0011,0011', 'Rex')}.to raise_error(NoMethodError)
      end

    end


    describe "#add_sequence" do

      it "should add a Sequence (as specified) to a DObject instance" do
        dcm = DObject.new
        e = dcm.add_sequence('0008,0082')
        expect(e.tag).to eql '0008,0082'
        expect(e.parent).to eql dcm
        expect(dcm.exists?('0008,0082')).to be_truthy
      end

      it "should add a Sequence (as specified) to the Item instance" do
        i = Item.new
        e = i.add_sequence('0011,0011', :name => 'Pet Sequence')
        expect(e.tag).to eql '0011,0011'
        expect(e.name).to eql 'Pet Sequence'
        expect(e.parent).to eql i
        expect(i.exists?('0011,0011')).to be_truthy
      end

      it "should give a NoMethodError if called on a Sequence" do
        s = Sequence.new('0008,0082')
        expect{s.add_sequence('0008,0082')}.to raise_error(NoMethodError)
      end

      it "should give a NoMethodError if called on an Element" do
        e = Element.new('0010,0010', 'John Doe')
        expect{e.add_sequence('0008,0082')}.to raise_error(NoMethodError)
      end

    end


    describe "#color?" do

      it "should return false when the DICOM object has no pixel data" do
        dcm = DObject.new
        expect(dcm.color?).to be_falsey
      end

      it "should return false when the DICOM object has greyscale pixel data" do
        dcm = DObject.read(DCM_EXPLICIT_MR_JPEG_LOSSY_MONO2)
        expect(dcm.color?).to be_falsey
      end

      it "should return true when the DICOM object has RGB pixel data" do
        dcm = DObject.read(DCM_EXPLICIT_BIG_ENDIAN_US_8BIT_RBG)
        expect(dcm.color?).to be_truthy
      end

      it "should return true when the DICOM object has palette color pixel data" do
        dcm = DObject.read(DCM_IMPLICIT_NO_HEADER_OT_8BIT_PAL)
        expect(dcm.color?).to be_truthy
      end

    end


    describe "#compression?" do

      it "should return false when the DICOM object has no pixel data" do
        dcm = DObject.new
        expect(dcm.compression?).to be_falsey
      end

      it "should return false when the DICOM object has ordinary, uncompressed pixel data" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        expect(dcm.compression?).to be_falsey
      end

      it "should return true when the DICOM object has JPG compressed pixel data" do
        dcm = DObject.read(DCM_EXPLICIT_MR_JPEG_LOSSY_MONO2)
        expect(dcm.compression?).to be_truthy
      end

      it "should return true when the DICOM object has RLE compressed pixel data" do
        dcm = DObject.read(DCM_EXPLICIT_US_RLE_PAL_MULTIFRAME)
        expect(dcm.compression?).to be_truthy
      end

    end


    describe "#decode_pixels" do

      it "should raise an error when the DICOM object doesn't have any of the necessary data elements needed to decode pixel data" do
        dcm = DObject.new
        expect {dcm.decode_pixels('0000')}.to raise_error(/Bit Depth/)
      end

      it "should raise an error when the DICOM object is missing the 'Pixel Representation' element, needed to decode pixel data" do
        dcm = DObject.new
        dcm.add(Element.new('0028,0100', 16))
        expect {dcm.decode_pixels('0000')}.to raise_error(/Pixel Representation/)
      end

      it "should raise an ArgumentError when a non-string is supplied" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        expect {dcm.decode_pixels(42)}.to raise_error(ArgumentError)
      end

      it "should return decoded pixel values in an array with a length determined by the input string length and the bit depth of the object's pixel data" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        pixels = dcm.decode_pixels('0000')
        expect(pixels.class).to eql Array
        expect(pixels.length).to eql 2
      end

    end


    describe "#encode_pixels" do

      it "should raise an error when the DICOM object doesn't have the necessary data elements needed to encode the pixel data" do
        dcm = DObject.new
        expect {dcm.encode_pixels([42, 42])}.to raise_error(/Bit Depth/)
      end

      it "should raise an error when the DICOM object is missing the 'Pixel Representation' element, needed to encode the pixel data" do
        dcm = DObject.new
        dcm.add(Element.new('0028,0100', 16))
        expect {dcm.encode_pixels([42, 42])}.to raise_error(/Pixel Representation/)
      end

      it "should raise an ArgumentError when a non-array is supplied" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        expect {dcm.encode_pixels('42')}.to raise_error(ArgumentError)
      end

      it "should return encoded pixel values in a string with a length determined by the input array length and the bit depth of the object's pixel data" do
        dcm = DObject.read(DCM_IMPLICIT_NO_HEADER_OT_8BIT_PAL)
        pixels = dcm.encode_pixels([42, 42])
        expect(pixels.class).to eql String
        expect(pixels.length).to eql 2
      end

    end


    describe "#pixels" do

      it "should return nil if no pixel data is present" do
        dcm = DObject.new
        expect(dcm.pixels).to be_nil
      end

      it "should return false if it is not able to decompress compressed pixel data" do
        dcm = DObject.new
        dcm.stubs(:exists?).returns(true)
        dcm.stubs(:compression?).returns(true)
        dcm.stubs(:decompress).returns(false)
        expect(dcm.pixels).to be_falsey
      end

      it "should return pixel data in an array" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        expect(dcm.pixels).to be_an(Array)
      end

      it "should return an array of length equal to the number of pixels in the pixel data" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        expect(dcm.pixels.length).to eql 65536 # 256*256 pixels
      end

      it "should properly decode the pixel data such that the minimum pixel value for this image is 1024" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        expect(dcm.pixels.min).to eql 1024
      end

      it "should properly decode the pixel data such that the maximum pixel value for this image is 1024" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        expect(dcm.pixels.max).to eql 1284
      end

      it "should remap the pixel values according to the rescale slope and intercept values and give the expected mininum value" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        dcm.add(Element.new('0028,1052', '-72')) # intercept
        dcm.add(Element.new('0028,1053', '3')) # slope
        expect(dcm.pixels(:remap => true).min).to eql 3000
      end

      it "should remap the pixel values according to the rescale slope and intercept values and give the expected maximum value" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        dcm.add(Element.new('0028,1052', '148')) # intercept
        dcm.add(Element.new('0028,1053', '3')) # slope
        expect(dcm.pixels(:remap => true).max).to eql 4000
      end

      it "should remap the pixel values using the default window center & width values and give the expected minimum value" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        expect(dcm.pixels(:level => true).min).to eql 1053
      end

      it "should remap the pixel values using the default window center & width values and give the expected maximum value" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        expect(dcm.pixels(:level => true).max).to eql 1137
      end

      it "should remap the pixel values using the requested window center & width values and give the expected minimum value" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        expect(dcm.pixels(:level => [1100, 100]).min).to eql 1050
      end

      it "should remap the pixel values using the requested window center & width values and give the expected maximum value" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        expect(dcm.pixels(:level => [1100, 100]).max).to eql 1150
      end

      it "should remap the pixel values using the requested window center & width values and give the expected minimum value, when using the NArray library" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        expect(dcm.pixels(:level => [1100, 100], :narray => true).min).to eql 1050
      end

      it "should remap the pixel values using the requested window center & width values and give the expected maximum value, when using the NArray library" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        expect(dcm.pixels(:level => [1100, 100], :narray => true).max).to eql 1150
      end

      it "should use NArray to process the pixel values when the :narray option is used" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        dcm.expects(:process_presentation_values_narray).once
        dcm.pixels(:level => [1100, 100],:narray => true)
      end

      it "should return the pixel values properly placed in the expected indices on a 3D Pixel Data volume" do
        dcm = DObject.new
        Element.new('0002,0010', EXPLICIT_LITTLE_ENDIAN, :parent => dcm) # TS
        Element.new('0028,0008', '2', :parent => dcm) # Frames
        Element.new('0028,0010', 4, :parent => dcm) # Rows
        Element.new('0028,0011', 3, :parent => dcm) # Columns
        Element.new('0028,0100', 16, :parent => dcm) # Bit Depth
        Element.new('0028,0103', 0, :parent => dcm) # Pixel Rep.
        pixels = Array.new(24) {|i| i}
        dcm.pixels = pixels
        pixels = dcm.pixels
        expect(pixels.length).to eql 24
        expect(pixels).to eql Array.new(24) {|i| i}
      end

    end


    describe "#narray" do

      it "should return nil if no pixel data is present" do
        dcm = DObject.new
        expect(dcm.narray).to be_nil
      end

      it "should return false if it is not able to decompress compressed pixel data" do
        dcm = DObject.new
        dcm.stubs(:exists?).returns(true)
        dcm.stubs(:compression?).returns(true)
        dcm.stubs(:decompress).returns(false)
        expect(dcm.narray).to be_falsey
      end

      it "should return pixel data in an NArray" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        expect(dcm.narray).to be_a(Numo::NArray)
      end

      it "should return an NArray of length equal to the number of pixels in the pixel data" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        expect(dcm.narray.length).to eql 65536 # 256*256 pixels
      end

      it "should return an NArray which is sized according to the dimensions of the 2D pixel image" do
        dcm = DObject.read(DCM_EXPLICIT_MR_16BIT_MONO2_NON_SQUARE_PAL_ICON)
        narr = dcm.narray
        expect(narr.shape[0]).to eql 448 # nr of columns
        expect(narr.shape[1]).to eql 268 # nr of rows
        expect(narr.shape.length).to eql 2
      end

      it "should return a volumetric NArray when using the :volume option on a 2D pixel image" do
        dcm = DObject.read(DCM_EXPLICIT_MR_16BIT_MONO2_NON_SQUARE_PAL_ICON)
        narr = dcm.narray(:volume => true)
        expect(narr.shape[0]).to eql 1 # nr of frames
        expect(narr.shape[1]).to eql 448 # nr of columns
        expect(narr.shape[2]).to eql 268 # nr of rows
        expect(narr.shape.length).to eql 3
      end

      it "should properly decode the pixel data such that the minimum pixel value for this image is 1024" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        expect(dcm.narray.min).to eql 1024
      end

      it "should properly decode the pixel data such that the maximum pixel value for this image is 1024" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        expect(dcm.narray.max).to eql 1284
      end

      it "should remap the pixel values according to the rescale slope and intercept values and give the expected mininum value" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        dcm.add(Element.new('0028,1052', '-72')) # intercept
        dcm.add(Element.new('0028,1053', '3')) # slope
        expect(dcm.narray(:remap => true).min).to eql 3000
      end

      it "should remap the pixel values according to the rescale slope and intercept values and give the expected maximum value" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        dcm.add(Element.new('0028,1052', '148')) # intercept
        dcm.add(Element.new('0028,1053', '3')) # slope
        expect(dcm.narray(:remap => true).max).to eql 4000
      end

      it "should remap the pixel values using the default window center & width values and give the expected minimum value" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        expect(dcm.narray(:level => true).min).to eql 1053
      end

      it "should remap the pixel values using the default window center & width values and give the expected maximum value" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        expect(dcm.narray(:level => true).max).to eql 1137
      end

      it "should remap the pixel values using the requested window center & width values and give the expected minimum value" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        expect(dcm.narray(:level => [1100, 100]).min).to eql 1050
      end

      it "should remap the pixel values using the requested window center & width values and give the expected maximum value" do
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        expect(dcm.narray(:level => [1100, 100]).max).to eql 1150
      end

      context "with a 3D pixel volume" do

        before :example do
          dcm = DObject.new
          Element.new('0002,0010', EXPLICIT_LITTLE_ENDIAN, :parent => dcm) # TS
          Element.new('0028,0008', '2', :parent => dcm) # Frames
          Element.new('0028,0010', 4, :parent => dcm) # Rows
          Element.new('0028,0011', 3, :parent => dcm) # Columns
          Element.new('0028,0100', 16, :parent => dcm) # Bit Depth
          Element.new('0028,0103', 0, :parent => dcm) # Pixel Rep.
          pixels = Array.new(24) {|i| i}
          dcm.pixels = pixels
          @narr = dcm.narray
        end

        it "should return a 3D NArray with the expected number of frames" do
          expect(@narr.shape[0]).to eql 2
        end

        it "should return a 3D NArray with the expected number of columns" do
          expect(@narr.shape[1]).to eql 3
        end

        it "should return a 3D NArray with the expected number of rows" do
          expect(@narr.shape[2]).to eql 4
        end

        it "should return an NArray with exactly 3 dimensions" do
          expect(@narr.shape.length).to eql 3
        end

        it "should return an NArray with the pixel values properly placed in the expected indices for each frame" do
          expect(@narr[0, true, true] == Numo::Int16.new(3, 4).seq).to be_truthy
          expect(@narr[1, true, true] == Numo::Int16.new(3, 4).seq + 12).to be_truthy
        end

      end

    end


    describe "#image_from_file" do

      it "should raise an ArgumentError when a non-string argument is passed" do
        dcm = DObject.new
        expect {dcm.image_from_file(42)}.to raise_error(ArgumentError)
      end

      it "should copy the content of the specified file to the DICOM object's pixel data element" do
        file_string = 'abcdefghijkl'
        File.open(TMPDIR + 'string.dat', 'wb') {|f| f.write(file_string) }
        dcm = DObject.new
        dcm.image_from_file(TMPDIR + 'string.dat')
        expect(dcm['7FE0,0010'].bin).to eql file_string
      end

    end


    describe "#num_cols" do

      it "gives nil when the 'Columns' data element is missing from the DICOM object" do
        dcm = DObject.new
        dcm.add(Element.new('0028,0010', 512)) # Rows
        expect(dcm.num_cols).to be_nil
      end

      it "gives the expected integer when the 'Columns' data element is defined in the DICOM object" do
        dcm = DObject.new
        columns_used = 256
        dcm.add(Element.new('0028,0011', columns_used))
        expect(dcm.num_cols).to eql columns_used
      end

    end


    describe "#num_rows" do

      it "gives nil when the 'Rows' data element is missing from the DICOM object" do
        dcm = DObject.new
        dcm.add(Element.new('0028,0011', 512)) # Columns
        expect(dcm.num_rows).to be_nil
      end

      it "gives the expected integer when the 'Rows' data element is defined in the DICOM object" do
        dcm = DObject.new
        rows_used = 256
        dcm.add(Element.new('0028,0010', rows_used))
        expect(dcm.num_rows).to eql rows_used
      end

    end


    describe "#num_frames" do

      it "gives 1 as a default value when the 'Number of Frames' data element is missing from the DICOM object" do
        dcm = DObject.new
        dcm.add(Element.new('0028,0010', 512)) # Rows
        dcm.add(Element.new('0028,0011', 512)) # Columns
        expect(dcm.num_frames).to eql 1
      end

      it "gives the expected integer when the 'Number of Frames' data element is defined in the DICOM object" do
        dcm = DObject.new
        frames_used = 8
        dcm.add(Element.new('0028,0008', frames_used))
        expect(dcm.num_frames).to eql frames_used
      end

    end


    describe "#image_to_file" do

      it "should raise an ArgumentError when a non-string argument is passed" do
        dcm = DObject.new
        expect {dcm.image_to_file(42)}.to raise_error(ArgumentError)
      end

      it "should write the DICOM object's pixel data string to the specified file" do
        pixel_data = 'abcdefghijkl'
        dcm = DObject.new
        dcm.add(Element.new('7FE0,0010', pixel_data, :encoded => true))
        dcm.image_to_file(TMPDIR + 'string.dat')
        f = File.new(TMPDIR + 'string.dat', 'rb')
        expect(f.read).to eql pixel_data
      end

      it "should write multiple files as expected, when a file extension is omitted" do
        dcm = DObject.read(DCM_IMPLICIT_US_JPEG2K_LOSSLESS_MONO2_MULTIFRAME) # 8 frames
        dcm.image_to_file(TMPDIR + 'data')
        expect(File.readable?(TMPDIR + 'data-0')).to be_truthy
        expect(File.readable?(TMPDIR + 'data-7')).to be_truthy
      end

      it "should write multiple files, using the expected file enumeration and image fragments, when the DICOM object has multi-fragment pixel data" do
        dcm = DObject.read(DCM_IMPLICIT_US_JPEG2K_LOSSLESS_MONO2_MULTIFRAME) # 8 frames
        dcm.image_to_file(TMPDIR + 'multi.dat')
        expect(File.readable?(TMPDIR + 'multi-0.dat')).to be_truthy
        expect(File.readable?(TMPDIR + 'multi-7.dat')).to be_truthy
        f0 = File.new(TMPDIR + 'multi-0.dat', 'rb')
        expect(f0.read).to eql dcm['7FE0,0010'][0][0].bin
        f7 = File.new(TMPDIR + 'multi-7.dat', 'rb')
        expect(f7.read).to eql dcm['7FE0,0010'][0][7].bin
      end

    end


    describe "#delete_sequences" do

      it "should delete all sequences from the DICOM object" do
        dcm = DObject.new
        dcm.add(Element.new('0010,0030', '20000101'))
        dcm.add(Sequence.new('0008,1140'))
        dcm.add(Sequence.new('0009,1140'))
        dcm.add(Sequence.new('0088,0200'))
        dcm['0008,1140'].add_item
        dcm.add(Element.new('0011,0030', '42'))
        dcm.delete_sequences
        expect(dcm.children.length).to eql 2
        expect(dcm.exists?('0008,1140')).to be_falsey
        expect(dcm.exists?('0009,1140')).to be_falsey
        expect(dcm.exists?('0088,0200')).to be_falsey
      end

      it "should delete all sequences from the Item" do
        i = Item.new
        i.add(Element.new('0010,0030', '20000101'))
        i.add(Sequence.new('0008,1140'))
        i.add(Sequence.new('0009,1140'))
        i.add(Sequence.new('0088,0200'))
        i['0008,1140'].add_item
        i.add(Element.new('0011,0030', '42'))
        i.delete_sequences
        expect(i.children.length).to eql 2
        expect(i.exists?('0008,1140')).to be_falsey
        expect(i.exists?('0009,1140')).to be_falsey
        expect(i.exists?('0088,0200')).to be_falsey
      end

    end


    describe "#pixels=" do

      it "should raise an ArgumentError when a non-array argument is passed" do
        dcm = DObject.new
        expect {dcm.pixels = 42}.to raise_error(ArgumentError)
      end

      it "should encode the pixel array and write it to the DICOM object's pixel data element" do
        pixel_data = [0,42,0,42]
        dcm = DObject.new
        dcm.add(Element.new('0028,0100', 8)) # Bit depth
        dcm.add(Element.new('0028,0103', 0)) # Pixel Representation
        dcm.pixels = pixel_data
        expect(dcm['7FE0,0010'].bin.length).to eql 4
        expect(dcm.decode_pixels(dcm['7FE0,0010'].bin)).to eql pixel_data
      end

      it "should encode the pixel array and update the DICOM object's pixel data element" do
        pixel_data = [0,42,0,42]
        dcm = DObject.read(DCM_IMPLICIT_MR_16BIT_MONO2)
        dcm.pixels = pixel_data
        expect(dcm['7FE0,0010'].bin.length).to eql 8
        expect(dcm.decode_pixels(dcm['7FE0,0010'].bin)).to eql pixel_data
      end

      it "should encode the pixels of the NArray and write them to the DICOM object's pixel data element" do
        pixel_data = [0,42,0,42]
        dcm = DObject.new
        dcm.add(Element.new('0028,0100', 8)) # Bit depth
        dcm.add(Element.new('0028,0103', 0)) # Pixel Representation
        dcm.pixels = Numo::NArray[*pixel_data]
        expect(dcm['7FE0,0010'].bin.length).to eql 4
        expect(dcm.decode_pixels(dcm['7FE0,0010'].bin)).to eql pixel_data
      end

      context "with a 3D pixel volume" do

        before :example do
          @dcm = DObject.new
          Element.new('0002,0010', EXPLICIT_LITTLE_ENDIAN, :parent => @dcm) # TS
          Element.new('0028,0008', '2', :parent => @dcm) # Frames
          Element.new('0028,0010', 4, :parent => @dcm) # Rows
          Element.new('0028,0011', 3, :parent => @dcm) # Columns
          Element.new('0028,0100', 16, :parent => @dcm) # Bit Depth
          Element.new('0028,0103', 0, :parent => @dcm) # Pixel Rep.
        end

        it "should encode the pixels of the NArray such that the pixel values are properly placed in the expected indices for each frame" do
          narr = Numo::Int16.zeros(2, 3, 4)
          narr[0, true, true] = Numo::Int16.new(3, 4).seq
          narr[1, true, true] = Numo::Int16.new(3, 4).seq + 12
          @dcm.pixels = narr
          expect(@dcm.pixels).to eql Array.new(24) {|i| i}
        end

        it "should encode the pixels of the (flat) Array such that the pixel values are properly placed in expected indices" do
          @dcm.pixels = Array.new(24) {|i| i}
          expect(@dcm.pixels).to eql Array.new(24) {|i| i}
        end

      end

    end


    # Note: Private method.
    describe "#window_level_values" do

      it "should return the expected window level related values" do
        center = 300
        width = 600
        intercept = -1024
        slope = 1
        dcm = DObject.new
        dcm.add_element('0028,1050', center.to_s)
        dcm.add_element('0028,1051', width.to_s)
        dcm.add_element('0028,1052', intercept.to_s)
        dcm.add_element('0028,1053', slope.to_s)
        c, w, i, s = dcm.send(:window_level_values)
        expect(c).to eql center
        expect(w).to eql width
        expect(i).to eql intercept
        expect(s).to eql slope
      end

      it "should return the expected window level related values for this case of multiple center/width values" do
        center = 30
        width = 200
        intercept = -1000
        slope = 2
        dcm = DObject.new
        dcm.add_element('0028,1050', "#{center}\\500")
        dcm.add_element('0028,1051', "#{width}\\2000")
        dcm.add_element('0028,1052', intercept.to_s)
        dcm.add_element('0028,1053', slope.to_s)
        c, w, i, s = dcm.send(:window_level_values)
        expect(c).to eql center
        expect(w).to eql width
        expect(i).to eql intercept
        expect(s).to eql slope
      end

    end

  end

end
module DICOM
  describe ImageItem, '#rle' do

    before :example do
      DICOM.logger = Logger.new(nil)
    end

    def rle_dcm(columns: 3, rows: 2, frames: 1, samples: 1, depth: 8,
                representation: 0, photometry: 'MONOCHROME2', planar: nil)
      dcm = DObject.new
      Element.new('0002,0010', TXS_RLE, :parent => dcm)
      Element.new('0028,0002', samples, :parent => dcm)
      Element.new('0028,0004', photometry, :parent => dcm)
      Element.new('0028,0006', planar, :parent => dcm) unless planar.nil?
      Element.new('0028,0008', frames, :parent => dcm) if frames > 1
      Element.new('0028,0010', rows, :parent => dcm)
      Element.new('0028,0011', columns, :parent => dcm)
      Element.new('0028,0100', depth, :parent => dcm)
      Element.new('0028,0103', representation, :parent => dcm)
      dcm
    end

    describe '#encode_rle' do

      it 'encodes literals, a short run, and row boundaries in an 8-bit monochrome frame' do
        dcm = rle_dcm(:columns => 3, :rows => 3)
        frame = dcm.encode_rle([1, 1, 2, 3, 4, 5, 6, 7, 8]).first

        expect(frame[0, 64].unpack('V16').first(2)).to eql [1, 64]
        expect(frame[64..-1].unpack1('H*')).to eql 'ff0100020203040502060708'
        expect(dcm.send(:decode_rle, 3, 3, frame)).to eql [1, 1, 2, 3, 4, 5, 6, 7, 8]
      end

      it 'encodes a run of 128 without combining bytes from the next row' do
        dcm = rle_dcm(:columns => 129, :rows => 2)
        pixels = Array.new(128, 7) + [8] + Array.new(129, 9)
        frame = dcm.encode_rle(pixels).first

        expect(frame[64, 8].unpack1('H*')).to eql '8107000881090009'
        expect(dcm.send(:decode_rle, 129, 2, frame)).to eql pixels
      end

      it 'splits a run of 129 at the maximum RLE run length' do
        dcm = rle_dcm(:columns => 129, :rows => 1)
        pixels = Array.new(129, 7)
        frame = dcm.encode_rle(pixels).first

        expect(frame[64, 4].unpack1('H*')).to eql '81070007'
        expect(dcm.send(:decode_rle, 129, 1, frame)).to eql pixels
      end

      it 'encodes 8-bit signed negative pixel values' do
        dcm = rle_dcm(:columns => 2, :rows => 1, :representation => 1)
        pixels = [-128, -1]
        frame = dcm.encode_rle(pixels).first

        expect(frame[64, 4].unpack1('H*')).to eql '0180ff00'
        expect(dcm.send(:decode_rle, 2, 1, frame)).to eql pixels
      end

      it 'encodes 16-bit unsigned pixel values' do
        dcm = rle_dcm(:columns => 2, :rows => 1, :depth => 16)
        pixels = [256, 255]
        frame = dcm.encode_rle(pixels).first

        expect(dcm.send(:decode_rle, 2, 1, frame)).to eql pixels
      end

      it 'encodes 16-bit signed pixels as high and low byte planes in RLE order' do
        dcm = rle_dcm(:columns => 2, :rows => 2, :depth => 16, :representation => 1)
        pixels = [-32768, -1, 256, 255]
        frame = dcm.encode_rle(pixels).first

        expect(frame[0, 64].unpack('V16').first(3)).to eql [2, 64, 70]
        expect(frame[64, 6].unpack1('H*')).to eql '0180ff010100'
        expect(frame[70, 6].unpack1('H*')).to eql '0100ff0100ff'
        expect(dcm.send(:decode_rle, 2, 2, frame)).to eql pixels
      end

      it 'encodes 16-bit rows with an odd byte plane length' do
        dcm = rle_dcm(:columns => 2, :rows => 2, :depth => 16, :representation => 1)
        pixels = [-32768, -1, 0, 0]
        frame = dcm.encode_rle(pixels).first

        expect(frame[0, 64].unpack('V16').first(3)).to eql [2, 64, 69]
        expect(frame[64, 5].unpack1('H*')).to eql '0180ffff00'
        expect(frame[69, 5].unpack1('H*')).to eql '0100ffff00'
        expect(dcm.send(:decode_rle, 2, 2, frame)).to eql pixels
      end

      it 'encodes RGB byte planes in red, green, blue order' do
        dcm = rle_dcm(:columns => 3, :rows => 1, :samples => 3, :photometry => PI_RGB, :planar => 1)
        pixels = [1, 2, 3, 4, 5, 6, 7, 8, 9]
        frame = dcm.encode_rle(pixels).first

        expect(frame[0, 64].unpack('V16').first(4)).to eql [3, 64, 68, 72]
        expect(frame[64, 12].unpack1('H*')).to eql '020102030204050602070809'
        expect(dcm.send(:decode_rle, 3, 1, frame)).to eql pixels
      end

      it 'encodes 16-bit RGB values in six byte planes' do
        dcm = rle_dcm(:columns => 1, :rows => 1, :samples => 3, :depth => 16,
                      :photometry => PI_RGB, :planar => 1)
        pixels = [256, 255, 1]
        frame = dcm.encode_rle(pixels).first

        expect(frame[0, 64].unpack('V16').first(7)).to eql [6, 64, 66, 68, 70, 72, 74]
        expect(frame[64, 12].unpack1('H*')).to eql '00010000000000ff00000001'
        expect(dcm.send(:decode_rle, 1, 1, frame)).to eql pixels
      end

      it 'rearranges pixel-interleaved RGB data to planar order before RLE encoding' do
        dcm = rle_dcm(:columns => 3, :rows => 1, :samples => 3, :photometry => PI_RGB, :planar => 0)
        pixels = [1, 4, 7, 2, 5, 8, 3, 6, 9]
        dcm.expects(:decompress).never
        dcm.expects(:export_pixels).never

        frame = dcm.encode_rle(dcm.tap { |object| object.pixels = pixels }.pixels).first

        expect(dcm.value('0028,0006')).to eql 1
        expect(dcm.send(:decode_rle, 3, 1, frame)).to eql [1, 2, 3, 4, 5, 6, 7, 8, 9]
      end

    end

    describe '#pixels=' do

      it 'stores one encapsulated RLE item per frame' do
        dcm = rle_dcm(:columns => 3, :rows => 2, :frames => 2)
        pixels = [1, 1, 2, 3, 4, 5, 6, 6, 7, 8, 9, 10]
        dcm.pixels = pixels

        sequence = dcm[PIXEL_TAG]
        expect(sequence).to be_a(Sequence)
        expect(sequence[0].children.length).to eql 2
        expect(dcm.image_strings(true).length).to eql 2
        expect(dcm.send(:decode_rle, 3, 2, dcm.image_strings(true)[0])).to eql pixels[0, 6]
        expect(dcm.send(:decode_rle, 3, 2, dcm.image_strings(true)[1])).to eql pixels[6, 6]
      end

      it 'writes and reads back encapsulated multi-frame RLE data through DObject#write' do
        path = TMPDIR + 'rle.dcm'
        dcm = rle_dcm(:columns => 3, :rows => 3, :frames => 2)
        pixels = [1, 1, 2, 3, 4, 5, 6, 7, 8, 9, 9, 10, 11, 12, 13, 14, 15, 16]
        dcm.pixels = pixels
        dcm.write(path)
        encoded = File.binread(path)
        pixel_tag = [0xe0, 0x7f, 0x10, 0x00].pack('C4')
        position = encoded.index(pixel_tag)
        expect(encoded[position + 12, 8].unpack1('H*')).to eql 'feff00e000000000'
        expect(encoded[position + 20, 8].unpack1('H*')).to eql 'feff00e04c000000'

        read_dcm = DObject.read(path)
        expect(read_dcm.compression?).to be_truthy
        expect(read_dcm.image_strings(true).length).to eql 2
        expect(read_dcm.send(:decode_rle, 3, 3, read_dcm.image_strings(true)[0])).to eql pixels[0, 9]
        expect(read_dcm.send(:decode_rle, 3, 3, read_dcm.image_strings(true)[1])).to eql pixels[9, 9]
      end

    end

  end
end
