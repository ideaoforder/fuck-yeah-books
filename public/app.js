// Inline ratings + one-click "mark read". Works on the list and book pages.
(() => {
  const STEP = 0.25;
  const clamp = (v) => Math.min(5, Math.max(0, Math.round(v / STEP) * STEP));

  function paint(el, v) {
    el.querySelector(".fill").style.width = `${(v || 0) * 20}%`;
    const label = el.nextElementSibling;
    if (label?.classList.contains("stars-val")) label.textContent = v ? String(v) : "";
  }

  function current(el) {
    const r = parseFloat(el.dataset.rating);
    return Number.isNaN(r) ? null : r;
  }

  function applyStatus(data) {
    document.querySelectorAll(`[data-status-for="${data.id}"]`).forEach((pill) => {
      pill.className = `pill ${data.status}`;
      pill.textContent = data.status_label;
    });
    if (data.status === "read") {
      document.querySelectorAll(`form.finish[data-id="${data.id}"]`).forEach((f) => f.remove());
    }
    const rateable = data.status === "read" || data.status === "dnf";
    document.querySelectorAll(`[data-rate-for="${data.id}"]`).forEach((slot) => { slot.hidden = !rateable; });
  }

  async function save(el, value) {
    const before = el.dataset.saved ?? el.dataset.rating;
    el.dataset.rating = value ?? "";
    el.setAttribute("aria-valuenow", value ?? 0);
    paint(el, value);
    el.classList.add("saving");
    try {
      const res = await fetch(`/books/${el.dataset.id}/rating`, {
        method: "PATCH",
        headers: { Accept: "application/json" },
        body: new URLSearchParams({ rating: value ?? "" }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error || res.statusText);
      el.dataset.saved = el.dataset.rating;
      applyStatus(data);
    } catch (err) {
      el.dataset.rating = before ?? "";
      paint(el, current(el));
      el.classList.add("error");
      el.title = `Couldn't save: ${err.message}`;
      setTimeout(() => el.classList.remove("error"), 2000);
    } finally {
      el.classList.remove("saving");
    }
  }

  function valueAt(el, e) {
    const rect = el.getBoundingClientRect();
    const frac = (e.clientX - rect.left) / rect.width;
    return Math.min(5, Math.max(STEP, Math.ceil(frac * 20) / 4));
  }

  document.querySelectorAll(".stars").forEach((el) => {
    el.dataset.saved = el.dataset.rating;
    let timer;

    el.addEventListener("mousemove", (e) => paint(el, valueAt(el, e)));
    el.addEventListener("mouseleave", () => paint(el, current(el)));
    el.addEventListener("click", (e) => {
      e.preventDefault();
      const v = valueAt(el, e);
      save(el, v === current(el) ? null : v); // click the same value again to clear
    });

    // Keyboard: arrows nudge by a quarter star, Backspace/Delete/0 clears.
    el.addEventListener("keydown", (e) => {
      let v = current(el) || 0;
      if (["ArrowRight", "ArrowUp"].includes(e.key)) v = clamp(v + STEP);
      else if (["ArrowLeft", "ArrowDown"].includes(e.key)) v = clamp(v - STEP);
      else if (["Backspace", "Delete", "0"].includes(e.key)) v = 0;
      else if (/^[1-5]$/.test(e.key)) v = Number(e.key);
      else return;
      e.preventDefault();
      el.dataset.rating = v || "";
      paint(el, v);
      clearTimeout(timer);
      timer = setTimeout(() => save(el, v || null), 500);
    });
  });

  // In lists, "✓ Read" updates in place. On the book page it submits
  // normally so the new read shows up in the Reads list.
  document.querySelectorAll("table form.finish").forEach((form) => {
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      const res = await fetch(form.action, { method: "POST", headers: { Accept: "application/json" } });
      if (res.ok) applyStatus(await res.json());
    });
  });
})();
