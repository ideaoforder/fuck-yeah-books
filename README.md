# Fuck Yeah Books 📚

A small, local book tracker: no Amazon, no bad UX. Sinatra + SQLite, about 1,600 lines including views and CSS. Your whole library lives in one SQLite file.

## What it does

- **Library**: title, author, ISBN, format, status (want / reading / read / DNF), owned, tags.
- **Reads**: every time you read a book, with start and finish dates, so rereads are kept.
- **Rating & review**: quarter-star ratings (StoryGraph-style 0.25–5), a review and private notes.
- **Barcode scanning**: open **Scan**, point your USB scanner at the back cover, keep going. Metadata comes from Open Library, with Google Books as a fallback. Neither needs an API key.
- **Import**: Goodreads CSV, StoryGraph CSV, or Booklog JSON. The format is auto-detected, and re-importing is safe because books are matched by ISBN, then by title + author, and existing data is never overwritten.
- **Export**: Booklog JSON (lossless) or Goodreads-format CSV (imports anywhere).
- **Compare**: your rating vs. the Goodreads average (captured at import) and the Open Library average (fetched live).
- **Lending**: who has it, since when, and when it came back. The "Lent out" page lists what's out.

## Run it

```sh
bundle install
bundle exec rackup -p 4567     # http://localhost:4567
bundle exec rake               # tests
```

The database is created and migrated on boot at `db/shelf.sqlite3`. Set `SHELF_DB=/path/to/books.sqlite3` to keep it somewhere else, like a synced folder. To use it from an iPad on your LAN, run `bundle exec rackup -o 0.0.0.0 -p 4567`. Note there's no auth.

### Metadata sources

ISBN lookups try **Open Library** (books API, then its search index), then **Google Books**. Google gives keyless requests a quota of zero, so the Google fallback only works with a free API key:

1. In [Google Cloud Console](https://console.cloud.google.com/), create or pick a project and enable **Books API**.
2. Go to **Credentials** → **Create credentials** → **API key**. You can restrict the key to the Books API.
3. Run with `GOOGLE_BOOKS_API_KEY=... bundle exec rackup -p 4567`, or export it in your shell profile.

Books that no source knew about are saved as just their ISBN. Retry them from **Import / Export** → *Retry those*, or with `bin/enrich --missing`. Failed lookups are logged to stderr as `[lookup] ...`.

### Moving off Goodreads / StoryGraph

1. **Goodreads**: My Books → Import and export → *Export Library*.
2. **StoryGraph**: Manage Account → *Export StoryGraph Library*.
3. Import both on **Import / Export**, Goodreads first. The StoryGraph import merges in: it fills blanks, adds reread dates, and adds books Goodreads didn't have. If both files rated the same book, the first rating imported is kept.
4. Click **Fetch in background** (or run `bin/enrich`) to pull covers, missing details and Open Library community ratings. It makes one request every half second to be polite to Open Library, so expect about 10 minutes per 1,000 books.

Goodreads Kindle editions often have no ISBN. Those books are matched against Open Library by title + author instead.

### Scanner notes

2D USB scanners act as keyboards: they type the code and press Enter. The Scan page keeps its input focused, so you can scan a stack without touching anything. Some scanners also read the small 5-digit price barcode and append it to the ISBN; that extra code is stripped. ISBN-10s and hyphens work anywhere you type an ISBN.

## The Booklog format (portable reviews)

**Is there an existing standard?** Partly. [schema.org](https://schema.org) already defines `Book`, `Review`, `Rating` and `AggregateRating`. That's what Google, BookWyrm-adjacent tools and most of the web use to describe a review. What's missing is a *reading log*: when you read it, whether you finished it, who borrowed it. No tracker supports a common format for that. In practice everyone imports the Goodreads CSV, which is lossy: whole stars only, one read date, no loans.

So **Booklog** is schema.org with as little added as possible:

- The document is valid **JSON-LD**. Books, reviews and ratings are pure schema.org, so anything that understands schema.org understands your reviews.
- Personal data schema.org can't express uses plain extension keys: `readingStatus`, `reads` (shaped like `ReadAction`), `borrows` (shaped like `LendAction`), `owned`, `dateAdded`, `privateNotes`. JSON-LD processors ignore these keys, and Booklog readers use them.
- Ratings carry `bestRating` / `worstRating`, so importers can rescale. A 9/10 review from elsewhere comes in as 4.5 stars.
- External IDs are just URLs in `sameAs`: Open Library and Goodreads pages.

A single review, the smallest portable unit (also served at `/books/:id/review.json`):

```json
{
  "@context": "https://schema.org",
  "@type": "Review",
  "itemReviewed": {
    "@type": "Book",
    "name": "Piranesi",
    "author": [{ "@type": "Person", "name": "Susanna Clarke" }],
    "isbn": "9781635575637"
  },
  "reviewRating": { "@type": "Rating", "ratingValue": 4.5, "bestRating": 5, "worstRating": 0 },
  "reviewBody": "A house of tides.",
  "dateCreated": "2023-02-19"
}
```

A full library export is an `ItemList` of `Book`s, each with an embedded `review`, `reads` and `borrows`. See `public/schema/example.booklog.json`.

- JSON Schema (draft 2020-12): [`public/schema/booklog.schema.json`](public/schema/booklog.schema.json), also served at `/schema/booklog.schema.json`.
- The importer accepts a full export, a single Book, a single Review, or an array of either. Exporting and re-importing a Booklog file loses nothing; there's a test for that.

## Layout

```
app.rb                      routes + view helpers
lib/shelf/models.rb         Book, Read, Borrow (Sequel)
lib/shelf/isbn.rb           ISBN-10/13 validation + conversion
lib/shelf/lookup.rb         Open Library / Google Books
lib/shelf/importers/*.rb    Goodreads, StoryGraph (+ shared merge logic in base.rb)
lib/shelf/booklog.rb        Booklog JSON import/export
lib/shelf/exporters/        Goodreads-format CSV
db/migrations/              Sequel migrations
public/schema/              Booklog JSON Schema + example
```

## Known limits

- **StoryGraph community ratings** aren't available: StoryGraph has no public API and its export doesn't include averages. You get Goodreads averages (frozen as of your import) and live Open Library averages instead. Open Library has fewer ratings per book, so expect it to be noisier.
- The Goodreads CSV export rounds to whole stars and keeps only your most recent read date. Use Booklog JSON for full fidelity.
- StoryGraph's export columns have changed over time. The importer matches headers loosely, but if a column comes in empty, check the header name in `importers/storygraph.rb`.
