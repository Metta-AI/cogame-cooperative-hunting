// Worst-case renderer driver. Runs INSIDE each sized frame, alongside the
// real client/replay_broadcast.html.
//
// checklist item 15: "a page that loads the real renderer, hands it a frame
// built to hurt (a full-cap remark on every seat at once ...), renders it at
// several canvas sizes, sets data-replay-loaded, and is driven by
// viewer_smoke.mjs --strict-text-bounds ... The fixture asserts its own
// strings are still full-length."
//
// The model text this viewer draws is DOM text (`#feed` .feed-row), not
// canvas text, so `canvas_text` cannot see it -- the equivalent gate is
// measured here and reported to the harness, which turns a failure into
// `data-replay-error` and so into a red viewer_smoke run.
(function () {
  'use strict';

  var TOL = 1;
  var SETTLE_MS = 600;    // .feed-row's `feedin` entrance animation is 250 ms

  var failures = [];
  var rows = [];
  var notes = {};

  function byId(id) { return document.getElementById(id); }
  function box(el) { return el.getBoundingClientRect(); }
  function runes(text) { return Array.from(text).length; }

  function outsideOf(inner, outer) {
    var edges = [];
    if (inner.left < outer.left - TOL) edges.push('left');
    if (inner.right > outer.right + TOL) edges.push('right');
    if (inner.top < outer.top - TOL) edges.push('top');
    if (inner.bottom > outer.bottom + TOL) edges.push('bottom');
    return edges;
  }

  function overlaps(a, b) {
    return a.left < b.right - TOL && a.right > b.left + TOL &&
      a.top < b.bottom - TOL && a.bottom > b.top + TOL;
  }

  function label(size, index) { return size + ' feed row ' + index; }

  function measureFeed(size, expected) {
    var stage = box(byId('stage'));
    var scorebug = box(byId('scorebug'));
    var transport = box(byId('transport'));
    var els = Array.prototype.slice.call(
      document.querySelectorAll('#feed .feed-row'));
    if (els.length !== expected.length) {
      failures.push(size + ': the feed rendered ' + els.length +
        ' rows for ' + expected.length + ' worst-case lines');
    }
    els.forEach(function (el, index) {
      var want = expected[index];
      var got = el.textContent;
      var rect = box(el);
      var style = window.getComputedStyle(el);
      // (1) the string is still full-length -- a quietly shortened remark
      // would leave every other assertion passing while testing nothing.
      if (got !== want) {
        failures.push(label(size, index) + ' is not the full-length string: ' +
          runes(got) + ' runes rendered for ' + runes(want) + ' handed in');
      }
      if (got.indexOf('\u2026') >= 0 && want.indexOf('\u2026') < 0) {
        failures.push(label(size, index) + ' was ellipsized: a remark is a ' +
          'sentence, not a nameplate');
      }
      // (2) nothing is cut off inside the row's own box.
      if (el.scrollWidth > el.clientWidth + TOL) {
        failures.push(label(size, index) + ' overflows its own box ' +
          'horizontally: scrollWidth ' + el.scrollWidth + ' > clientWidth ' +
          el.clientWidth);
      }
      if (el.scrollHeight > el.clientHeight + TOL) {
        failures.push(label(size, index) + ' overflows its own box ' +
          'vertically: scrollHeight ' + el.scrollHeight + ' > clientHeight ' +
          el.clientHeight);
      }
      // (3) the row is inside the frame -- the DOM equivalent of a canvas
      // draw at a negative coordinate (cogchemists, 2026-08-24).
      var off = outsideOf(rect, stage);
      if (off.length) {
        failures.push(label(size, index) + ' is drawn outside the frame (' +
          off.join('+') + '): [' + Math.round(rect.left) + ',' +
          Math.round(rect.top) + ',' + Math.round(rect.right) + ',' +
          Math.round(rect.bottom) + '] in [' + Math.round(stage.left) + ',' +
          Math.round(stage.top) + ',' + Math.round(stage.right) + ',' +
          Math.round(stage.bottom) + ']');
      }
      // (4) it is not sitting on top of the two reserved bands.
      if (overlaps(rect, scorebug)) {
        failures.push(label(size, index) + ' overlaps the scorebug band');
      }
      if (overlaps(rect, transport)) {
        failures.push(label(size, index) + ' overlaps the transport band');
      }
      // (5) it is actually painted.
      if (style.visibility !== 'visible' || style.display === 'none' ||
          parseFloat(style.opacity) < 0.99) {
        failures.push(label(size, index) + ' is not visible after the ' +
          'entrance animation settled: display=' + style.display +
          ' visibility=' + style.visibility + ' opacity=' + style.opacity);
      }
      rows.push({
        row: index,
        runes: runes(got),
        width: Math.round(rect.width),
        height: Math.round(rect.height),
        font_size: style.fontSize,
        wrapped_lines: Math.max(1, Math.round(rect.height /
          Math.max(1, parseFloat(style.fontSize))))
      });
    });
  }

  function measureEndcard(size) {
    var stage = box(byId('stage'));
    var transport = box(byId('transport'));
    var card = byId('endcard');
    if (!card.classList.contains('on')) {
      failures.push(size + ': the end-card never opened on a final frame');
      return;
    }
    var rect = box(card);
    var off = outsideOf(rect, stage);
    if (off.length) {
      failures.push(size + ': the end-card is outside the frame (' +
        off.join('+') + ')');
    }
    if (overlaps(rect, transport)) {
      failures.push(size + ': the end-card covers the transport band, so the ' +
        'scrubber cannot pull the match back');
    }
    var standings = Array.prototype.slice.call(
      document.querySelectorAll('#ec-standings .row'));
    notes.endcard_rows = standings.length;
    standings.forEach(function (el, index) {
      var edges = outsideOf(box(el), stage);
      if (edges.length) {
        failures.push(size + ': end-card standings row ' + index +
          ' is outside the frame (' + edges.join('+') + ')');
      }
    });
  }

  function settle() {
    return new Promise(function (resolve) {
      setTimeout(function () {
        requestAnimationFrame(function () {
          requestAnimationFrame(resolve);
        });
      }, SETTLE_MS);
    });
  }

  function report(ok) {
    window.__fixtureReport = {
      ok: ok && failures.length === 0,
      size: window.innerWidth + 'x' + window.innerHeight,
      failures: failures,
      rows: rows,
      notes: notes
    };
  }

  var params = new URLSearchParams(window.location.search);
  var stateUrl = params.get('state');
  var size = window.innerWidth + 'x' + window.innerHeight;

  fetch(stateUrl, { credentials: 'omit' })
    .then(function (response) { return response.json(); })
    .then(function (state) {
      var hooks = window.__fixtureHooks;
      if (!hooks || typeof hooks.onText !== 'function') {
        throw new Error('the page never called createCore');
      }
      var expected = state.feed.slice(-6).map(function (line) {
        return line.text;
      });
      notes.state_bytes = new TextEncoder().encode(JSON.stringify(state)).length;
      notes.beats = state.beats.length;
      notes.seats = state.seats.length;
      // Pass 1: the live worst case -- every seat speaking at its cap on the
      // same tick, no end-card over the top.
      var live = JSON.parse(JSON.stringify(state));
      live.final = null;
      live.reason = null;
      hooks.onLoaded(state.rounds * state.ticksPerRound);
      hooks.onTick(state.tick, state.rounds * state.ticksPerRound);
      hooks.onText(JSON.stringify(live));
      return settle().then(function () {
        measureFeed(size, expected);
        // Pass 2: the same frame with the episode over, so the end-card and
        // its full-cap standings are measured too. `feed` is empty because
        // the label only ever carries lines new since the previous frame.
        var ended = JSON.parse(JSON.stringify(state));
        ended.feed = [];
        hooks.onText(JSON.stringify(ended));
        return settle();
      }).then(function () {
        measureEndcard(size);
        report(true);
      });
    })
    .catch(function (error) {
      failures.push(size + ': driver error: ' + (error && error.message));
      report(false);
    });
})();
