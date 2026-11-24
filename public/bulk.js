// Bulk selection on the library list: shift-click for ranges, select-all,
// and an action bar that appears once something is selected.
(() => {
  const form = document.getElementById("bulk");
  if (!form) return;
  const boxes = [...document.querySelectorAll('input[name="ids[]"][form="bulk"]')];
  const all = document.getElementById("select-all");
  const count = document.getElementById("bulk-count");
  const action = document.getElementById("bulk-action");
  const valueInputs = [...form.querySelectorAll("[data-for]")];
  let last = null;

  function sync() {
    const n = boxes.filter((b) => b.checked).length;
    count.textContent = n;
    form.hidden = n === 0;
    all.checked = n > 0 && n === boxes.length;
    all.indeterminate = n > 0 && n < boxes.length;
    boxes.forEach((b) => b.closest("tr").classList.toggle("selected", b.checked));
  }

  // Only the value input that matches the action is enabled (and submitted).
  function syncAction() {
    valueInputs.forEach((el) => {
      const on = el.dataset.for.split(" ").includes(action.value);
      el.hidden = !on;
      el.disabled = !on;
      el.required = on && el.tagName === "INPUT";
    });
  }

  boxes.forEach((box, i) => {
    box.addEventListener("click", (e) => {
      if (e.shiftKey && last !== null) {
        const [a, b] = [last, i].sort((x, y) => x - y);
        boxes.slice(a, b + 1).forEach((x) => { x.checked = box.checked; });
      }
      last = i;
      sync();
    });
  });
  all.addEventListener("change", () => { boxes.forEach((b) => { b.checked = all.checked; }); sync(); });
  document.getElementById("bulk-clear").addEventListener("click", () => { boxes.forEach((b) => { b.checked = false; }); sync(); });
  action.addEventListener("change", syncAction);
  form.addEventListener("submit", (e) => {
    const n = boxes.filter((b) => b.checked).length;
    if (action.value === "delete" && !confirm(`Delete ${n} ${n === 1 ? "book" : "books"}, with their reads and loans?`)) e.preventDefault();
  });
  syncAction();
  sync();
})();
