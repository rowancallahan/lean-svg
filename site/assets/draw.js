/* Draw: a browser-only toy. Click on the canvas, get SVG source, see your own
   browser render it. Adapted from playground/index.html's draw panel; nothing
   here talks to a server. */
(function () {
  "use strict";

  var SIZE = 240;
  var BLANK = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + SIZE + " " + SIZE +
              '" width="' + SIZE + '" height="' + SIZE + '">\n</svg>\n';
  var HINTS = {
    polygon: "Click to add points; double-click or “close shape” to finish.",
    freehand: "Drag to draw a freehand path.",
    circle: "Drag from the centre outward.",
    rect: "Drag to define a rectangle.",
    line: "Drag from one end to the other."
  };

  var $ = function (id) { return document.getElementById(id); };
  var canvas = $("drawCanvas"), ctx = canvas.getContext("2d");
  var src = $("src"), preview = $("preview");
  var mode = "polygon", poly = [], free = [], dragStart = null, dragNow = null;
  var history = [];

  function b64(text) {
    return btoa(String.fromCharCode.apply(null, new TextEncoder().encode(text)));
  }
  function dataUrl() { return "data:image/svg+xml;base64," + b64(src.value); }

  function setMode(m) {
    mode = m;
    poly = []; free = []; dragStart = null; dragNow = null;
    Array.prototype.forEach.call(document.querySelectorAll(".mode"), function (b) {
      b.classList.toggle("on", b.dataset.mode === m);
    });
    $("closeShape").disabled = (m !== "polygon");
    $("drawHint").textContent = HINTS[m];
    paint();
  }

  function pos(e) {
    var r = canvas.getBoundingClientRect();
    return {
      x: Math.round(Math.max(0, Math.min(canvas.width, (e.clientX - r.left) * (canvas.width / r.width)))),
      y: Math.round(Math.max(0, Math.min(canvas.height, (e.clientY - r.top) * (canvas.height / r.height))))
    };
  }

  function styleAttrs() {
    var w = parseFloat($("strokeWidth").value) || 0;
    var a = ' fill="' + ($("noFill").checked ? "none" : $("fill").value) + '"';
    if (w > 0) a += ' stroke="' + $("stroke").value + '" stroke-width="' + w + '"';
    return a;
  }

  function append(el) {
    history.push(src.value);
    var text = src.value;
    var i = text.lastIndexOf("</svg>");
    if (i < 0) { text = BLANK; i = text.lastIndexOf("</svg>"); }
    src.value = text.slice(0, i) + "  " + el + "\n" + text.slice(i);
    update();
  }

  function finishPolygon() {
    if (poly.length >= 3) {
      append('<polygon points="' + poly.map(function (p) { return p.x + "," + p.y; }).join(" ") +
             '"' + styleAttrs() + "/>");
    }
    poly = [];
    paint();
  }

  function finishFreehand() {
    if (free.length >= 2) {
      var d = "M " + free[0].x + " " + free[0].y;
      for (var i = 1; i < free.length; i++) d += " L " + free[i].x + " " + free[i].y;
      append('<path d="' + d + '"' + styleAttrs() + "/>");
    }
    free = [];
    paint();
  }

  canvas.addEventListener("pointerdown", function (e) {
    e.preventDefault();
    try { canvas.setPointerCapture(e.pointerId); } catch (err) { /* not capturable */ }
    var p = pos(e);
    if (mode === "polygon") { poly.push(p); paint(); }
    else if (mode === "freehand") { free = [p]; }
    else { dragStart = p; dragNow = p; }
  });

  canvas.addEventListener("pointermove", function (e) {
    var p = pos(e);
    if (mode === "freehand" && free.length) {
      var last = free[free.length - 1];
      if (Math.abs(p.x - last.x) + Math.abs(p.y - last.y) >= 3) { free.push(p); paint(); }
    } else if (dragStart) { dragNow = p; paint(); }
    else if (mode === "polygon" && poly.length) { paint(p); }
  });

  canvas.addEventListener("pointerup", function (e) {
    var p = pos(e);
    if (mode === "freehand") { if (free.length) { free.push(p); finishFreehand(); } return; }
    if (!dragStart) return;
    var a = dragStart, b = p;
    dragStart = null; dragNow = null;
    if (mode === "circle") {
      var r = Math.round(Math.hypot(b.x - a.x, b.y - a.y));
      if (r > 0) append('<circle cx="' + a.x + '" cy="' + a.y + '" r="' + r + '"' + styleAttrs() + "/>");
    } else if (mode === "rect") {
      var w = Math.abs(b.x - a.x), h = Math.abs(b.y - a.y);
      if (w > 0 && h > 0) {
        append('<rect x="' + Math.min(a.x, b.x) + '" y="' + Math.min(a.y, b.y) +
               '" width="' + w + '" height="' + h + '"' + styleAttrs() + "/>");
      }
    } else if (mode === "line") {
      var sw = parseFloat($("strokeWidth").value) || 2;
      append('<line x1="' + a.x + '" y1="' + a.y + '" x2="' + b.x + '" y2="' + b.y +
             '" stroke="' + $("stroke").value + '" stroke-width="' + sw + '"/>');
    }
    paint();
  });

  canvas.addEventListener("dblclick", function (e) {
    e.preventDefault();
    if (mode === "polygon") finishPolygon();
  });

  Array.prototype.forEach.call(document.querySelectorAll(".mode"), function (b) {
    b.addEventListener("click", function () { setMode(b.dataset.mode); });
  });
  $("closeShape").addEventListener("click", finishPolygon);
  $("undo").addEventListener("click", function () {
    if (history.length) { src.value = history.pop(); update(); }
  });
  $("clearDraw").addEventListener("click", function () {
    history.push(src.value);
    poly = []; free = []; dragStart = null; dragNow = null;
    src.value = BLANK;
    update();
  });
  $("download").addEventListener("click", function () {
    var blob = new Blob([src.value], { type: "image/svg+xml" });
    var a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "drawing.svg";
    a.click();
    setTimeout(function () { URL.revokeObjectURL(a.href); }, 1000);
  });
  src.addEventListener("input", update);

  /* The browser's own rendering, live, plus the same image under the canvas so
     you draw on top of what you have. */
  function update() {
    var url = dataUrl();
    preview.innerHTML = "";
    var shown = new Image();
    shown.alt = "your browser's rendering of the SVG source";
    shown.src = url;
    preview.appendChild(shown);
    paint();
  }

  function paint(ghost) {
    var img = new Image();
    img.onload = function () { draw(img, ghost); };
    img.onerror = function () { draw(null, ghost); };
    img.src = dataUrl();
  }

  function draw(img, ghost) {
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    if (img) { try { ctx.drawImage(img, 0, 0, canvas.width, canvas.height); } catch (e) { /* ignore */ } }
    ctx.lineWidth = 1;
    ctx.strokeStyle = "#0a7";
    ctx.setLineDash([4, 3]);
    if (mode === "polygon" && poly.length) {
      ctx.beginPath();
      ctx.moveTo(poly[0].x, poly[0].y);
      for (var i = 1; i < poly.length; i++) ctx.lineTo(poly[i].x, poly[i].y);
      if (ghost) ctx.lineTo(ghost.x, ghost.y);
      ctx.stroke();
      ctx.setLineDash([]);
      ctx.fillStyle = "#0a7";
      poly.forEach(function (p) { ctx.fillRect(p.x - 2, p.y - 2, 4, 4); });
    } else if (mode === "freehand" && free.length > 1) {
      ctx.setLineDash([]);
      ctx.beginPath();
      ctx.moveTo(free[0].x, free[0].y);
      for (var j = 1; j < free.length; j++) ctx.lineTo(free[j].x, free[j].y);
      ctx.stroke();
    } else if (dragStart && dragNow) {
      if (mode === "circle") {
        ctx.beginPath();
        ctx.arc(dragStart.x, dragStart.y, Math.hypot(dragNow.x - dragStart.x, dragNow.y - dragStart.y), 0, Math.PI * 2);
        ctx.stroke();
      } else if (mode === "rect") {
        ctx.strokeRect(Math.min(dragStart.x, dragNow.x), Math.min(dragStart.y, dragNow.y),
                       Math.abs(dragNow.x - dragStart.x), Math.abs(dragNow.y - dragStart.y));
      } else if (mode === "line") {
        ctx.beginPath();
        ctx.moveTo(dragStart.x, dragStart.y);
        ctx.lineTo(dragNow.x, dragNow.y);
        ctx.stroke();
      }
    }
    ctx.setLineDash([]);
  }

  src.value = BLANK;
  setMode("polygon");
  update();
})();
