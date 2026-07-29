/* Fleet Desk — Ops Floor poller (Phase B).
   Served as site/experience/assets/floor.js; loaded only by /live/index.html.

   Reads the live/1 projection (data/live.json, written by scripts/desk_live.py)
   over http and repaints the floor regions in place. Honesty rules:
     - renders ONLY what the projection carries — no invented seats or timers
     - staleness is recomputed from last_event_ts against the projection's own
       thresholds, so a stream that stops goes STALE then OFFLINE on its own
     - file:// desks usually block fetch(); on any failure the static snapshot
       rendered at build time stays on screen, untouched
   No frameworks, no build step. */
(function () {
  "use strict";

  var me = document.currentScript;
  var url = me && me.getAttribute("data-live-json");
  if (!url || typeof fetch !== "function") return;

  var POLL_MS = 3000;

  function $(id) { return document.getElementById(id); }

  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function fmtDur(secs) {
    if (typeof secs !== "number" || !isFinite(secs) || secs < 0) return "—";
    var s = Math.floor(secs);
    if (s < 60) return s + "s";
    var m = Math.floor(s / 60);
    if (m < 60) return m + "m" + ("0" + (s % 60)).slice(-2) + "s";
    return Math.floor(m / 60) + "h" + ("0" + (m % 60)).slice(-2) + "m";
  }

  function timeOf(ts) {
    // Event timestamps are naive UTC ISO-8601 with a trailing Z.
    var d = new Date(ts);
    return isNaN(d.getTime()) ? String(ts || "—") : d.toUTCString().slice(17, 25) + "Z";
  }

  /* Staleness: trust timestamps over the stored snapshot state. */
  function liveState(d) {
    var stale = (d.staleness && d.staleness.stale_after_s) || 120;
    var offline = (d.staleness && d.staleness.offline_after_s) || 900;
    var t = new Date(d.last_event_ts || "").getTime();
    if (isNaN(t)) {
      return { state: (d.staleness && d.staleness.state) || "none", age: null };
    }
    var age = Math.max(0, Math.round((Date.now() - t) / 1000));
    var state = age >= offline ? "offline" : age >= stale ? "stale" : "live";
    return { state: state, age: age };
  }

  var LED_CLASS = { live: "led live", stale: "led stale", offline: "led off", none: "led off" };

  /* Seat status → pill (text AND color, mirrored in experience_build.py). */
  function seatPill(seat) {
    var st = seat.status || "queued";
    if (st === "success" || st === "done") return '<span class="st st-done">settled</span>';
    if (st === "running") return '<span class="st st-run">in flight</span>';
    if (st === "ratecap") return '<span class="st st-warn">rate-capped</span>';
    if (st === "failed" || st === "blocked" || st === "unavailable") {
      return '<span class="st st-fail">blocked</span>';
    }
    if (st === "queued") return '<span class="st st-unk">queued</span>';
    return '<span class="st st-unk">' + esc(st) + "</span>";
  }

  function seatTimer(seat) {
    if (seat.status === "running") return fmtDur(seat.elapsed_s);
    return fmtDur(seat.duration_s);
  }

  function seatLane(seat) {
    var chips = "";
    if (seat.ratecapped) chips += '<span class="vendor warn">rate-cap</span>';
    (seat.failovers || []).forEach(function (f) {
      chips += '<span class="vendor warn">failover ' + esc(f.from) + " → " + esc(f.to) + "</span>";
    });
    var vendor = [seat.provider, seat.model].filter(Boolean).join(" · ");
    return '<div class="lane' + (seat.status === "running" ? " run" : "") + '">' +
      '<div class="lane-top"><span class="role">' + esc(seat.agent || seat.task_id) + "</span>" +
      seatPill(seat) + '<span class="timer">' + seatTimer(seat) + "</span></div>" +
      '<div class="branch">' + esc(seat.branch || "branch not yet reported") + "</div>" +
      '<span class="vendor">' + esc(vendor || "provider —") + "</span>" + chips +
      "</div>";
  }

  function ghostLane() {
    return '<div class="lane ghost">' +
      '<div class="lane-top"><span class="role">plan seat</span>' +
      '<span class="st st-unk">queued</span><span class="timer">—</span></div>' +
      '<div class="branch">seat planned by the dispatch, not yet started</div>' +
      '<span class="vendor">provider —</span></div>';
  }

  function renderAmbient(d, st) {
    var led = $("floor-led");
    if (led) led.className = LED_CLASS[st.state] || "led off";
    var msg = $("floor-msg");
    if (msg) {
      msg.innerHTML = "<strong>" + esc(d.status || "unknown") + "</strong> — dispatch " +
        "<span class=\"mono\">" + esc(d.dispatch_id || "—") + "</span>" +
        (st.state !== "live" ? " · stream " + esc(st.state) : "");
    }
    var meta = $("floor-meta");
    if (meta) {
      meta.textContent = (d.source || "live.json") +
        " · last event " + (st.age == null ? "—" : fmtDur(st.age) + " ago") +
        " · snapshot " + esc(d.generated_at || "—");
    }
  }

  function renderWaiting(d) {
    var box = $("floor-waiting-items");
    if (!box) return;
    var items = d.waiting_on || [];
    if (!items.length) {
      box.innerHTML = '<p class="muted flush">Nothing waiting — no open gates, no rate-caps.</p>';
      return;
    }
    box.innerHTML = items.map(function (w) {
      return '<p class="witem flush"><span class="pill accent">' + esc(w.kind || "wait") + "</span> " +
        esc(w.label || "waiting") +
        (w.since ? ' <span class="muted">since ' + esc(timeOf(w.since)) + "</span>" : "") + "</p>";
    }).join("");
  }

  function renderCounts(d) {
    var c = d.counts || {};
    var ids = { queued: "pipe-queued", in_flight: "pipe-inflight", blocked: "pipe-blocked", settled: "pipe-settled" };
    Object.keys(ids).forEach(function (k) {
      var el = $(ids[k]);
      if (el) el.textContent = (typeof c[k] === "number" ? c[k] : "—");
    });
  }

  function renderLanes(d) {
    var mode = $("floor-mode-body");
    if (!mode) return;
    var seats = d.seats || [];
    var ghosts = 0;
    if (typeof d.seats_planned === "number" && d.seats_planned > seats.length) {
      ghosts = d.seats_planned - seats.length;
    }
    var byWave = {};
    seats.forEach(function (s) {
      var w = typeof s.wave === "number" ? s.wave : 0;
      (byWave[w] = byWave[w] || []).push(s);
    });
    var inner = "";
    Object.keys(byWave).sort(function (a, b) { return a - b; }).forEach(function (w) {
      var cur = d.wave && d.wave.current === Number(w) ? " · current" : "";
      inner += '<h3 class="wavehead2">Wave ' + esc(w) + cur + "</h3>" +
        '<div class="lanes">' + byWave[w].map(seatLane).join("") + "</div>";
    });
    if (ghosts) {
      var g = "";
      for (var i = 0; i < ghosts; i++) g += ghostLane();
      inner += '<h3 class="wavehead2">Planned, not started</h3><div class="lanes">' + g + "</div>";
    }
    if (!inner) {
      inner = '<p class="empty">Dispatch reported no seats yet — the stream is the only source of lanes.</p>';
    }
    mode.innerHTML = '<div class="card"><div class="cardhead"><h2>Wave — parallel seat lanes</h2>' +
      '<span class="more faint">wave mode</span></div>' +
      '<p class="muted">Ghost lanes are plan seats not yet started. Rate-cap and failover ride the lane as honest chrome.</p>' +
      inner + "</div>";
  }

  function renderSpine(d) {
    var mode = $("floor-mode-body");
    if (!mode) return;
    var seats = d.seats || [];
    var inner;
    if (!seats.length) {
      inner = '<p class="empty">Conductor run reported no seats yet.</p>';
    } else {
      var nodes = seats.map(function (s, i) {
        var cls = s.status === "running" ? " hot"
          : (s.status === "success" || s.status === "done") ? " done" : "";
        return '<div class="spine-node' + cls + '"><div class="orb">' + (i + 1) + "</div>" +
          '<div class="nm">' + esc(s.agent || s.task_id) + "</div>" +
          '<div class="meta">' + esc(s.status) + " · " + seatTimer(s) + "</div></div>";
      });
      inner = '<div class="spine">' + nodes.join('<span class="spine-link"></span>') + "</div>";
    }
    mode.innerHTML = '<div class="card"><div class="cardhead"><h2>Conductor — serial spine</h2>' +
      '<span class="more faint">conductor mode</span></div>' +
      '<p class="muted">Settled nodes fill, the hot pin marks the live seat, dashed nodes stay ahead of it.</p>' +
      inner + "</div>";
  }

  function renderEvents(d) {
    var box = $("floor-events");
    if (!box) return;
    var evs = (d.recent_events || []).slice(-12).reverse();
    if (!evs.length) {
      box.innerHTML = '<li class="muted">No events in the projection tail.</li>';
      return;
    }
    box.innerHTML = evs.map(function (ev) {
      var det = ev.task_id != null ? "task " + ev.task_id : "";
      det += ev.agent ? " " + ev.agent : "";
      det += ev.provider ? " · " + ev.provider : "";
      return "<li><span class=\"ets mono\">" + esc(timeOf(ev.ts)) + "</span> " +
        '<span class="ekind">' + esc(ev.event) + "</span>" +
        (det ? ' <span class="edet muted">' + esc(det.trim()) + "</span>" : "") + "</li>";
    }).join("");
  }

  function renderAll(d) {
    if (!d || d.schema !== "live/1") return;
    var st = liveState(d);
    renderAmbient(d, st);
    renderWaiting(d);
    renderCounts(d);
    if (d.mode === "conductor") renderSpine(d); else renderLanes(d);
    renderEvents(d);
  }

  function poll() {
    fetch(url, { cache: "no-store" })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (d) { if (d) renderAll(d); })
      .catch(function () { /* file:// or server down: keep the build snapshot */ })
      .then(function () { setTimeout(poll, POLL_MS); });
  }

  poll();
})();
