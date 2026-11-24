require "csv"
require "cgi"
require "date"

module Shelf
  module Importers
    Result = Struct.new(:source, :created, :updated, :errors) do
      def initialize(source) = super(source, 0, 0, [])
      def to_s = "#{source}: #{created} added, #{updated} merged#{", #{errors.size} errors" if errors.any?}"
    end

    # An importer yields normalized records:
    #   { book: {column => value}, reads: [[started_on, finished_on], ...], borrows: [{...}] }
    # Base handles de-duplication and merging so re-importing is safe.
    class Base
      def self.call(io) = new(io).run

      def initialize(io)
        @data = io.respond_to?(:read) ? io.read : io.to_s
        @data = @data.dup.force_encoding("UTF-8").delete_prefix("﻿")
      end

      def source_name = self.class.name.split("::").last

      def run
        result = Result.new(source_name)
        index = {}
        Book.all.each { |b| Duplicates.keys_for(b).each { index[_1] = b } }

        DB.transaction do
          each_record do |rec, line|
            upsert(rec, index, result)
          rescue Sequel::ValidationFailed, ArgumentError => e
            result.errors << "#{line}: #{e.message}"
          end
        end
        result
      end

      private

      def upsert(rec, index, result)
        attrs = rec[:book].reject { |_, v| v.nil? || v == "" }
        # A rating in an export means it was read, whatever shelf it's on.
        attrs[:status] = "read" if attrs[:rating] && !Book::RATEABLE.include?(attrs[:status])
        book = Duplicates.keys_for(Book.new(attrs.slice(*Duplicates::MATCH_ATTRS))).lazy.map { index[_1] }.find(&:itself)

        if book
          attrs.each { |k, v| book[k] = v if book[k].nil? || book[k] == "" }
          book.gr_avg_rating = attrs[:gr_avg_rating] if attrs[:gr_avg_rating]
          if Book::STATUS_RANK.fetch(attrs[:status], 0) > Book::STATUS_RANK.fetch(book.status, 0)
            book.status = attrs[:status]
          end
          book.status = "read" if book.rating && !book.rateable?
          book.save_changes
          result.updated += 1
        else
          book = Book.create(attrs)
          result.created += 1
        end
        Duplicates.keys_for(book).each { index[_1] = book }

        existing = book.reads.map { [_1.started_on, _1.finished_on] }
        Array(rec[:reads]).uniq.each do |started, finished|
          next if existing.any? { |s, f| f == finished && (finished || s == started) }
          book.add_read(started_on: started, finished_on: finished)
        end

        Array(rec[:borrows]).each do |b|
          next if book.borrows.any? { _1.borrowed_by == b[:borrowed_by] && _1.borrowed_on == b[:borrowed_on] }
          book.add_borrow(b)
        end
        book.refresh
      end

      # --- helpers shared by CSV importers ---

      def csv_rows
        CSV.parse(@data, headers: true).each.with_index(2)
      end

      # First non-blank value among several possible header names.
      def col(row, *names)
        names.each do |n|
          v = row[n]
          return v.strip if v && !v.strip.empty?
        end
        nil
      end

      def date(str)
        return nil if str.to_s.strip.empty?
        Date.strptime(str.strip, "%Y/%m/%d")
      rescue Date::Error
        Date.parse(str) rescue nil
      end

      def rating(str)
        r = str.to_f
        r.positive? ? (r * 4).round / 4.0 : nil
      end

      def format_from(str) = Lookup.map_format(str)

      # Goodreads reviews come out as HTML with <br/>s.
      def clean_review(str)
        return nil if str.to_s.strip.empty?
        CGI.unescapeHTML(str.gsub(%r{<br\s*/?>}i, "\n").gsub(/<[^>]+>/, "")).strip
      end
    end
  end
end
