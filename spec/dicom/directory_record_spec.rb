# encoding: UTF-8

require 'spec_helper'

module DICOM

  describe DirectoryRecord do

    describe "::new" do

      it "should create a record with the given directory record type" do
        record = DirectoryRecord.new("PATIENT")
        expect(record.type).to eql "PATIENT"
        expect(record.value(RECORD_TYPE_TAG)).to eql "PATIENT"
      end

      it "should initialize the mandatory link elements with zero/empty defaults" do
        record = DirectoryRecord.new("STUDY")
        expect(record.value(NEXT_RECORD_TAG)).to eql 0
        expect(record.value(LOWER_LEVEL_RECORD_TAG)).to eql 0
        expect(record.value(RECORD_IN_USE_TAG)).to eql 65535
      end

      it "should be created without a parent and without children" do
        record = DirectoryRecord.new("SERIES")
        expect(record.parent).to be_nil
        expect(record.children).to eql Array.new
        expect(record.children?).to be_falsey
      end

      it "should attach itself to a parent record when given one" do
        parent = DirectoryRecord.new("PATIENT")
        child = DirectoryRecord.new("STUDY", :parent => parent)
        expect(child.parent).to equal parent
        expect(parent.children).to eq [child]
      end

    end

    describe "#add_record" do

      it "should create and attach a child record" do
        patient = DirectoryRecord.new("PATIENT")
        study = patient.add_record("STUDY")
        expect(study.parent).to equal patient
        expect(patient.children.map(&:type)).to eql ["STUDY"]
        expect(patient.count).to eql 1
      end

      it "should nest records through several levels" do
        patient = DirectoryRecord.new("PATIENT")
        study = patient.add_record("STUDY")
        series = study.add_record("SERIES")
        image = series.add_record("IMAGE")
        expect(patient.count_all).to eql 4
        expect(series.children).to eq [image]
      end

      it "should insert a newly created record at a given index" do
        patient = DirectoryRecord.new("PATIENT")
        first = patient.add_record("STUDY")
        third = patient.add_record("STUDY")
        middle = patient.add_record("STUDY", :index => 1)
        expect(patient.children).to eq [first, middle, third]
      end

    end

    describe "#add" do

      it "should insert an existing record at a specific child index" do
        patient = DirectoryRecord.new("PATIENT")
        first = patient.add_record("STUDY")
        last = patient.add_record("STUDY")
        middle = DirectoryRecord.new("STUDY")
        patient.add(middle, :index => 1)
        expect(patient.children).to eq [first, middle, last]
      end

      it "should move a record away from its previous parent" do
        patient_a = DirectoryRecord.new("PATIENT")
        patient_b = DirectoryRecord.new("PATIENT")
        study = patient_a.add_record("STUDY")
        patient_b.add(study)
        expect(patient_a.children).to eql Array.new
        expect(patient_b.children).to eq [study]
        expect(study.parent).to equal patient_b
      end

    end

    describe "#next_record" do

      it "should return the following sibling, or nil for the last one" do
        patient = DirectoryRecord.new("PATIENT")
        first = patient.add_record("STUDY")
        second = patient.add_record("STUDY")
        expect(first.next_record).to equal second
        expect(second.next_record).to be_nil
      end

    end

    describe "#delete" do

      before do
        @patient = DirectoryRecord.new("PATIENT")
        @study1 = @patient.add_record("STUDY")
        @series1 = @study1.add_record("SERIES")
        @series1.add_record("IMAGE")
        @series1.add_record("IMAGE")
        @study2 = @patient.add_record("STUDY")
      end

      it "should remove a leaf record and return it" do
        last_image = @series1.children.last
        removed = @series1.delete(last_image)
        expect(removed).to equal last_image
        expect(@series1.count).to eql 1
        expect(removed.parent).to be_nil
      end

      it "should remove a subtree by default" do
        @patient.delete(@study1)
        expect(@patient.children).to eq [@study2]
        expect(@patient.count_all).to eql 2
      end

      it "should promote children when keep_children is used, preserving position" do
        @patient.delete(@study1, :keep_children => true)
        expect(@patient.children).to eq [@series1, @study2]
        expect(@series1.parent).to equal @patient
      end

    end

    describe "#flatten and traversal" do

      it "should flatten in depth-first (pre-order) order" do
        patient = DirectoryRecord.new("PATIENT")
        study = patient.add_record("STUDY")
        series = study.add_record("SERIES")
        image = series.add_record("IMAGE")
        expect(patient.flatten).to eq [patient, study, series, image]
        types = Array.new
        patient.each_record { |record| types << record.type }
        expect(types).to eql %w[PATIENT STUDY SERIES IMAGE]
      end

      it "should filter children by type" do
        study = DirectoryRecord.new("STUDY")
        series_a = study.add_record("SERIES")
        study.add_record("IMAGE")
        series_b = study.add_record("SERIES")
        expect(study.children_by_type("series")).to eq [series_a, series_b]
      end

    end

    describe "Referenced File ID" do

      it "should return an empty array when no file is referenced" do
        record = DirectoryRecord.new("PATIENT")
        expect(record.file_id).to eql Array.new
      end

      it "should store components joined with the DICOM backslash separator" do
        record = DirectoryRecord.new("IMAGE")
        record.file_id = ["A", "B", "C"]
        expect(record.item.value(REFERENCED_FILE_ID_TAG)).to eql "A\\B\\C"
        expect(record.file_id).to eql ["A", "B", "C"]
      end

      it "should accept a raw file ID string as well" do
        record = DirectoryRecord.new("IMAGE")
        record.file_id = "X\\Y"
        expect(record.file_id).to eql ["X", "Y"]
      end

    end

  end

end
