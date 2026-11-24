require "sinatra/base"
require "json"
require "date"

require_relative "lib/shelf/env"
require_relative "lib/shelf/db"
require_relative "lib/shelf/isbn"
require_relative "lib/shelf/lookup"
require_relative "lib/shelf/models"
require_relative "lib/shelf/importers/base"
require_relative "lib/shelf/importers/goodreads"
require_relative "lib/shelf/importers/storygraph"
require_relative "lib/shelf/booklog"
require_relative "lib/shelf/exporters/goodreads_csv"
require_relative "lib/shelf/enricher"

module Shelf
  class App < Sinatra::Base
    set :root, ROOT
    set :method_override, true
    # Personal app, no auth: allow any Host header so it works over LAN/iPad
    # if you bind to 0.0.0.0. Default binding is localhost only.
    set :host_authorization, { permitted_hosts: [] }

    helpers do
      def h(s) = Rack::Utils.escape_html(s.to_s)
      def simple_format(s) = h(s).gsub(/\r?\n/, "<br>")
      def stars(r) = r ? format("%g ★", r) : "—"
      def fmt_date(d) = d ? d.strftime("%b %-d, %Y") : "—"
      def today = Date.today.iso8601

      def cover(book, size = "M", klass = "cover")
        src = book.cover_src(size) or return %(<span class="#{klass} blank"></span>)
        %(<img class="#{klass}" src="#{h src}" loading="lazy" alt="" onerror="this.outerHTML='<span class=&quot;#{klass} blank&quot;></span>'">)
      end

      def delta(mine, theirs)
        return "" unless mine && theirs
        d = (mine - theirs).round(2)
        %(<span class="delta #{d.positive? ? 'up' : d.negative? ? 'down' : ''}">#{d.positive? ? '+' : ''}#{format('%.2f', d)}</span>)
      end

      def flash_msg = (m = session_flash) && %(<p class="flash">#{h m}</p>)
      def session_flash = request.cookies["flash"].tap { response.delete_cookie("flash") if _1 }
      def flash!(msg) = response.set_cookie("flash", value: msg, path: "/", httponly: true)

      def book_status_json(book)
        { id: book.id, rating: book.rating, status: book.status, status_label: Book::STATUSES[book.status] }.to_json
      end

      # Clickable quarter-star rating widget (public/app.js). Hidden until the
      # book is read/DNF; app.js reveals it when "✓ Read" is clicked.
      def star_input(book)
        r = book.rating
        %(<span class="rate-slot" data-rate-for="#{book.id}"#{' hidden' unless book.rateable?}>) +
          %(<span class="stars" role="slider" tabindex="0" aria-label="Your rating" aria-valuemin="0" aria-valuemax="5" ) +
          %(aria-valuenow="#{r || 0}" data-id="#{book.id}" data-rating="#{r}" title="Click to rate (click again to clear)">) +
          %(<span class="fill" style="width:#{(r || 0) * 20}%"></span></span>) +
          %(<span class="stars-val">#{r ? format('%g', r) : ''}</span></span>)
      end

      def status_pill(book)
        %(<span class="pill #{book.status}" data-status-for="#{book.id}">#{Book::STATUSES[book.status]}</span>)
      end

      def finish_button(book)
        return "" if book.status == "read"
        %(<form method="post" action="/books/#{book.id}/finish" class="inline finish" data-id="#{book.id}">) +
          %(<button class="small ghost" title="Mark read, finished today">✓ Read</button></form>)
      end

      def book_params
        attrs = params.fetch("book", {}).slice(*Book::EDITABLE.map(&:to_s))
        attrs["owned"] = attrs.key?("owned") if params["book"]
        attrs
      end
    end

    # --- library -------------------------------------------------------

    get "/" do
      ds = Book.dataset
      @status = params["status"]
      ds = ds.where(status: @status) if Book::STATUSES.key?(@status)
      if (q = params["q"].to_s.strip) != ""
        like = "%#{q}%"
        ds = ds.where(Sequel.ilike(:title, like) | Sequel.ilike(:authors, like) | Sequel.ilike(:tags, like) |
                      { isbn13: ISBN.normalize(q) || q })
      end
      last_read = DB[:reads].where(book_id: Sequel[:books][:id]).select { max(finished_on) }
      ds = ds.select_append(last_read.as(:last_read))
      @sort = params["sort"] || "added"
      ds = case @sort
           when "title"  then ds.order(Sequel.function(:lower, :title))
           when "author" then ds.order(Sequel.function(:lower, :authors), :title)
           when "rating" then ds.order(Sequel.desc(:rating, nulls: :last), :title)
           when "read"   then ds.order(Sequel.desc(:last_read, nulls: :last))
           else ds.order(Sequel.desc(:created_at), Sequel.desc(:id))
           end
      @books = ds.eager(:borrows).all
      @counts = Book.group_and_count(:status).to_h { [_1[:status], _1[:count]] }
      @counts["all"] = @counts.values.sum
      erb :index
    end

    get "/books/new" do
      @book = Book.new
      erb :new
    end

    post "/books" do
      @book = Book.new(book_params)
      if @book.valid?
        @book.save
        @book.enrich! if params["lookup"] && @book.isbn13
        redirect "/books/#{@book.id}"
      else
        erb :new
      end
    end

    # Add by ISBN (typed or scanned) from the regular form.
    post "/books/isbn" do
      res = Enricher.add_by_isbn(params["isbn"], status: params["status"], format: params["format"], owned: params.key?("owned"))
      flash!(res[:message])
      redirect res[:book] ? "/books/#{res[:book].id}" : "/books/new"
    end

    get "/books/:id" do
      @book = Book[params["id"]] or halt 404
      erb :show
    end

    get "/books/:id/edit" do
      @book = Book[params["id"]] or halt 404
      erb :edit
    end

    patch "/books/:id" do
      @book = Book[params["id"]] or halt 404
      @book.set_fields(book_params, Book::EDITABLE.map(&:to_s), missing: :skip)
      if @book.valid?
        @book.save_changes
        redirect "/books/#{@book.id}"
      else
        erb :edit
      end
    end

    delete "/books/:id" do
      Book[params["id"]]&.destroy
      flash!("Deleted.")
      redirect "/"
    end

    post "/books/:id/enrich" do
      book = Book[params["id"]] or halt 404
      flash!(book.enrich! ? "Metadata refreshed." : "Nothing found for this book.")
      redirect "/books/#{book.id}"
    end

    # Inline rating from the star widget. Empty rating clears it.
    patch "/books/:id/rating" do
      book = Book[params["id"]] or halt 404
      content_type :json
      value = params["rating"].to_s.strip
      book.rate!(value.empty? ? nil : Float(value))
      book_status_json(book)
    rescue ArgumentError, Sequel::ValidationFailed => e
      halt 422, { error: e.message }.to_json
    end

    # One-click "finished it today".
    post "/books/:id/finish" do
      book = Book[params["id"]] or halt 404
      book.log_read!(finished_on: Date.today)
      if request.accept?("application/json") && !request.accept?("text/html")
        content_type :json
        book_status_json(book)
      else
        redirect back
      end
    end

    get "/books/:id/review.json" do
      book = Book[params["id"]] or halt 404
      content_type :json
      JSON.pretty_generate(Booklog.review(book))
    end

    # --- reads -----------------------------------------------------------

    post "/books/:id/reads" do
      book = Book[params["id"]] or halt 404
      started = params["started_on"].to_s.empty? ? nil : Date.parse(params["started_on"])
      finished = params["finished_on"].to_s.empty? ? nil : Date.parse(params["finished_on"])
      book.log_read!(started_on: started, finished_on: finished)
      redirect "/books/#{book.id}"
    end

    patch "/reads/:id" do
      read = Read[params["id"]] or halt 404
      read.update(finished_on: Date.parse(params["finished_on"]))
      read.book.update(status: "read")
      redirect "/books/#{read.book_id}"
    end

    delete "/reads/:id" do
      read = Read[params["id"]] or halt 404
      read.destroy
      redirect "/books/#{read.book_id}"
    end

    # --- borrows ---------------------------------------------------------

    get "/borrows" do
      @out = Borrow.where(returned_on: nil).order(:borrowed_on).eager(:book).all
      @history = Borrow.exclude(returned_on: nil).order(Sequel.desc(:returned_on)).limit(50).eager(:book).all
      erb :borrows
    end

    post "/books/:id/borrows" do
      book = Book[params["id"]] or halt 404
      b = Borrow.new(book_id: book.id, borrowed_by: params["borrowed_by"].to_s.strip,
                     borrowed_on: params["borrowed_on"].to_s.empty? ? Date.today : Date.parse(params["borrowed_on"]),
                     notes: params["notes"])
      b.valid? ? b.save : flash!(b.errors.full_messages.join(", "))
      redirect "/books/#{book.id}"
    end

    post "/borrows/:id/return" do
      b = Borrow[params["id"]] or halt 404
      b.update(returned_on: params["returned_on"].to_s.empty? ? Date.today : Date.parse(params["returned_on"]))
      redirect back
    end

    delete "/borrows/:id" do
      b = Borrow[params["id"]] or halt 404
      b.destroy
      redirect "/books/#{b.book_id}"
    end

    # --- scanning --------------------------------------------------------

    get "/scan" do
      erb :scan
    end

    post "/api/scan" do
      content_type :json
      body = JSON.parse(request.body.read) rescue params
      res = Enricher.add_by_isbn(body["code"], status: body["status"], format: body["format"], owned: body["owned"])
      book = res.delete(:book)
      res[:book] = book && { id: book.id, title: book.display_title, authors: book.authors,
                             cover: book.cover_src("M"), url: "/books/#{book.id}" }
      status(res[:status] == "invalid" ? 422 : 200)
      res.to_json
    end

    # --- compare ---------------------------------------------------------

    get "/compare" do
      @books = Book.exclude(rating: nil).where(Sequel.|({ Sequel.~(gr_avg_rating: nil) => true }, Sequel.~(ol_avg_rating: nil))).all
      @books.sort_by! { -(_1.rating - _1.community_rating).abs }
      @unrated_community = Book.exclude(rating: nil).where(gr_avg_rating: nil, ol_avg_rating: nil).count
      erb :compare
    end

    # --- import / export ------------------------------------------------

    get "/import" do
      @enrich = Enricher.status
      @pending = Book.where(looked_up_at: nil).count
      @placeholders = Enricher.placeholders.count
      @google_key = !ENV["GOOGLE_BOOKS_API_KEY"].to_s.empty?
      erb :import
    end

    post "/import" do
      file = params["file"] or halt 400, "No file"
      data = file[:tempfile].read
      @result = Enricher.import(data)
      flash!(@result.to_s)
      @result.errors.first(5).each { warn _1 }
      redirect "/import"
    rescue ArgumentError, JSON::ParserError, CSV::MalformedCSVError => e
      flash!("Import failed: #{e.message}")
      redirect "/import"
    end

    post "/enrich" do
      Enricher.enrich_all_in_background(params["missing"] ? Enricher.placeholders : Book.where(looked_up_at: nil))
      redirect "/import"
    end

    get "/export.json" do
      attachment "books-#{Date.today}.booklog.json"
      content_type :json
      JSON.pretty_generate(Booklog.export(Book.order(:id).eager(:reads, :borrows).all))
    end

    get "/export.csv" do
      attachment "books-#{Date.today}.goodreads.csv"
      content_type "text/csv"
      Exporters::GoodreadsCsv.call(Book.order(:id).eager(:reads).all)
    end

    not_found { "Not found" }
  end
end
