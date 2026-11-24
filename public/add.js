// Typeahead on the Add page: search Open Library / Google Books as you type,
// click a result to add it.
(() => {
  const input = document.getElementById("q");
  const list = document.getElementById("results");
  const status = document.getElementById("find-status");
  const addStatus = document.getElementById("add-status");
  let timer, controller, results = [], active = -1;

  const el = (tag, attrs = {}, ...kids) => {
    const n = Object.assign(document.createElement(tag), attrs);
    n.append(...kids.filter((k) => k != null && k !== ""));
    return n;
  };

  // Paste/type an ISBN → straight to the ISBN path.
  const isbnish = (q) => /^[\d\-\s]{9,17}[\dxX]$/.test(q.trim());

  async function search(q) {
    controller?.abort();
    controller = new AbortController();
    status.textContent = "Searching…";
    try {
      const res = await fetch(`/api/search?q=${encodeURIComponent(q)}`, { signal: controller.signal });
      results = await res.json();
      render();
      status.textContent = results.length ? "" : "Nothing found. Try fewer words, or add it manually below.";
    } catch (e) {
      if (e.name !== "AbortError") status.textContent = `Search failed: ${e.message}`;
    }
  }

  function render() {
    active = -1;
    list.replaceChildren(...results.map((r, i) => {
      const img = el("img", { src: r.cover_url || "", alt: "", loading: "lazy" });
      img.onerror = () => img.replaceWith(el("span", { className: "thumb blank" }));
      if (!r.cover_url) img.onerror();
      const meta = [r.authors?.replaceAll(";", ","), r.year, r.editions > 1 ? `${r.editions} editions` : null,
                    r.isbn13 ? `ISBN ${r.isbn13}` : null].filter(Boolean).join(" · ");
      const badge = el("span", { className: `src ${r.source}` }, r.source === "google" ? "Google" : "Open Library");
      const right = r.in_library
        ? el("a", { href: r.in_library, className: "pill read" }, "In library")
        : el("button", { type: "button", className: "small" }, "Add");
      const li = el("li", { tabIndex: -1 }, img,
        el("div", { className: "info" }, el("strong", {}, r.title), r.subtitle ? el("span", { className: "muted" }, `: ${r.subtitle}`) : null,
           el("div", { className: "muted" }, meta, " ", badge)),
        right);
      if (!r.in_library) {
        li.addEventListener("click", (e) => { if (e.target.tagName !== "A") add(i, li); });
      }
      return li;
    }));
  }

  async function add(i, li) {
    if (li.classList.contains("adding")) return;
    li.classList.add("adding");
    status.textContent = `Adding ${results[i].title}…`;
    const res = await fetch("/api/books", {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({ pick: results[i], status: addStatus.value }),
    });
    const data = await res.json();
    if (!res.ok) {
      li.classList.remove("adding");
      status.textContent = data.error;
      return;
    }
    window.location = data.url;
  }

  input.addEventListener("input", () => {
    clearTimeout(timer);
    const q = input.value.trim();
    if (q.length < 3) { list.replaceChildren(); status.textContent = ""; return; }
    if (isbnish(q)) { status.textContent = "Looks like an ISBN. Press Enter to add it."; list.replaceChildren(); return; }
    timer = setTimeout(() => search(q), 350);
  });

  // ↑/↓ to move, Enter to add (or submit an ISBN).
  input.addEventListener("keydown", (e) => {
    const items = [...list.children];
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      if (!items.length) return;
      active = (active + (e.key === "ArrowDown" ? 1 : -1) + items.length) % items.length;
      items.forEach((li, i) => li.classList.toggle("active", i === active));
      items[active].scrollIntoView({ block: "nearest" });
    } else if (e.key === "Enter") {
      e.preventDefault();
      const q = input.value.trim();
      if (isbnish(q)) {
        const f = document.querySelector('form[action="/books/isbn"]');
        f.isbn.value = q;
        f.status.value = addStatus.value;
        f.submit();
      } else if (active >= 0) {
        if (results[active].in_library) window.location = results[active].in_library;
        else add(active, items[active]);
      }
    }
  });
})();
