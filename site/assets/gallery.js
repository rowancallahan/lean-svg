/* Gallery: one card per file in the resvg test suite.
   Four panels per card — lean-svg, resvg 0.48.1, your browser, and the
   lean-svg/resvg difference. The browser panel is never scored.
   Descends from tests/gen_gallery.py's page: same filters and worst-first sort,
   with the usvg route dropped and the browser column added. */
(function () {
  "use strict";

  var PAGE = 120;                      // cards rendered per batch
  var $ = function (id) { return document.getElementById(id); };
  var state = { data: [], top: "", sub: "", status: "", q: "", sort: "worst",
                sel: [], shown: PAGE, rows: [] };

  function enc(path) {
    return path.split("/").map(encodeURIComponent).join("/");
  }
  function esc(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
                    .replace(/"/g, "&quot;");
  }
  function num(x) { return x === null ? "—" : x.toFixed(2) + "%"; }

  /* One of the feature page's selectors: a directory prefix or a path
     fragment; `!foo` removes what it matches, so two rows can split one
     directory the same way the feature page does. */
  function selMatch(c, sel) {
    return c.d === sel || c.d.indexOf(sel + "/") === 0 || c.f.indexOf(sel) >= 0;
  }
  function selected(c, sels) {
    var keep = sels.filter(function (s) { return s.charAt(0) !== "!"; });
    var drop = sels.filter(function (s) { return s.charAt(0) === "!"; });
    if (drop.some(function (s) { return selMatch(c, s.slice(1)); })) return false;
    return !keep.length || keep.some(function (s) { return selMatch(c, s); });
  }

  function img(c, kind, alt, full) {
    if (!(kind === "d" ? c.df : c[kind])) return '<div class="stage empty">n/a</div>';
    var dir = full && c.x ? "img/suite-full/" : "img/suite/";
    return '<div class="stage"><img loading="lazy" src="' + dir + enc(c.f) + "." + kind +
           '.png" alt="' + alt + '"></div>';
  }

  function browserImg(c) {
    return '<div class="stage"><img loading="lazy" src="svg/suite/' + enc(c.f) +
           '" alt="your browser\'s rendering"></div>';
  }

  function cardHtml(c, idx) {
    var err = "";
    if (c.err) err = '<div class="err">rc=' + esc(c.rc) + ": " + esc(c.err) + "</div>";
    else if (c.rc !== "" && c.rc !== "0") err = '<div class="err">rc=' + esc(c.rc) + "</div>";
    return '<article class="card ' + c.g + '" data-i="' + idx + '">' +
      '<span class="badge">' + esc(c.s) + "</span>" +
      "<h3>" + esc(c.f) + "</h3>" +
      '<div class="metrics">' + (c.z || "—") + " · within-8 " + num(c.w) +
      " · exact " + num(c.e) + "</div>" + err +
      '<div class="cols">' +
      "<figure>" + img(c, "o", "lean-svg rendering", false) + "<figcaption>lean-svg</figcaption></figure>" +
      "<figure>" + img(c, "r", "resvg rendering", false) + "<figcaption>resvg</figcaption></figure>" +
      "<figure>" + browserImg(c) + "<figcaption>browser</figcaption></figure>" +
      "<figure>" + img(c, "d", "difference", false) + "<figcaption>diff</figcaption></figure>" +
      "</div></article>";
  }

  function filtered() {
    var rows = state.data;
    if (state.sel.length) {
      rows = rows.filter(function (c) { return selected(c, state.sel); });
    }
    if (state.top) rows = rows.filter(function (c) { return c.t === state.top; });
    if (state.sub) rows = rows.filter(function (c) { return c.d === state.sub; });
    if (state.status) rows = rows.filter(function (c) { return c.g === state.status; });
    if (state.q) {
      var q = state.q.toLowerCase();
      rows = rows.filter(function (c) { return c.f.toLowerCase().indexOf(q) >= 0; });
    }
    rows = rows.slice();
    if (state.sort === "worst") {
      rows.sort(function (a, b) {
        return (a.w === null ? -1 : a.w) - (b.w === null ? -1 : b.w) || a.f.localeCompare(b.f);
      });
    } else {
      rows.sort(function (a, b) { return a.f.localeCompare(b.f); });
    }
    return rows;
  }

  function render(reset) {
    if (reset) state.shown = PAGE;
    state.rows = filtered();
    var slice = state.rows.slice(0, state.shown);
    var passing = state.rows.filter(function (c) { return c.s === "pass"; }).length;
    $("countLabel").textContent =
      state.rows.length + " of " + state.data.length + " files · " + passing + " pass" +
      (state.rows.length ? " (" + (passing / state.rows.length * 100).toFixed(1) + "%)" : "");
    $("cards").innerHTML = slice.map(function (c) {
      return cardHtml(c, state.data.indexOf(c));
    }).join("");
    $("moreBtn").hidden = state.rows.length <= state.shown;
    $("moreBtn").textContent = "show more (" + (state.rows.length - state.shown) + " left)";
  }

  function fillSelect(sel, values, label) {
    sel.innerHTML = '<option value="">' + label + "</option>" +
      values.map(function (v) { return '<option value="' + esc(v) + '">' + esc(v) + "</option>"; }).join("");
  }

  /* #dirs=shapes/rect,shapes/circle — the feature page links here. */
  function readHash() {
    var hash = location.hash.replace(/^#/, "");
    if (!hash) return;
    hash.split("&").forEach(function (pair) {
      var kv = pair.split("=");
      var key = decodeURIComponent(kv[0] || "");
      var val = decodeURIComponent((kv[1] || "").replace(/\+/g, " "));
      if (key === "dirs" && val) state.sel = val.split(",");
      if (key === "status") state.status = val;
      if (key === "q") state.q = val;
    });
  }

  function showSelection() {
    var box = $("countLabel");
    if (!state.sel.length) return;
    box.title = "filtered to: " + state.sel.join(", ");
    var note = document.createElement("span");
    note.className = "muted";
    note.textContent = " · filtered to " + state.sel.join(", ");
    box.appendChild(note);
  }

  function openOverlay(c) {
    $("ovTitle").textContent = c.f;
    var set = function (id, kind) {
      var el = $(id);
      var have = kind === "d" ? c.df : c[kind];
      var dir = c.x ? "img/suite-full/" : "img/suite/";
      /* A rejected or unrendered file has no image: say so instead of showing
         a broken one. */
      el.hidden = !have;
      el.parentNode.classList.toggle("empty", !have);
      el.parentNode.dataset.note = have ? "" : "not rendered";
      if (have) el.src = dir + enc(c.f) + "." + kind + ".png";
      else el.removeAttribute("src");
    };
    set("ovOurs", "o");
    set("ovRef", "r");
    set("ovDiff", "d");
    $("ovBrowser").src = "svg/suite/" + enc(c.f);
    $("ovMeta").textContent =
      c.s + " · " + (c.z || "size —") + " · within-8 " + num(c.w) + " · exact " + num(c.e) +
      (c.err ? " · rc=" + c.rc + ": " + c.err : "");
    $("ovSrc").href = "svg/suite/" + enc(c.f);
    $("overlay").classList.remove("hidden");
  }
  function closeOverlay() { $("overlay").classList.add("hidden"); }

  function init(data) {
    state.data = data;
    var tops = [], subs = [];
    data.forEach(function (c) {
      if (tops.indexOf(c.t) < 0) tops.push(c.t);
      if (subs.indexOf(c.d) < 0) subs.push(c.d);
    });
    tops.sort(); subs.sort();
    fillSelect($("topFilter"), tops, "(all)");
    fillSelect($("subFilter"), subs, "(all)");

    readHash();
    $("statusFilter").value = state.status;
    $("searchBox").value = state.q;

    $("topFilter").addEventListener("change", function () {
      state.top = this.value; state.sub = ""; $("subFilter").value = "";
      fillSelect($("subFilter"), subs.filter(function (d) {
        return !state.top || d.split("/")[0] === state.top;
      }), "(all)");
      render(true);
    });
    $("subFilter").addEventListener("change", function () { state.sub = this.value; render(true); });
    $("statusFilter").addEventListener("change", function () { state.status = this.value; render(true); });
    $("sortSelect").addEventListener("change", function () { state.sort = this.value; render(true); });
    $("searchBox").addEventListener("input", function () { state.q = this.value; render(true); });
    $("resetBtn").addEventListener("click", function () {
      state.sel = []; state.top = state.sub = state.status = state.q = "";
      location.hash = "";
      $("topFilter").value = ""; $("subFilter").value = "";
      $("statusFilter").value = ""; $("searchBox").value = "";
      fillSelect($("subFilter"), subs, "(all)");
      render(true);
    });
    $("moreBtn").addEventListener("click", function () { state.shown += PAGE; render(false); });
    $("cards").addEventListener("click", function (e) {
      var card = e.target.closest(".card");
      if (card) openOverlay(state.data[parseInt(card.dataset.i, 10)]);
    });
    $("overlayClose").addEventListener("click", closeOverlay);
    $("overlay").addEventListener("click", function (e) { if (e.target === this) closeOverlay(); });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape") closeOverlay(); });
    window.addEventListener("hashchange", function () {
      state.sel = []; readHash(); render(true); showSelection();
    });

    render(true);
    showSelection();
  }

  fetch("data/gallery.json").then(function (r) { return r.json(); }).then(init);
})();
