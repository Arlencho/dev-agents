/* Fleet Desk — Ops Floor poller + Phase C replay scrubber.
   Served as site/experience/assets/floor.js; loaded only by /live/index.html.

   Live mode (Phase B):
     Reads data/live.json (live/1) over http and repaints regions.
   Replay mode (Phase C):
     Scrubs a settled stream via /api/replay?dispatch_id=&as_of_seq=
     (or a build-time snapshot stamped view=replay). Honesty watermark REPLAY
     is always visible; green LIVE LED is never painted in replay.

   Honesty rules:
     - only projection facts — no invented seats
     - staleness from last_event_ts for live; replay forces state=replay
     - file:// desks keep the build snapshot when fetch fails
   No frameworks, no build step. */
(function () {
  "use strict";

  var me = document.currentScript;
  var liveUrl = (me && me.getAttribute("data-live-json")) || "../data/live.json";
  var runsUrl = (me && me.getAttribute("data-runs-url")) || "/api/runs";
  var replayUrl = (me && me.getAttribute("data-replay-url")) || "/api/replay";
  if (typeof fetch !== "function") return;

  var POLL_MS = 3000;
  var params = new URLSearchParams(window.location.search || "");
  var hash = (window.location.hash || "").replace(/^#/, "");
  var mode = {
    // ?replay=1 or #replay both enter scrub mode (hash keeps static hrefs resolvable).
    replay: params.get("replay") === "1" || params.get("view") === "replay" || hash === "replay",
    dispatchId: params.get("dispatch_id") || "",
    asOfSeq: params.get("as_of_seq") ? parseInt(params.get("as_of_seq"), 10) : null,
    pollTimer: null,
    last: null,
  };

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
    var d = new Date(ts);
    return isNaN(d.getTime()) ? String(ts || "—") : d.toUTCString().slice(17, 25) + "Z";
  }

  /* Live: trust timestamps. Replay: never claim live. */
  function liveState(d) {
    if (d && (d.view === "replay" || (d.replay && d.replay.watermark === "REPLAY"))) {
      var ageR = (d.staleness && typeof d.staleness.seconds === "number")
        ? d.staleness.seconds : null;
      return { state: "replay", age: ageR };
    }
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

  var LED_CLASS = {
    live: "led live",
    stale: "led stale",
    offline: "led off",
    none: "led off",
    replay: "led replay",
  };

  function seatPill(seat) {
    var st = seat.status || "queued";
    if (st === "success" || st === "done") return '<span class="st st-done">settled</span>';
    if (st === "running") return '<span class="st st-run">in flight</span>';
    if (st === "ratecap") return '<span class="st st-warn">rate-capped</span>';
    if (st === "failed" || st === "blocked" || st === "unavailable" || st === "unknown") {
      return '<span class="st st-fail">blocked</span>';
    }
    if (st === "queued") return '<span class="st st-unk">queued</span>';
    return '<span class="st st-unk">' + esc(st) + "</span>";
  }

  function seatTimer(seat) {
    if (seat.status === "running") return fmtDur(seat.elapsed_s);
    return fmtDur(seat.duration_s);
  }

  function almanacLinks() {
    var el = $("floor-almanac-links");
    if (!el) return { by_branch: {}, by_mission: {} };
    try {
      return JSON.parse(el.textContent || "{}");
    } catch (e) {
      return { by_branch: {}, by_mission: {} };
    }
  }

  function seatLane(seat) {
    var links = almanacLinks();
    var chips = "";
    if (seat.ratecapped) chips += '<span class="vendor warn">rate-cap</span>';
    (seat.failovers || []).forEach(function (f) {
      chips += '<span class="vendor warn">failover ' + esc(f.from) + " → " + esc(f.to) + "</span>";
    });
    var vendor = [seat.provider, seat.model].filter(Boolean).join(" · ");
    var branch = seat.branch || "";
    var trailId = branch && links.by_branch ? links.by_branch[branch] : null;
    var branchHtml = esc(branch || "branch not yet reported");
    if (trailId) {
      branchHtml = '<a href="../trail/' + esc(trailId) + '/index.html" class="mono">' +
        esc(branch) + "</a> <span class=\"faint\">→ trail</span>";
    }
    return '<div class="lane' + (seat.status === "running" ? " run" : "") + '">' +
      '<div class="lane-top"><span class="role">' + esc(seat.agent || seat.task_id) + "</span>" +
      seatPill(seat) + '<span class="timer">' + seatTimer(seat) + "</span></div>" +
      '<div class="branch">' + branchHtml + "</div>" +
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

  function renderWatermark(st, d) {
    var wm = $("floor-watermark");
    if (!wm) return;
    if (st.state === "replay" || (d && d.view === "replay")) {
      wm.hidden = false;
      wm.innerHTML =
        '<span class="wm-badge" aria-label="Replay mode">REPLAY</span>' +
        '<span class="wm-copy">Historical scrub — not a live dispatch. ' +
        "Only events at or before the scrubber position are shown.</span>";
    } else {
      wm.hidden = true;
      wm.innerHTML = "";
    }
  }

  function renderAmbient(d, st) {
    var led = $("floor-led");
    if (led) led.className = LED_CLASS[st.state] || "led off";
    var msg = $("floor-msg");
    if (msg) {
      var extra = "";
      if (st.state === "replay") extra = " · <strong class=\"wm-inline\">REPLAY</strong>";
      else if (st.state !== "live") extra = " · stream " + esc(st.state);
      // Hang honesty: still "running" but quiet → call it out in ambient
      var quiet = (d.waiting_on || []).some(function (w) { return w.kind === "quiet_stream"; });
      if (quiet && st.state !== "replay") {
        extra += ' · <strong class="wm-inline">QUIET</strong> (no new events)';
      }
      msg.innerHTML = "<strong>" + esc(d.status || "unknown") + "</strong> — dispatch " +
        "<span class=\"mono\">" + esc(d.dispatch_id || "—") + "</span>" + extra;
    }
    var meta = $("floor-meta");
    if (meta) {
      var seqNote = "";
      if (d.replay && d.replay.as_of_seq != null) {
        seqNote = " · as_of_seq " + d.replay.as_of_seq + "/" + (d.replay.total_events || "—");
      }
      meta.textContent = (d.source || "live.json") +
        " · last event " + (st.age == null ? "—" : fmtDur(st.age) + " ago") +
        (st.age != null && st.age >= 90 ? " · follow may be stuck" : "") +
        " · snapshot " + esc(d.generated_at || "—") + seqNote;
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
      var kind = w.kind || "wait";
      var pillCls = kind === "quiet_stream" ? "pill warn" : "pill accent";
      return '<p class="witem flush' + (kind === "quiet_stream" ? " quiet" : "") + '">' +
        '<span class="' + pillCls + '">' + esc(kind) + "</span> " +
        esc(w.label || "waiting") +
        (w.seconds != null ? ' <span class="muted mono">(' + esc(fmtDur(w.seconds)) + ")</span>" : "") +
        (w.since && kind !== "quiet_stream" ? ' <span class="muted">since ' + esc(timeOf(w.since)) + "</span>" : "") +
        "</p>";
    }).join("");
  }

  function renderCounts(d) {
    var c = d.counts || {};
    var ids = { in_flight: "pipe-inflight", blocked: "pipe-blocked", settled: "pipe-settled" };
    Object.keys(ids).forEach(function (k) {
      var el = $(ids[k]);
      if (el) el.textContent = (typeof c[k] === "number" ? c[k] : "\u2014");
    });
    /* Queued counts PLANS, not seats: the only real queue is the declared one.
       With no queue file we fall back to the seat count and say so. */
    var meta = d.queue_meta || {};
    var queued = (d.queue || []).length;
    var cell = $("pipe-queued");
    if (cell) {
      cell.textContent = meta.declared
        ? queued
        : (typeof c.queued === "number" ? c.queued : "\u2014");
    }
    var desc = $("pipe-queued-desc");
    if (desc) {
      desc.innerHTML = meta.declared
        ? "plans armed in <span class=\"mono\">" + esc(meta.source || "logs/fleet-queue.json") + "</span>"
        : "no queue declared, showing plan seats not started";
    }
  }

  /* The now view: what every live seat is doing, why, and for how long.
     Purpose and task come from the plan file (projection side), elapsed ticks
     in the browser from the seat_dispatch timestamp, and a seat whose last sign
     of life is older than the quiet threshold wears the watermark badge. */
  function nowRow(seat) {
    var quiet = seat.quiet === true;
    var wave = (typeof seat.wave === "number")
      ? ("wave " + seat.wave + (seat.wave_total ? " of " + seat.wave_total : ""))
      : "wave not reported";
    var beat = seat.last_heartbeat_ts
      ? "last heartbeat " + timeOf(seat.last_heartbeat_ts) +
        (typeof seat.heartbeat_age_s === "number" ? " (" + fmtDur(seat.heartbeat_age_s) + " ago)" : "")
      : "no heartbeat yet";
    return '<li class="nowrow' + (quiet ? " quiet" : "") + '">' +
      '<div class="nowhead"><span class="role">' + esc(seat.agent || seat.task_id) + "</span>" +
      seatPill(seat) +
      (quiet ? '<span class="wm-badge" title="no sign of life since the quiet threshold">quiet</span>' : "") +
      '<span class="timer mono" data-elapsed-from="' + esc(seat.started_at || "") + '">' +
      fmtDur(seat.elapsed_s) + "</span></div>" +
      '<div class="nowpurpose">' + esc(seat.plan_purpose || "purpose not declared in the plan header") + "</div>" +
      '<div class="nowtask">' + esc(seat.task || "task line not resolvable from the plan on this machine") + "</div>" +
      '<div class="nowmeta"><span class="vendor">' + esc(wave) + "</span>" +
      '<span class="vendor">attempt ' + esc(seat.attempt || 1) + "</span>" +
      '<span class="mono faint">' + esc(seat.branch || "branch not reported") + "</span>" +
      '<span class="faint">' + esc(beat) + "</span></div></li>";
  }

  function renderNow(d) {
    var box = $("floor-now-list");
    if (!box) return;
    var live = (d.seats || []).filter(function (s) { return s.status === "running"; });
    var note = $("floor-now-note");
    if (note) {
      var runs = {};
      live.forEach(function (s) { if (s.dispatch_id) runs[s.dispatch_id] = 1; });
      var n = Object.keys(runs).length;
      note.textContent = live.length
        ? live.length + " live seat(s) across " + (n || 1) + " dispatch(es)"
        : "no seat is live";
    }
    box.innerHTML = live.length
      ? live.map(nowRow).join("")
      : '<li class="muted">No seat is live. The Floor shows motion only while a dispatch is running.</li>';
    tickElapsed();
  }

  /* One ticker for the page: elapsed counts up every second from the timestamp
     the stream recorded, so a live seat never looks frozen between polls. */
  function tickElapsed() {
    var nodes = document.querySelectorAll("[data-elapsed-from]");
    for (var i = 0; i < nodes.length; i++) {
      var from = new Date(nodes[i].getAttribute("data-elapsed-from") || "").getTime();
      if (isNaN(from)) continue;
      nodes[i].textContent = fmtDur(Math.max(0, Math.round((Date.now() - from) / 1000)));
    }
  }

  /* Up next: declared intent. Never rendered as motion, never as "running". */
  function renderQueue(d) {
    var box = $("floor-queue-list");
    if (!box) return;
    var items = d.queue || [];
    var meta = d.queue_meta || {};
    var note = $("floor-queue-note");
    if (note) {
      note.innerHTML = meta.declared
        ? "Declared by the orchestrator in <span class=\"mono\">" +
          esc(meta.source || "logs/fleet-queue.json") + "</span>, newest entry added " +
          esc(meta.declared_at || "at an unknown time") +
          ". Order is intent: a queued plan is not running."
        : "No queue declared. Arm one with <code>./scripts/queue.sh add &lt;plan&gt; &lt;repo&gt; &lt;purpose&gt;</code>.";
    }
    if (!items.length) {
      box.innerHTML = '<li class="muted">Nothing armed. The next dispatch is whatever the operator types.</li>';
      return;
    }
    box.innerHTML = items.map(function (q) {
      return '<li class="qrow">' +
        '<span class="qpos mono">' + esc(q.position) + "</span>" +
        '<span class="qbody"><span class="qpurpose">' +
        esc(q.purpose || "no purpose declared") + "</span>" +
        '<span class="qmeta"><span class="vendor">' + esc(q.repo || "repo not declared") + "</span> " +
        '<span class="mono faint">' + esc(q.plan_basename || q.plan || "") + "</span></span></span>" +
        '<span class="st st-unk">queued</span></li>';
    }).join("");
  }

  /* Landed today: every dispatch whose dispatch_end fell on this local day. */
  function renderToday(d) {
    var box = $("floor-today-list");
    if (!box) return;
    var items = d.today || [];
    var meta = d.today_meta || {};
    var note = $("floor-today-note");
    if (note) {
      note.textContent = "dispatch_end on " + (meta.date || "today") +
        " · " + (meta.streams_read || 0) + " stream(s) read" +
        ((meta.live || []).length ? " · " + meta.live.length + " still live" : "");
    }
    if (!items.length) {
      box.innerHTML = '<li class="muted">Nothing has landed today yet.</li>';
      return;
    }
    box.innerHTML = items.map(function (t) {
      var cls = t.status === "settled" ? "st st-done"
        : (t.status === "aborted" || t.status === "failed") ? "st st-fail" : "st st-unk";
      var branches = (t.branches || []).map(function (b) {
        return '<span class="mono faint">' + esc(b) + "</span>";
      }).join(" ");
      return '<li class="trow">' +
        '<span class="tbody"><span class="tpurpose">' +
        esc(t.purpose || t.plan_basename || t.dispatch_id) + "</span>" +
        '<span class="tmeta"><span class="vendor">' + esc(t.repo || "repo not reported") + "</span> " +
        (branches || '<span class="faint">no branch reported</span>') + "</span></span>" +
        '<span class="' + cls + '">' + esc(t.status || "unknown") + "</span>" +
        '<span class="timer mono">' + fmtDur(t.duration_s) + "</span></li>";
    }).join("");
  }

  function renderLanes(d) {
    var modeBody = $("floor-mode-body");
    if (!modeBody) return;
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
    modeBody.innerHTML = '<div class="card"><div class="cardhead"><h2>Wave — parallel seat lanes</h2>' +
      '<span class="more faint">wave mode</span></div>' +
      '<p class="muted">Ghost lanes are plan seats not yet started. Rate-cap and failover ride the lane as honest chrome.</p>' +
      inner + "</div>";
  }

  function renderSpine(d) {
    var modeBody = $("floor-mode-body");
    if (!modeBody) return;
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
    modeBody.innerHTML = '<div class="card"><div class="cardhead"><h2>Conductor — serial spine</h2>' +
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

  function renderCrossLinks(d) {
    var box = $("floor-cross-links");
    if (!box) return;
    var links = almanacLinks();
    var parts = [];
    parts.push('<a href="../work/index.html">Almanac · Work</a>');
    parts.push('<a href="../missions/index.html">Missions</a>');
    var plan = d.plan || "";
    if (plan && links.by_plan && links.by_plan[plan]) {
      var mslug = links.by_plan[plan];
      parts.push('<a href="../mission/' + esc(mslug) + '/index.html">Mission for plan ' + esc(plan) + "</a>");
    } else if (plan) {
      parts.push('<span class="muted">Plan <span class="mono">' + esc(plan) +
        "</span> — no mission join in this Almanac build</span>");
    }
    var seats = d.seats || [];
    var trailLinks = [];
    seats.forEach(function (s) {
      if (s.branch && links.by_branch && links.by_branch[s.branch]) {
        var tid = links.by_branch[s.branch];
        trailLinks.push('<a href="../trail/' + esc(tid) + '/index.html" class="mono">' +
          esc(s.agent || tid) + "</a>");
      }
    });
    if (trailLinks.length) {
      parts.push("Trails: " + trailLinks.join(" · "));
    }
    box.innerHTML = parts.join(" <span class=\"faint\">·</span> ");
  }

  function renderScrubber(d) {
    var panel = $("floor-scrubber");
    if (!panel) return;
    var isReplay = d.view === "replay" || mode.replay;
    var total = (d.replay && d.replay.total_events) || d.events_seen || 0;
    var cur = (d.replay && d.replay.as_of_seq != null)
      ? d.replay.as_of_seq
      : total;
    var did = d.dispatch_id || mode.dispatchId || "";
    var terminal = d.status && d.status !== "running" && d.status !== "idle";

    if (!isReplay && !terminal && !mode.replay) {
      // Live running: show a quiet entry point only if we know a dispatch id.
      if (!did) {
        panel.hidden = true;
        return;
      }
    }
    panel.hidden = false;

    if (!isReplay && terminal) {
      panel.innerHTML =
        '<div class="scrub-head"><strong>Settled run</strong> — open historical scrub</div>' +
        '<p class="muted flush">This dispatch is no longer live. Replay shows only events at or ' +
        "before the scrubber — never a green LIVE LED.</p>" +
        '<p><button type="button" class="btn-replay" id="floor-enter-replay">Enter REPLAY</button> ' +
        '<span class="mono muted">' + esc(did) + "</span></p>";
      var btn = $("floor-enter-replay");
      if (btn) {
        btn.addEventListener("click", function () {
          mode.replay = true;
          mode.dispatchId = did;
          mode.asOfSeq = total || null;
          loadReplay(did, total);
          // Update URL without reload.
          try {
            var u = new URL(window.location.href);
            u.searchParams.set("replay", "1");
            if (did) u.searchParams.set("dispatch_id", did);
            if (total) u.searchParams.set("as_of_seq", String(total));
            history.replaceState({}, "", u.toString());
          } catch (e) { /* ignore */ }
        });
      }
      return;
    }

    // Active scrubber UI
    panel.innerHTML =
      '<div class="scrub-head"><span class="wm-badge">REPLAY</span> ' +
      '<strong>Scrubber</strong> · dispatch <span class="mono">' + esc(did || "—") + "</span></div>" +
      '<label class="scrub-label" for="floor-scrub-range">Event position ' +
      '<span class="mono" id="floor-scrub-pos">' + esc(cur) + " / " + esc(total || "—") + "</span></label>" +
      '<input type="range" id="floor-scrub-range" min="1" max="' + Math.max(1, total || 1) +
      '" value="' + Math.max(1, cur || 1) + '" step="1" ' +
      (total ? "" : "disabled ") + "/>" +
      '<div class="scrub-actions">' +
      '<button type="button" class="btn-replay" id="floor-exit-replay">Exit to live Floor</button>' +
      '<span class="muted"> /api/replay?dispatch_id=&amp;as_of_seq=</span></div>' +
      '<div id="floor-run-picker" class="run-picker muted">Loading runs…</div>';

    var range = $("floor-scrub-range");
    var pos = $("floor-scrub-pos");
    var debounce = null;
    if (range) {
      range.addEventListener("input", function () {
        if (pos) pos.textContent = range.value + " / " + (total || "—");
        clearTimeout(debounce);
        debounce = setTimeout(function () {
          mode.asOfSeq = parseInt(range.value, 10);
          loadReplay(did, mode.asOfSeq);
        }, 80);
      });
    }
    var exit = $("floor-exit-replay");
    if (exit) {
      exit.addEventListener("click", function () {
        mode.replay = false;
        mode.asOfSeq = null;
        try {
          var u = new URL(window.location.href);
          u.searchParams.delete("replay");
          u.searchParams.delete("as_of_seq");
          u.searchParams.delete("view");
          history.replaceState({}, "", u.pathname + (u.search || ""));
        } catch (e) { /* ignore */ }
        startLivePoll();
      });
    }
    loadRunPicker(did);
  }

  function loadRunPicker(currentId) {
    var box = $("floor-run-picker");
    if (!box) return;
    fetch(runsUrl, { cache: "no-store" })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (cat) {
        if (!cat || !cat.runs || !cat.runs.length) {
          box.innerHTML = "No event streams under logs/fleet-events yet.";
          return;
        }
        var opts = cat.runs.map(function (r) {
          var label = (r.dispatch_id || "?") +
            " · " + (r.status || "?") +
            " · " + (r.events || 0) + " events" +
            (r.plan ? " · " + r.plan : "");
          var sel = r.dispatch_id === currentId ? " selected" : "";
          return '<option value="' + esc(r.dispatch_id) + '"' + sel + ">" + esc(label) + "</option>";
        }).join("");
        box.innerHTML = '<label>Settled / known runs <select id="floor-run-select">' +
          opts + "</select></label>";
        var sel = $("floor-run-select");
        if (sel) {
          sel.addEventListener("change", function () {
            mode.dispatchId = sel.value;
            mode.replay = true;
            loadReplay(sel.value, null);
          });
        }
      })
      .catch(function () {
        box.innerHTML = "Run catalog needs <code>make desk-live</code> (HTTP). " +
          "file:// desks: <code>python3 scripts/desk_live.py --once --replay --dispatch-id …</code>";
      });
  }

  function renderAll(d) {
    if (!d || d.schema !== "live/1") return;
    mode.last = d;
    var st = liveState(d);
    // Hard honesty: never green LIVE when view says replay.
    if (d.view === "replay" && st.state === "live") st = { state: "replay", age: st.age };
    renderWatermark(st, d);
    renderAmbient(d, st);
    renderWaiting(d);
    renderCounts(d);
    renderNow(d);
    renderQueue(d);
    renderToday(d);
    if (d.mode === "conductor") renderSpine(d); else renderLanes(d);
    renderEvents(d);
    renderCrossLinks(d);
    renderScrubber(d);
  }

  function loadReplay(dispatchId, asOfSeq) {
    stopLivePoll();
    var q = [];
    if (dispatchId) q.push("dispatch_id=" + encodeURIComponent(dispatchId));
    if (asOfSeq != null && !isNaN(asOfSeq)) q.push("as_of_seq=" + encodeURIComponent(String(asOfSeq)));
    var url = replayUrl + (q.length ? "?" + q.join("&") : "");
    fetch(url, { cache: "no-store" })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (d) {
        if (d) {
          // Server should stamp view=replay; force it if missing.
          if (d.view !== "replay") d.view = "replay";
          renderAll(d);
        }
      })
      .catch(function () { /* keep snapshot */ });
  }

  function stopLivePoll() {
    if (mode.pollTimer) {
      clearTimeout(mode.pollTimer);
      mode.pollTimer = null;
    }
  }

  function pollLive() {
    fetch(liveUrl, { cache: "no-store" })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (d) {
        if (!d) return;
        // Auto-offer scrubber when the live projection is terminal.
        if (mode.replay) return;
        renderAll(d);
      })
      .catch(function () { /* file:// or server down: keep the build snapshot */ })
      .then(function () {
        if (!mode.replay) mode.pollTimer = setTimeout(pollLive, POLL_MS);
      });
  }

  function startLivePoll() {
    stopLivePoll();
    mode.replay = false;
    pollLive();
  }

  // Boot
  setInterval(tickElapsed, 1000);
  if (mode.replay || mode.dispatchId) {
    mode.replay = true;
    loadReplay(mode.dispatchId, mode.asOfSeq);
  } else {
    startLivePoll();
  }
})();
