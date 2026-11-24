// USB/Bluetooth barcode scanners act as keyboards: they type the digits and
// press Enter. So "scanning" is just submitting this form, with the input
// kept focused so you can scan a whole stack without touching the mouse.
(() => {
  const form = document.getElementById("scan-form");
  const input = document.getElementById("code");
  const results = document.getElementById("results");
  const opts = ["status", "format", "owned"].map((id) => document.getElementById(id));

  const refocus = () => setTimeout(() => {
    if (!opts.includes(document.activeElement)) input.focus();
  }, 0);
  window.addEventListener("focus", refocus);
  document.addEventListener("click", refocus);

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    const code = input.value.trim();
    input.value = "";
    if (!code) return;

    const li = document.createElement("li");
    li.className = "pending";
    li.textContent = `Looking up ${code}…`;
    results.prepend(li);

    try {
      const res = await fetch("/api/scan", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          code,
          status: opts[0].value,
          format: opts[1].value,
          owned: opts[2].checked,
        }),
      });
      const data = await res.json();
      li.className = data.status;
      li.innerHTML = "";
      if (data.book) {
        const img = document.createElement("img");
        img.src = data.book.cover || "";
        img.onerror = () => img.remove();
        const a = document.createElement("a");
        a.href = data.book.url;
        a.textContent = data.book.title;
        const by = document.createElement("span");
        by.className = "muted";
        by.textContent = data.book.authors ? ` ${data.book.authors}` : "";
        li.append(img, a, by);
      }
      if (data.sticker) {
        const a = document.createElement("a");
        a.href = "/books/new";
        a.textContent = "Search by title instead →";
        li.append(document.createTextNode(`${code}: store price sticker (the ISBN isn't in it). Peel it, or `), a);
      }
      const msg = document.createElement("small");
      msg.textContent = { created: data.found ? "added" : "added, no metadata yet", exists: "already in library", merged: "merged with existing entry", invalid: data.sticker ? "" : data.message }[data.status];
      li.append(msg);
    } catch (err) {
      li.className = "invalid";
      li.textContent = `${code}: ${err.message}`;
    }
    refocus();
  });
})();
