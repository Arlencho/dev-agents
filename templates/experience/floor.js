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

  /* Does the elapsed ticker run? Only while the stream itself is live. It
     starts false so the build snapshot never counts up before a fetch has
     confirmed anything, and it goes false again on stale, offline, replay or
     a failed fetch: the seat then keeps the last value the projection
     reported, the way the lanes already do. */
  var elapsedLive = false;

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

  /* Plain-words durations for sentences: minutes, never "12m05s". */
  function fmtMin(secs) {
    if (typeof secs !== "number" || !isFinite(secs) || secs < 0) return "-";
    var s = Math.floor(secs);
    if (s < 60) return "under a minute";
    if (s < 3600) return Math.round(s / 60) + " min";
    var h = Math.floor(s / 3600);
    var m = Math.round((s % 3600) / 60);
    return m ? h + " h " + m + " min" : h + " h";
  }

  /* Ages floor, never round: at 101 s the top line must still read "1 min
     ago", because the LED and the state note flip at "over 2 min". A rounded
     "2 min ago" under a live LED is two clocks disagreeing. */
  function fmtAgo(secs) {
    if (typeof secs !== "number" || !isFinite(secs) || secs < 0) return "-";
    var s = Math.floor(secs);
    if (s < 60) return s + " s ago";
    if (s < 3600) return Math.floor(s / 60) + " min ago";
    return Math.floor(s / 3600) + " h ago";
  }

  /* Seconds between two ISO timestamps, or null when either side is missing
     or unparsable: the degraded sentence speaks only in timestamps the
     projection carries, and drops a clause rather than printing a guess. */
  function secsBetween(laterTs, earlierTs) {
    var a = new Date(laterTs || "").getTime();
    var b = new Date(earlierTs || "").getTime();
    if (isNaN(a) || isNaN(b)) return null;
    return Math.max(0, Math.round((a - b) / 1000));
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

  /* Top line in plain words, from the summary object: how many running, how
     many up next, how many landed today, when the last event arrived. The age
     is the liveState age (computed in the browser from last_event_ts), the
     same clock the rest of the chrome reads, so this line can never disagree
     with the state note. Off a live stream the line says so in place and the
     running count is qualified as of the last event. A replay carries no
     summary, so the line goes away instead of guessing. */
  function renderSummary(d, st) {
    var el = $("floor-summary");
    if (!el) return;
    var s = d.summary;
    var parts = [];
    if (s && typeof s === "object") {
      var degraded = st && (st.state === "stale" || st.state === "offline");
      if (typeof s.running === "number") {
        parts.push(s.running + " running" + (degraded ? " at last event" : ""));
      }
      if (typeof s.queued === "number") parts.push(s.queued + " up next");
      if (typeof s.landed_today === "number") parts.push(s.landed_today + " landed today");
      if (st && typeof st.age === "number") parts.push("last event " + fmtAgo(st.age));
      if (degraded) parts.push("stream " + st.state);
    }
    if (!parts.length) {
      el.hidden = true;
      el.textContent = "";
      return;
    }
    el.hidden = false;
    el.textContent = parts.join(" · ");
  }

  /* The LED states explained in place, one short sentence for the state that
     applies right now. Replay needs none: its watermark already says what it
     is, and that copy is not touched here. */
  function renderStateNote(d, st) {
    var el = $("floor-state-note");
    if (!el) return;
    var stale = (d.staleness && d.staleness.stale_after_s) || 120;
    var offline = (d.staleness && d.staleness.offline_after_s) || 900;
    var txt = "";
    if (st.state === "live") {
      txt = "Live: events are arriving, so this page shows what is happening now.";
    } else if (st.state === "stale") {
      txt = "Stale: no new event for over " + fmtMin(stale) +
        ", so the page shows the last known state and the clocks stay frozen.";
    } else if (st.state === "offline") {
      txt = "Offline: no new event for over " + fmtMin(offline) +
        ", so everything below is history, not the present.";
    }
    if (!txt) {
      el.hidden = true;
      el.textContent = "";
      return;
    }
    el.hidden = false;
    el.textContent = txt;
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

  /* One line of live activity under a seat: phase pill, tool, repo-relative
     path, then the counts the stream reported. Projection facts only: the
     stream carries no prompt, no argument and no command line, so there is
     nothing here to leak. Absent activity renders nothing at all. */
  var PHASES = { reading: 1, reviewing: 1, editing: 1, testing: 1, committing: 1 };

  function activityLine(seat) {
    var a = seat.activity;
    if (!a) return "";
    var phase = PHASES[a.phase] ? a.phase : "in flight";
    var what = [];
    if (a.tool) what.push(esc(a.tool));
    if (a.path) what.push('<span class="mono">' + esc(a.path) + "</span>");
    var counts = [
      (a.files_edited || 0) + " edited",
      (a.commands_run || 0) + " cmd",
      (a.tests_run || 0) + " test",
      (a.commits_made || 0) + " commit",
    ].join(" · ");
    return '<div class="nowact"><span class="st st-run">' + esc(phase) + "</span>" +
      '<span class="faint">' + (what.join(" ") || "no tool reported yet") + "</span>" +
      '<span class="mono faint">' + esc(counts) + "</span></div>";
  }

  /* The now view: one running seat reads as the purpose on its own line,
     then one short status clause of nouns, built from the seats[].now object
     the projection folds for exactly this. Every field is independently
     nullable, so a missing fact drops its clause instead of printing a guess.
     Ids and schema words (branch, attempt) are demoted to a dim secondary
     line. The elapsed clock is the clause itself: it ticks in plain minutes
     while the stream is live and freezes with the rest of the page off it,
     so one fact never wears two clocks. The quiet badge keeps its rule:
     quiet wears violet. */
  function nowPurpose(now) {
    var purpose = String(now.purpose || "").replace(/[.\s]+$/, "");
    return purpose ? '<div class="nowpurpose">' + esc(purpose) + ".</div>" : "";
  }

  /* Issue and milestone the plan serves (issue 72): the number always comes
     from the plan header line; the milestone title only from a verified gh
     lookup. A skipped lookup says so in place instead of implying there is
     no milestone. */
  function issueLine(issue) {
    if (!issue || typeof issue.number !== "number") return "";
    var txt = "#" + issue.number;
    if (issue.milestone) txt += " · " + esc(issue.milestone);
    if (issue.lookup === "skipped") txt += ' <span class="faint">(milestone unverified)</span>';
    return '<div class="nowissue">' + txt + "</div>";
  }

  /* The open (else merged) PR for the seat branch: number and title only,
     and only when gh answered with one. Nothing renders otherwise. */
  function prLine(pr) {
    if (!pr || typeof pr.number !== "number") return "";
    var txt = "PR #" + pr.number;
    if (pr.title) txt += " · " + esc(pr.title);
    return '<div class="nowpr">' + txt + "</div>";
  }

  /* Repo group header counts (issue 72): "seats live, dispatches live" per
     repo. Off a live stream the word "live" is a claim the projection cannot
     back, so it is qualified; a replay drops the word entirely (the seats
     shown are history at the scrubber position). */
  function repoHeadCounts(nSeats, nDisp, st) {
    var seatWord = nSeats === 1 ? "seat" : "seats";
    var dispWord = nDisp === 1 ? "dispatch" : "dispatches";
    if (st && st.state === "replay") return nSeats + " " + seatWord + " · " + nDisp + " " + dispWord;
    var qual = (st && (st.state === "stale" || st.state === "offline")) ? " at last event" : "";
    return nSeats + " " + seatWord + " live" + qual + " · " + nDisp + " " + dispWord + " live" + qual;
  }

  /* Status clause: role, phase with its program, wave, elapsed, heartbeat.
     Off a live stream the clause degrades with the page: the phase goes past
     tense, and both clocks stop at the last event. The numbers then come from
     the timestamps the projection carries (elapsed = last_event_ts minus
     started_at, heartbeat = last_event_ts minus last_heartbeat_ts), never
     from the projection's own run time: a seat's elapsed at the last event
     cannot depend on when the projection ran. A missing timestamp drops its
     clause. */
  function nowStatus(now, st, seat, lastEventTs) {
    var degraded = st && (st.state === "stale" || st.state === "offline");
    var parts = ["<strong>" + esc(now.role || "this seat") + "</strong>"];
    if (now.phase) {
      var phase = esc(now.phase) + (now.program ? " with " + esc(now.program) : "");
      parts.push(degraded ? "was " + phase : phase);
    } else {
      parts.push(degraded ? "was at work" : "at work");
    }
    if (typeof now.wave === "number") {
      parts.push("wave " + now.wave +
        (typeof now.wave_total === "number" ? " of " + now.wave_total : ""));
    }
    if (degraded) {
      var elapsedAt = secsBetween(lastEventTs, seat.started_at);
      if (elapsedAt != null) {
        parts.push(fmtMin(elapsedAt) + " in at the last event");
      }
      var heartbeatAt = secsBetween(lastEventTs, seat.last_heartbeat_ts);
      if (heartbeatAt != null) {
        parts.push("last heartbeat " + fmtAgo(heartbeatAt).replace(/ ago$/, "") +
          " before the last event");
      }
    } else {
      if (typeof now.elapsed_s === "number") {
        parts.push('running <span data-elapsed-from="' + esc(seat.started_at || "") +
          '" data-elapsed-min="1">' + fmtMin(now.elapsed_s) + "</span>");
      }
      if (typeof now.heartbeat_age_s === "number") {
        parts.push("heartbeat " + fmtAgo(now.heartbeat_age_s));
      }
    }
    return parts.join(", ") + ".";
  }

  function nowRow(seat, st, lastEventTs) {
    var quiet = seat.quiet === true;
    var quietBadge = quiet
      ? '<span class="wm-badge" title="no sign of life since the quiet threshold">quiet</span>' : "";
    /* Seat card order (issue 72): repo; issue and milestone (unverified mark
       when the lookup was skipped); purpose; seat task line; status clause;
       branch dim; PR number and title when one exists. */
    if (seat.now && typeof seat.now === "object") {
      return '<li class="nowrow' + (quiet ? " quiet" : "") + '">' +
        '<div class="nowhead"><span class="rname">' + esc(seat.repo || "repo not reported") + "</span>" +
        seatPill(seat) + quietBadge + "</div>" +
        issueLine(seat.issue) +
        nowPurpose(seat.now) +
        (seat.task_line ? '<div class="nowtask">' + esc(seat.task_line) + "</div>" : "") +
        '<div class="nowsent">' + nowStatus(seat.now, st, seat, lastEventTs) + "</div>" +
        '<div class="nowmeta"><span class="mono faint">' + esc(seat.branch || "branch not reported") + "</span>" +
        '<span class="faint">attempt ' + esc(seat.attempt || 1) + "</span></div>" +
        prLine(seat.pr) + "</li>";
    }
    /* Older projection or replay: seats[].now is null, so fall back to the
       plan-header layout rather than inventing a present-tense sentence. The
       repo, issue, task line and PR still ride the card when the projection
       carries them. */
    var timer = '<span class="timer mono" data-elapsed-from="' + esc(seat.started_at || "") + '">' +
      fmtDur(seat.elapsed_s) + "</span>";
    var wave = (typeof seat.wave === "number")
      ? ("wave " + seat.wave + (seat.wave_total ? " of " + seat.wave_total : ""))
      : "wave not reported";
    var beat = seat.last_heartbeat_ts
      ? "last heartbeat " + timeOf(seat.last_heartbeat_ts) +
        (typeof seat.heartbeat_age_s === "number" ? " (" + fmtDur(seat.heartbeat_age_s) + " ago)" : "")
      : "no heartbeat yet";
    return '<li class="nowrow' + (quiet ? " quiet" : "") + '">' +
      '<div class="nowhead"><span class="rname">' + esc(seat.repo || "repo not reported") + "</span>" +
      '<span class="role">' + esc(seat.agent || seat.task_id) + "</span>" +
      seatPill(seat) + quietBadge + timer + "</div>" +
      issueLine(seat.issue) +
      '<div class="nowpurpose">' + esc(seat.plan_purpose || "purpose not declared in the plan header") + "</div>" +
      '<div class="nowtask">' + esc(seat.task_line || seat.task || "task line not resolvable from the plan on this machine") + "</div>" +
      activityLine(seat) +
      '<div class="nowmeta"><span class="vendor">' + esc(wave) + "</span>" +
      '<span class="vendor">attempt ' + esc(seat.attempt || 1) + "</span>" +
      '<span class="mono faint">' + esc(seat.branch || "branch not reported") + "</span>" +
      '<span class="faint">' + esc(beat) + "</span></div>" +
      prLine(seat.pr) + "</li>";
  }

  function renderNow(d, st) {
    var box = $("floor-now-list");
    if (!box) return;
    var live = (d.seats || []).filter(function (s) { return s.status === "running"; });
    var note = $("floor-now-note");
    if (note) {
      var runs = {};
      live.forEach(function (s) { if (s.dispatch_id) runs[s.dispatch_id] = 1; });
      var n = Object.keys(runs).length;
      /* "Live" is a liveness claim like any other on this page: off a live
         stream it is qualified with "at last event", same as Landed today. */
      var degraded = st && (st.state === "stale" || st.state === "offline");
      note.textContent = live.length
        ? live.length + (live.length === 1 ? " seat live" : " seats live") +
          (degraded ? " at last event" : "") +
          " across " + (n || 1) + ((n || 1) === 1 ? " dispatch" : " dispatches")
        : "no seat is live";
    }
    if (!live.length) {
      box.innerHTML = '<li class="muted">No seat is live. The Floor shows motion only while a dispatch is running.</li>';
      tickElapsed();
      return;
    }
    /* Group by repo (issue 72): with two repos live at once a seat must sit
       under its repo's header, which carries the per-repo counts from
       repos[]. A replay carries no repos[], so the counts then come from the
       seats shown at the scrubber position. */
    var reposMeta = {};
    (d.repos || []).forEach(function (r) {
      if (r && r.repo) reposMeta[r.repo] = r;
    });
    var groups = {};
    live.forEach(function (s) {
      var repo = s.repo || "unknown";
      (groups[repo] = groups[repo] || []).push(s);
    });
    var order = Object.keys(groups).sort(function (a, b) {
      var ma = reposMeta[a], mb = reposMeta[b];
      var ca = ma && typeof ma.seats_live === "number" ? ma.seats_live : groups[a].length;
      var cb = mb && typeof mb.seats_live === "number" ? mb.seats_live : groups[b].length;
      return cb - ca || (a < b ? -1 : a > b ? 1 : 0);
    });
    var html = "";
    order.forEach(function (repo) {
      var gseats = groups[repo];
      var meta = reposMeta[repo] || {};
      var nSeats = typeof meta.seats_live === "number" ? meta.seats_live : gseats.length;
      var nDisp = typeof meta.dispatches_live === "number" ? meta.dispatches_live
        : (function () {
            var ids = {};
            gseats.forEach(function (s) { if (s.dispatch_id) ids[s.dispatch_id] = 1; });
            return Object.keys(ids).length || 1;
          })();
      html += '<li class="repohead"><span class="rname">' + esc(repo) + "</span>" +
        '<span class="faint">' + esc(repoHeadCounts(nSeats, nDisp, st)) + "</span></li>";
      html += gseats.map(function (s) { return nowRow(s, st, d.last_event_ts); }).join("");
    });
    box.innerHTML = html;
    tickElapsed();
  }

  /* One ticker for the page: elapsed counts up every second from the timestamp
     the stream recorded, so a live seat never looks frozen between polls.
     Off a live stream it does not run at all: a clock still climbing while the
     LED says offline is a liveness claim the projection cannot back. Spans
     marked data-elapsed-min tick in plain minutes (the seat status clause),
     the rest in the compact timer format. */
  function tickElapsed() {
    if (!elapsedLive) return;
    var nodes = document.querySelectorAll("[data-elapsed-from]");
    for (var i = 0; i < nodes.length; i++) {
      var from = new Date(nodes[i].getAttribute("data-elapsed-from") || "").getTime();
      if (isNaN(from)) continue;
      var secs = Math.max(0, Math.round((Date.now() - from) / 1000));
      nodes[i].textContent = nodes[i].getAttribute("data-elapsed-min") ? fmtMin(secs) : fmtDur(secs);
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
      /* Repo is the first word; the issue number follows when the plan
         header names one (issue 72). */
      var issue = q.issue && typeof q.issue.number === "number"
        ? ' <span class="mono">#' + q.issue.number + "</span>" : "";
      return '<li class="qrow">' +
        '<span class="qpos mono">' + esc(q.position) + "</span>" +
        '<span class="qbody"><span class="qpurpose"><span class="rname">' +
        esc(q.repo || "repo not declared") + "</span>" + issue + " " +
        esc(q.purpose || "no purpose declared") + "</span>" +
        '<span class="qmeta"><span class="mono faint">' + esc(q.plan_basename || q.plan || "") + "</span></span></span>" +
        '<span class="st st-unk">queued</span></li>';
    }).join("");
  }

  /* Landed today: every dispatch whose dispatch_end fell on this local day.
     The "still live" count is a liveness claim like any other on this page, so
     off a live stream it is qualified with "at last event" instead of being
     asserted in the present tense. State comes from renderAll. */
  function renderToday(d, st) {
    var box = $("floor-today-list");
    if (!box) return;
    var items = d.today || [];
    var meta = d.today_meta || {};
    /* The note is a variable length, data driven string, so it lives in the
       muted paragraph UNDER the head (same as #floor-queue-note), never in the
       .cardhead .more slot: that slot is white-space: nowrap and a live day
       pushed the whole page sideways at 400px. */
    var note = $("floor-today-note");
    if (note) {
      var state = (st && st.state) || liveState(d).state;
      var liveN = (meta.live || []).length;
      var liveTxt = !liveN ? ""
        : state === "live" ? " · " + liveN + " still live"
        : " · " + liveN + " still live at last event";
      note.textContent = "dispatch_end on " + (meta.date || "today") +
        " · " + (meta.streams_read || 0) + " stream(s) read" + liveTxt;
    }
    if (!items.length) {
      box.innerHTML = '<li class="muted">Nothing has landed today yet.</li>';
      return;
    }
    box.innerHTML = items.map(function (t) {
      /* Outcome in words from the projection's today[].outcome (landed,
         failed, aborted), which reads the seat exits; status alone cannot
         tell a failed run from an operator stop. Older projections without
         outcome fall back to the status map. Failed and aborted wear
         different pills so a scan of the column tells them apart. */
      var word = t.outcome ||
        (t.status === "settled" ? "landed"
        : t.status === "failed" ? "failed"
        : t.status === "aborted" ? "aborted" : (t.status || "unknown"));
      var cls = word === "landed" ? "st st-done"
        : word === "failed" ? "st st-fail"
        : word === "aborted" ? "st st-warn" : "st st-unk";
      var branches = (t.branches || []).map(function (b) {
        return '<span class="mono faint">' + esc(b) + "</span>";
      }).join(" ");
      /* Repo is the first word; the PR number follows when one exists for
         the landing's branch (issue 72). */
      var pr = t.pr && typeof t.pr.number === "number"
        ? ' <span class="mono">PR #' + t.pr.number + "</span>" : "";
      return '<li class="trow">' +
        '<span class="tbody"><span class="tpurpose"><span class="rname">' +
        esc(t.repo || "repo not reported") + "</span>" + pr + " " +
        esc(t.purpose || t.plan_basename || t.dispatch_id) + "</span>" +
        '<span class="tmeta">' +
        (branches || '<span class="faint">no branch reported</span>') + "</span></span>" +
        '<span class="' + cls + ' tout">' + esc(word) + "</span>" +
        '<span class="timer mono">' + fmtMin(t.duration_s) + "</span></li>";
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
    elapsedLive = st.state === "live";
    renderSummary(d, st);
    renderWatermark(st, d);
    renderAmbient(d, st);
    renderStateNote(d, st);
    renderWaiting(d);
    renderCounts(d);
    renderNow(d, st);
    renderQueue(d);
    renderToday(d, st);
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
      .catch(function () { elapsedLive = false; /* keep snapshot, frozen */ });
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
        if (!d) { elapsedLive = false; return; }
        // Auto-offer scrubber when the live projection is terminal.
        if (mode.replay) return;
        renderAll(d);
      })
      .catch(function () {
        // file:// or server down: keep the build snapshot, and stop the clock.
        elapsedLive = false;
      })
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
