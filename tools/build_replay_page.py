#!/usr/bin/env python3
"""Assemble client/replay_broadcast.html.

The page is `Metta-AI/coworld-ctf`'s (paintbot's) `client/replay_broadcast.html`
with a Cooperative Hunting game block APPENDED -- not a rewrite that reuses
its ids (cogame-gridlock, 2026-08-23). The starter's <head>, CSS variables,
transport markup, endcard skeleton and relayout()/bridge scaffolding stay as
they are; only the ctf-specific elements the design note lists as removed are
deleted, and only the game half is new.

This script exists so the provenance is reproducible and reviewable: run it
against a coworld-ctf checkout and diff the result against the committed page.

  python3 tools/build_replay_page.py /path/to/coworld-ctf > client/replay_broadcast.html
"""
import re
import sys

STARTER_DEFAULT = "/workspace/starters/coworld-ctf"

# Starter elements the design note removes: the first-person picture-in-
# picture, the locker-room curtain, the kill feed (replaced by #feed), the POV
# badge, the mismatch warning, and -- per the zoom decision -- the whole view
# panel. The arena is a fixed 32x32 tile board that is always drawn in full,
# so a zoom bar and a minimap have no job.
REMOVED_SELECTOR_TOKENS = [
    "#fpv", ".fpv-",
    "#lockerroom", "#lk-", ".lk-",
    "#killfeed", ".kf-",
    "#povBadge", "#mmwarn",
    "#viewpanel", "#zoombar", "#zoom-", ".zbtn", "#minimap", ".mm-",
]


def split_rules(text):
    out = []
    depth = 0
    start = 0
    sel_start = 0
    for i, c in enumerate(text):
        if c == "{":
            if depth == 0:
                sel_start = start
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                out.append(text[sel_start:i + 1])
                start = i + 1
    if start < len(text):
        out.append(text[start:])
    return out


def selector_of(rule):
    idx = rule.find("{")
    return rule[:idx] if idx >= 0 else rule


def dropped(selector):
    bare = re.sub(r"/\*.*?\*/", "", selector, flags=re.S)
    return any(token in bare for token in REMOVED_SELECTOR_TOKENS)


def filter_css(text):
    kept = []
    for rule in split_rules(text):
        selector = selector_of(rule)
        head = selector.lstrip()
        if head.startswith("@media") or head.startswith("@supports"):
            open_i = rule.find("{")
            inner = filter_css(rule[open_i + 1:rule.rfind("}")])
            if inner.strip():
                kept.append(rule[:open_i + 1] + inner + "\n}")
            continue
        if head.startswith("@"):
            kept.append(rule)
            continue
        if "{" in rule and dropped(selector):
            continue
        kept.append(rule)
    return "".join(kept)


GAME_CSS = """
/* ============================================================
   cooperative-hunting additions to the inherited coworld-ctf chrome.
   Everything above this block is the starter's CSS, kept verbatim except
   for the rules belonging to the elements the design note removes (#fpv,
   #lockerroom, #killfeed, #povBadge, #mmwarn and the whole #viewpanel zoom
   bar + minimap). Everything below is this game's: the six hunter plates,
   the round clock, the feed, the scrubber beats and the grass toggle.
   ============================================================ */

#feed {
  position: absolute;
  right: calc(8 * var(--u));
  bottom: calc(var(--band, 0px) + 6 * var(--u));
  z-index: 6;
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: calc(2 * var(--u));
  pointer-events: none;
  max-width: min(64%, calc(320 * var(--u)));
}
/* A `say` line is a MODEL sentence at the server's 120-rune cap
   (MaxSayRunes), not the starter's ten-character kill-feed line, and 120
   runes of CJK are three times the width of 120 runes of latin. The
   starter's `white-space: nowrap; max-width: none` sends such a row off the
   LEFT edge of the frame (the rows are right-anchored), which is
   cogchemists' negative-coordinate bubble in DOM form: drawn, unclipped by
   any box, and invisible. Wrap inside the feed's reserved width instead --
   the band is sized from the cap the server enforces, not by eye. Gated by
   tools/ci/fixtures/worst_case_harness.html in ci.yml. */
#feed .feed-row {
  pointer-events: none;
  white-space: normal;
  overflow-wrap: anywhere;
  max-width: 100%;
  text-align: right;
}
#feed .feed-row.say { color: var(--paper); font-style: italic; }
#feed .feed-row.hurt { color: var(--red); }
#feed .feed-row.tag { color: var(--amber); }
#feed .feed-row.round { color: var(--paper-dim); letter-spacing: calc(1 * var(--u)); }
#feed .feed-row.fallback { color: var(--ghost); }

/* Six hunter plates in slot order, three each side of the clock. The
   starter stacks its two team plates in a column; six hunters would make
   that band 400 px tall and swallow the board, so ours run in a row and
   wrap only when the frame is too narrow to hold three. */
#scorebug .plates { flex-direction: row; flex-wrap: wrap; align-items: stretch; gap: calc(4 * var(--u)); padding: 0 calc(3 * var(--u)); overflow: hidden; }

/* Six hunter plates in slot order: colour chip, alias, the REAL policy
   name, score in big digits, an energy bar 0-200 and a role/level badge. */
.hplate {
  display: flex;
  align-items: center;
  gap: calc(4 * var(--u));
  background: var(--ink-soft);
  padding: calc(2 * var(--u)) calc(5 * var(--u));
  font-family: var(--pixfont);
  font-size: calc(9 * var(--u));
  line-height: 1.1;
  /* NOT `min-width: 0`: that let three plates share a 640 px half by
     shrinking BELOW the width their own furniture needs, and
     `#scorebug .plates { overflow: hidden }` then sliced the overflow off --
     at 1280 px every plate ran 259 px of content in a 153 px box and the
     last seat's score was cut by the frame edge (viewer-smoke.png, run
     32774674232). The floor is the room the chip, the alias, the name at
     its own 3.2em floor, the score, the energy bar and the badge actually
     take; a plate that cannot have it WRAPS onto a second line instead (the
     band grows and relayout reports the new --topband). So the score is
     always whole and only the name ellipsizes, which is what a label is
     allowed to do. Gated per plate by
     tools/ci/fixtures/fixture_chrome_driver.js. */
  min-width: calc(210 * var(--u));
  flex: 1 1 calc(210 * var(--u));
}
.hplate.dc { opacity: .42; filter: grayscale(1); }
.hplate .chip {
  width: calc(9 * var(--u));
  height: calc(9 * var(--u));
  flex: 0 0 auto;
  border-radius: 50%;
}
.plate-alias { color: var(--paper-dim); flex: 0 0 auto; }
/* Player names must never collapse to an ellipsis in the ~360 px featured
   match iframe: give the name the flex growth and a floor of its own. */
.plate-name { flex: 1 1 auto; min-width: 3.2em; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.plate-score {
  font-weight: 700;
  font-size: calc(13 * var(--u));
  font-variant-numeric: tabular-nums;
  flex: 0 0 auto;
  margin-left: auto;
  color: var(--paper);
}
.plate-energy {
  position: relative;
  height: calc(5 * var(--u));
  width: calc(34 * var(--u));
  flex: 0 0 auto;
  background: #2a1a12;
  border: calc(1 * var(--u)) solid #4a2e21;
}
.plate-energy i { position: absolute; inset: 0 auto 0 0; display: block; background: var(--green); }
.plate-badge {
  flex: 0 0 auto;
  font-size: calc(7.5 * var(--u));
  letter-spacing: calc(0.6 * var(--u));
  color: var(--amber);
  border: calc(1 * var(--u)) solid currentColor;
  padding: 0 calc(3 * var(--u));
}

#gamechips {
  position: absolute;
  left: calc(8 * var(--u));
  bottom: calc(var(--band, 0px) + 6 * var(--u));
  z-index: 7;
  display: flex;
  gap: calc(4 * var(--u));
}
#gamechips button {
  font-family: var(--pixfont);
  font-size: calc(8.5 * var(--u));
  letter-spacing: calc(0.6 * var(--u));
  color: var(--paper-dim);
  background: var(--ink-soft);
  border: calc(1 * var(--u)) solid #4a2e21;
  padding: calc(2 * var(--u)) calc(6 * var(--u));
  cursor: pointer;
}
#gamechips button.on { color: var(--amber); border-color: var(--amber); }
#gamechips[hidden] { display: none; }

/* Scrubber beats: clickable, LABELLED buttons that seek to their tick. Every
   kind the game emits has a rule here and no other kind is ever emitted --
   round, bigcatch, smallcatch, tag, end. */
.beat-marker {
  position: absolute;
  top: 0;
  bottom: 0;
  width: calc(3 * var(--u));
  margin-left: calc(-1.5 * var(--u));
  padding: 0;
  border: 0;
  background: var(--paper-dim);
  cursor: pointer;
  z-index: 4;
  overflow: hidden;
  text-indent: -999em;
}
.beat-marker:hover, .beat-marker:focus-visible { outline: calc(1 * var(--u)) solid var(--paper); }
.beat-marker.round { background: var(--paper-dim); }
.beat-marker.bigcatch { background: var(--amber); width: calc(4 * var(--u)); }
.beat-marker.smallcatch { background: var(--green); }
.beat-marker.tag { background: var(--red); }
.beat-marker.end { background: var(--paper); width: calc(4 * var(--u)); }
.beat-marker.ahead { opacity: .28; }

/* The endcard stops ABOVE the transport band and every seek dismisses it. */
#endcard { bottom: var(--band, 0px); }
#ec-standings { margin-top: calc(6 * var(--u)); width: min(96%, calc(460 * var(--u))); }
#ec-standings .row {
  display: flex;
  align-items: baseline;
  gap: calc(6 * var(--u));
  font-family: var(--pixfont);
  font-size: calc(10 * var(--u));
  padding: calc(2 * var(--u)) 0;
  border-bottom: calc(1 * var(--u)) solid #3a2a1e;
}
#ec-standings .row .rank { color: var(--paper-dim); flex: 0 0 calc(16 * var(--u)); }
#ec-standings .row .score { margin-left: auto; font-variant-numeric: tabular-nums; font-weight: 700; }

@media (max-width: 640px) {
  /* At the ~360 px featured-match width the scorebug, the clock and the feed
     are what must stay legible, so everything decorative gives way first. */
  #speedchips .chip-label, .tbtn .label { display: none !important; }
  /* The scorebug's local --u is what every measure in the band derives from
     (the starter's own knob), so ONE px floor keeps six plates legible in
     the ~360 px featured-match iframe instead of shrinking to 3.6 px type. */
  #scorebug {
    --u: max(0.95px, calc(1px * var(--hudscale) * 0.8));
    /* Restack: the clock on its own row, then all six plates across the full
       width. The starter's three-track grid leaves each side ~110 px at this
       size, which is where a policy name collapses to an ellipsis. */
    grid-template-columns: 1fr;
    gap: calc(3 * var(--u));
    padding: calc(4 * var(--u)) calc(6 * var(--u));
  }
  #scorebug .clock-col { order: -1; }
  #scorebug .plates { gap: calc(3 * var(--u)); }
  #clock-time { font-size: calc(15 * var(--u)); }
  /* The colour chip already identifies the seat, so the alias is the label
     that gives way and the REAL policy name keeps the room. */
  .plate-alias { display: none; }
  .hplate { min-width: 0; flex: 1 1 30%; padding: calc(1 * var(--u)) calc(3 * var(--u)); }
  .hplate .plate-energy { display: none; }
  .hplate .plate-badge { display: none; }
  #feed { max-width: 72%; font-size: calc(7.5 * var(--u)); }
  #ec-headline { font-size: clamp(13px, 4.2vw, 26px); }
}
"""

GAME_MARKUP_SCOREBUG = """      <div class="plates" id="plates-l"></div>

      <div class="clock-col">
        <div class="clock amb" id="clock">
          <div class="time" id="clock-time">ROUND 1 OF 3</div>
          <span class="ffwd-mini" id="ffwd-mini">&#9656;&#9656;</span>
          <div class="caption" id="clock-caption">Waiting for the hunt</div>
        </div>
      </div>

      <div class="plates" id="plates-r"></div>
"""

GAME_SCRIPT = r"""
  /* ==========================================================
     cooperative-hunting additions to the inherited coworld-ctf chrome.
     Everything above this comment is the starter's boot scaffolding; this
     block is the game half: it reads the chrome label off sprite 4090 (via
     BroadcastCore's onText, which the worker forwards) and drives the six
     hunter plates, the round clock, the feed, the scrubber beats, the
     endcard and the grass toggle.

     No function declared here may share a name with a ChromeCommon alias
     (markBeat, esc, fmt, renderClock, ...): a hoisted `function markBeat`
     shadows the alias and the beats render as unlabeled dead divs (tandem,
     2026-08-23). Ours is pushHuntBeat.
     ========================================================== */
  function boot() {
    var byId = function (id) { return document.getElementById(id); };
    var core = null;
    var chromeCommon = null;
    var speed = 1;
    var skipping = false;
    var chrome = null;
    var beatsBuilt = false;
    var beatEls = [];
    var feedSeen = {};
    var platesBuilt = 0;
    var tickCount = 1;
    var currentIndex = 0;
    var loop = false;
    var endShown = false;
    var grassOpen = false;

    function escText(value) { return String(value == null ? '' : value); }

    function fmtRound(state) {
      return 'ROUND ' + state.round + ' OF ' + state.rounds;
    }

    // ---- scorebug --------------------------------------------------------
    function buildPlates(seats) {
      var left = byId('plates-l');
      var right = byId('plates-r');
      left.textContent = '';
      right.textContent = '';
      var half = Math.ceil(seats.length / 2);
      seats.forEach(function (seat, index) {
        var plate = document.createElement('div');
        plate.className = 'hplate';
        plate.id = 'hplate-' + seat.slot;
        var chip = document.createElement('span');
        chip.className = 'chip';
        chip.style.background = COG_COLORS[seat.color % COG_COLORS.length];
        plate.appendChild(chip);
        var alias = document.createElement('span');
        alias.className = 'plate-alias';
        alias.textContent = escText(seat.alias);
        plate.appendChild(alias);
        var name = document.createElement('span');
        name.className = 'plate-name';
        // Real policy names live HERE and in the endcard, and nowhere else:
        // in-game every hunter is only a coloured sprite and a Cog- alias.
        name.textContent = escText(seat.name);
        plate.appendChild(name);
        var energy = document.createElement('span');
        energy.className = 'plate-energy';
        energy.innerHTML = '<i></i>';
        plate.appendChild(energy);
        var badge = document.createElement('span');
        badge.className = 'plate-badge';
        plate.appendChild(badge);
        var score = document.createElement('span');
        score.className = 'plate-score';
        score.textContent = '0';
        plate.appendChild(score);
        (index < half ? left : right).appendChild(plate);
      });
      platesBuilt = seats.length;
    }

    var COG_COLORS = [
      '#ff004d', '#29adff', '#ffa300', '#ff77a8', '#ffec27', '#00e436',
      '#8376c8', '#fff1e8', '#008751', '#ab5236', '#1d2b53', '#7e2553',
      '#00c8c8', '#c2c3c7', '#ff6464', '#b4e650', '#dc96ff', '#ffc878',
      '#64dcaa', '#ff50b4'
    ];

    function updatePlates(state) {
      state.seats.forEach(function (seat) {
        var plate = byId('hplate-' + seat.slot);
        if (!plate) return;
        plate.classList.toggle('dc', !!seat.dc);
        var bar = plate.querySelector('.plate-energy i');
        if (bar) bar.style.width = Math.max(0, Math.min(100, seat.energy / 2)) + '%';
        var score = plate.querySelector('.plate-score');
        if (score) score.textContent = String(seat.score);
        var badge = plate.querySelector('.plate-badge');
        if (badge) {
          if (state.variant === 'lbf') {
            badge.textContent = 'L' + seat.level;
            badge.hidden = false;
          } else if (state.variant === 'predator-prey') {
            badge.textContent = seat.role === 'forager' ? 'FORAGE' : 'HUNT';
            badge.hidden = false;
          } else {
            badge.textContent = '';
            badge.hidden = true;
          }
        }
      });
    }

    // ---- clock -----------------------------------------------------------
    function updateClock(state) {
      // Real numbers, never internal notation: the round out of the round
      // count, and the play tick out of the episode's play ticks.
      var playTick = (state.round - 1) * state.ticksPerRound +
        (state.rtick || 0);
      var playTotal = state.rounds * state.ticksPerRound;
      byId('clock-time').textContent = fmtRound(state);
      byId('clock-caption').textContent =
        (state.phase === 'card'
          ? 'Round card'
          : (VARIANT_CAPTION[state.variant] || 'The hunt')) +
        ' \u00b7 ' + playTick + ' / ' + playTotal;
      // #tick-clock belongs to the transport bar, and chrome_common's
      // renderTransport writes it from the scrubber's own axis.
    }

    var VARIANT_CAPTION = {
      'staghunt': 'Stag hunt',
      'coop-mining': 'Cooperative mining',
      'lbf': 'Level-based foraging',
      'predator-prey': 'Predator and prey'
    };

    // ---- feed ------------------------------------------------------------
    // The chrome label carries only the lines NEW since the previous frame,
    // but the replay re-emits the SAME frame for as long as the playhead
    // sits on a tick -- paused, scrubbed, or parked at the end -- so each of
    // those lines arrives again on every one of those frames. Rebuilding the
    // host for each of them restarted the `feedin` entrance animation at
    // 8 Hz and no row ever settled: in run 32774674232 the six end-of-hunt
    // lines drew permanently mid-animation, translated past the right frame
    // edge at 60 % opacity. Dedupe on the line's own identity and append
    // only what is new, so a row animates in once and then stays put.
    function feedKey(line) {
      return line.t + '|' + (line.kind || '') + '|' + line.text;
    }

    function clearFeed() {
      feedSeen = {};
      byId('feed').textContent = '';
    }

    function pumpFeed(state) {
      if (!state.feed || !state.feed.length) return;
      var host = byId('feed');
      state.feed.forEach(function (line) {
        var key = feedKey(line);
        if (feedSeen[key]) return;
        feedSeen[key] = true;
        var row = document.createElement('div');
        row.className = 'feed-row ' + (line.kind || '');
        row.textContent = escText(line.text);
        host.appendChild(row);
      });
      while (host.children.length > 6) host.removeChild(host.firstChild);
    }

    // ---- scrubber beats --------------------------------------------------
    var BEAT_LABEL = {
      round: 'Round boundary',
      bigcatch: 'Big animal taken',
      smallcatch: 'Small catch',
      tag: 'Forager tagged',
      end: 'Hunt over'
    };

    function pushHuntBeat(tick, kind) {
      // NOT markBeat: that name is a ChromeCommon alias and a hoisted
      // declaration here would shadow it (tandem, 2026-08-23).
      var label = BEAT_LABEL[kind];
      if (!label) return;
      var mark = document.createElement('button');
      mark.type = 'button';
      mark.className = 'beat-marker ' + kind;
      mark.style.left = (100 * tick / Math.max(1, tickCount)) + '%';
      mark.title = label + ' at tick ' + tick;
      mark.textContent = label;
      mark.setAttribute('aria-label', label + ' at tick ' + tick + ' (seek)');
      mark.onclick = function (event) {
        event.stopPropagation();
        seekTo(Math.round(tick * (tickCount - 1) / Math.max(1, tickCount)));
      };
      byId('scrub').appendChild(mark);
      beatEls.push({ tick: tick, el: mark });
    }

    function buildBeats(state) {
      if (beatsBuilt || !state.beats || !state.beats.length) return;
      beatsBuilt = true;
      state.beats.forEach(function (beat) { pushHuntBeat(beat.t, beat.k); });
    }

    function gateBeats(state) {
      var spoil = chromeCommon ? chromeCommon.getSpoilers()
        : byId('btn-spoilers').classList.contains('on');
      beatEls.forEach(function (entry) {
        entry.el.classList.toggle('ahead', !spoil && entry.tick > state.tick);
      });
    }

    // ---- endcard ---------------------------------------------------------
    function showEndcard(final) {
      if (endShown || !final) return;
      endShown = true;
      byId('ec-headline').textContent = final.reason === 'complete'
        ? 'HUNT OVER'
        : 'HUNT OVER \u2014 ' + String(final.reason).toUpperCase();
      byId('ec-wincond').textContent = 'Score is every capture you stood a ' +
        'side for. Higher is better.';
      byId('ec-how').textContent = '';
      var host = byId('ec-standings');
      host.textContent = '';
      (final.order || []).forEach(function (entry, index) {
        var row = document.createElement('div');
        row.className = 'row';
        var rank = document.createElement('span');
        rank.className = 'rank';
        rank.textContent = '#' + (index + 1);
        row.appendChild(rank);
        var alias = document.createElement('span');
        alias.className = 'plate-alias';
        alias.textContent = escText(entry.alias);
        row.appendChild(alias);
        var name = document.createElement('span');
        name.className = 'plate-name';
        name.textContent = escText(entry.name);
        row.appendChild(name);
        var score = document.createElement('span');
        score.className = 'score';
        score.textContent = String(entry.score);
        row.appendChild(score);
        host.appendChild(row);
      });
      byId('endcard').classList.add('on');
      byId('win-chip').textContent = String(final.reason).toUpperCase();
    }

    function hideEndcard() {
      endShown = false;
      byId('endcard').classList.remove('on');
    }

    // ---- transport -------------------------------------------------------
    function seekTo(index) {
      // Every seek dismisses the endcard so the match is visible again; it
      // comes back when playback reaches the end once more. The feed goes
      // with it: its lines are the ones new since the previous frame, so
      // after a jump they belong to a stretch of the hunt that is no longer
      // on screen -- and clearing lets them arrive again if playback
      // returns to them.
      hideEndcard();
      clearFeed();
      currentIndex = Math.max(0, Math.min(tickCount - 1, index));
      core.seek(currentIndex);
    }

    // ---- the ChromeCommon seam ------------------------------------------
    // chrome_common.js is the starter's shared chrome and this page
    // INSTANTIATES it: loading the file and then re-implementing what it
    // does is how a page becomes a lookalike. It owns the transport bar
    // (the play/loop/skip glyphs, the speed chips, the ffwd chips), the
    // scrubber geometry and its tick clock, the lull spans, the momentum
    // band and the spoiler toggle.
    //
    // What stays in this block is the half that is this game's own and that
    // chrome_common has no shape for: the round clock (a hunt has rounds
    // and a round card, not a countdown to a draw limit), the six hunter
    // plates, the feed, the end-card, and the beat markers -- ours are
    // LABELLED buttons that seek to their tick, which the starter's
    // markBeat, an unlabelled div, cannot be.
    //
    // The momentum band stays empty on purpose: it draws a lives LEAD
    // between sides and a hunt has no sides. Feeding it six same-coloured
    // score lines would be a fiction, so the band is left as the starter
    // ships it rather than filled with one.
    var SPEED_COMMANDS = { '5': 0.5, '1': 1, '2': 2, '3': 3, '4': 4, '8': 8, '6': 16 };

    function sendTransportCommand(command) {
      // chrome_common's speed chips send the wire command chars the starter
      // uses; this replay's transport is a local core, so map them back.
      var value = SPEED_COMMANDS[command];
      if (!value || !core) return;
      speed = value;
      core.setSpeed(value);
      paintTransport();
    }

    function transportState() {
      // The frame chrome_common's renderTransport reads. `st`/`mx`/`t` are
      // the scrubber's axis: a replay has no lobby prefix, so it starts at
      // 0. No `teams`/`roster`/`lead`: see the momentum note above.
      return {
        en: true,
        pl: !!(core && core.isPlaying()),
        lp: loop,
        sk: skipping,
        ff: skipping,
        sp: speed,
        st: 0,
        mx: Math.max(1, tickCount - 1),
        t: Math.max(0, Math.min(currentIndex, tickCount - 1)),
        ph: 'playing'
      };
    }

    function paintTransport() {
      // NOT `renderTransport`: that name is a ChromeCommon alias and a
      // hoisted declaration here would shadow it.
      if (chromeCommon) chromeCommon.renderTransport(transportState());
    }

    function wireTransport() {
      byId('btn-play').onclick = function () {
        core.setPlaying(!core.isPlaying());
        paintTransport();
      };
      byId('btn-restart').onclick = function () { seekTo(0); };
      byId('btn-back').onclick = function () { seekTo(currentIndex - 1); };
      byId('btn-fwd').onclick = function () { seekTo(currentIndex + 40); };
      byId('btn-end').onclick = function () { seekTo(tickCount - 1); };
      byId('btn-loop').onclick = function () {
        loop = !loop;
        paintTransport();
      };
      byId('btn-skip').onclick = function () {
        skipping = !skipping;
        speed = skipping ? 4 : 1;
        core.setSpeed(speed);
        paintTransport();
      };
      // chrome_common owns the spoiler toggle: it carries the URL default
      // (?spoilers=0), the button's `on` class and its own click listener,
      // which runs before this one. All that is left here is re-gating THIS
      // game's beat markers against the new value.
      byId('btn-spoilers').addEventListener('click', function () {
        if (chrome) gateBeats(chrome);
      });
      byId('scrub').onclick = function (event) {
        // Beat markers stopPropagation, so anything that reaches here is a
        // seek on the track itself.
        var rect = byId('scrub').getBoundingClientRect();
        var ratio = (event.clientX - rect.left) / Math.max(1, rect.width);
        seekTo(Math.round(ratio * (tickCount - 1)));
      };
      byId('btn-grass').onclick = function () {
        grassOpen = !grassOpen;
        byId('btn-grass').classList.toggle('on', grassOpen);
        core.sendCommand('g');
      };
      window.addEventListener('keydown', function (event) {
        if (event.key === ' ') { byId('btn-play').onclick(); event.preventDefault(); }
        else if (event.key === 'e') seekTo(tickCount - 1);
        else if (event.key === ',') seekTo(0);
        else if (event.key === 'b') byId('btn-back').onclick();
        else if (event.key === '.') byId('btn-fwd').onclick();
        else if (event.key === 'r') byId('btn-loop').onclick();
        else if (event.key === 'f') byId('btn-skip').onclick();
        else if (event.key === 'o') byId('btn-spoilers').click();
      });
    }

    // ---- the chrome channel ---------------------------------------------
    function onChromeText(text) {
      var state;
      try { state = JSON.parse(text); } catch (error) { return; }
      if (!state || typeof state.tick !== 'number') return;
      chrome = state;
      if (state.seats && state.seats.length &&
          platesBuilt !== state.seats.length) {
        buildPlates(state.seats);
      }
      buildBeats(state);
      updateClock(state);
      updatePlates(state);
      pumpFeed(state);
      gateBeats(state);
      byId('gamechips').hidden = state.variant !== 'predator-prey';
      byId('status').textContent = '';
      paintTransport();
      if (state.final) showEndcard(state.final);
    }

    // ---- boot ------------------------------------------------------------
    core = window.CooperativeHuntingStaticReplay.createCore({
      canvas: byId('board'),
      onText: onChromeText,
      onStatus: function (status) { byId('status').textContent = status; },
      onFirstFrame: function () { core.setViewportFit(); },
      onLoaded: function (count) {
        tickCount = count || 1;
        core.setViewportFit();
      },
      onTick: function (index, count) {
        currentIndex = index;
        tickCount = count || tickCount;
      },
      onEnd: function () {
        if (loop) { seekTo(0); return; }
        if (chrome && chrome.final) showEndcard(chrome.final);
      }
    });
    chromeCommon = window.ChromeCommon({
      send: sendTransportCommand,
      sendPov: function () {},   // no POV lens: the whole board is always up
      getState: transportState
    });
    wireTransport();
    paintTransport();
    window.addEventListener('resize', function () { core.setViewportFit(); });
    core.start();

    // --hudscale / --band relayout loop, inherited from the starter. The
    // game block READS --band and never writes it.
    var lastBoardBox = '';
    function relayout() {
      var stage = byId('stage');
      var root = document.documentElement;
      var width = stage.clientWidth || 760;
      root.style.setProperty('--hudscale',
        String(Math.max(0.5, Math.min(1.6, width / 760))));
      stage.classList.toggle('tiny', width <= 620);
      var transport = byId('transport');
      if (transport) root.style.setProperty('--band', transport.offsetHeight + 'px');
      // --topband is the starter's other reserved band: the scorebug strip
      // above the board. #board and #endcard both size against it, so a
      // six-plate scorebug that is taller than ctf's two-plate one must
      // report its real height or it covers play.
      var scorebug = byId('scorebug');
      if (scorebug) root.style.setProperty('--topband', scorebug.offsetHeight + 'px');
      var board = byId('board');
      var boxKey = board.clientWidth + 'x' + board.clientHeight;
      if (boxKey !== lastBoardBox) {
        lastBoardBox = boxKey;
        if (core) core.setViewportFit();
      }
      requestAnimationFrame(relayout);
    }
    relayout();
  }
"""


def main():
    starter = sys.argv[1] if len(sys.argv) > 1 else STARTER_DEFAULT
    src = open(starter + "/client/replay_broadcast.html").read().split("\n")

    head = "\n".join(src[0:6])
    head = head.replace("<title>Ctf — Broadcast Replay</title>",
                        "<title>Cooperative Hunting — Broadcast Replay</title>")
    css = filter_css("\n".join(src[7:1459]))
    # The starter ships a `rajdhani` webfont next to its bundle; this game's
    # bundle carries no font file, so the @font-face would 404 on every load.
    # Drop the rule and let --pixfont fall through to the embedded pixel face
    # and the system stack, which is what it already lists as its fallbacks.
    css = re.sub(
        r"@font-face \{\s*font-family: 'rajdhani';.*?\}\s*", "", css,
        flags=re.S)
    css = css.replace("(align-items:flex-end on #killfeed)",
                      "(align-items:flex-end on #feed)")
    body = "\n".join(src[1462:1600])

    # --- body surgery: remove the elements the note lists, rename the feed,
    #     add the six-plate scorebug, the game chips and the endcard table.
    body = re.sub(r"  <!-- Pre-load curtain.*?</div>\n\n", "", body, flags=re.S)
    body = re.sub(r"    <!-- View controls.*?\n    </div>\n\n", "", body, flags=re.S)
    body = re.sub(r"    <div id=\"mmwarn\">.*?\n", "", body)
    body = re.sub(r"    <div id=\"povBadge\">.*?\n", "", body)
    body = re.sub(r"    <!-- First-person picture-in-picture.*?\n    </div>\n",
                  "", body, flags=re.S)
    # #bannerlane stays. It is not on the design note's removal list, its CSS
    # section (3. BANNER LANE) is kept verbatim above the banner comment, and
    # an empty lane draws nothing: it is `pointer-events: none` with a
    # reserved min-height so the layout never jumps when a chip lands. Taking
    # the element out while keeping its rules left the page one silent step
    # further from the starter's for no gain.
    body = body.replace('    <div id="killfeed"></div>',
                        '    <!-- One line per catch, plan `say`, trample, gore, tag, forage and\n'
                        '         fallback. #feed replaces the starter\'s #killfeed. -->\n'
                        '    <div id="feed"></div>\n'
                        '    <!-- predator-prey only: fade tall grass to 40 % alpha so the\n'
                        '         spectator sees the ambush the hunter could not. -->\n'
                        '    <div id="gamechips" hidden>\n'
                        '      <button type="button" id="btn-grass">grass</button>\n'
                        '    </div>')
    body = body.replace(
        '<span class="momentum-label">LIVES LEAD</span>',
        '<span class="momentum-label">HUNT</span>')
    body = re.sub(
        r'    <!-- Plates are generated.*?    <div id="scorebug">\n.*?\n    </div>\n',
        '    <!-- Six hunter plates in slot order, three each side of the clock:\n'
        '         colour chip, Cog- alias, the real policy name, score, an energy\n'
        '         bar 0-200 and a role/level badge. Built by buildPlates(). -->\n'
        '    <div id="scorebug">\n' + GAME_MARKUP_SCOREBUG + '    </div>\n',
        body, flags=re.S)
    body = body.replace(
        '      <div class="ec-teams" id="ec-teams"></div>',
        '      <div class="ec-teams" id="ec-teams"></div>\n'
        '      <div id="ec-standings"></div>')

    boot = """<!-- CHROME_COMMON -->
<!-- BROADCAST_CORE -->

<script>
(function () {
  'use strict';

  // The two splice markers above are replaced with <script src> tags by
  // Dockerfile.replay-viewer when the static bundle is built. A raw open of
  // this source file has no splice, so pull the same files in by src and
  // re-enter once they are up. Inherited from the starter.
  function need(name, global) {
    return typeof window[global] === 'undefined' ? name : null;
  }
  var missing = [
    need('chrome_common.js', 'ChromeCommon'),
    need('static_replay.js', 'CooperativeHuntingStaticReplay')
  ].filter(Boolean);
  if (missing.length) {
    var base = location.pathname.indexOf('/client/') === 0 ? '/client/' : './';
    var pending = missing.length;
    missing.forEach(function (file) {
      var tag = document.createElement('script');
      tag.src = base + file;
      tag.onload = function () { if (--pending === 0) boot(); };
      tag.onerror = function () { pending = -1; };
      document.head.appendChild(tag);
    });
    return;
  }
  boot();
""" + GAME_SCRIPT + """})();
</script>
</body>
</html>
"""

    out = (head + "\n<style>\n" + css + "\n" + GAME_CSS + "</style>\n</head>\n"
           "<body>\n" + body + "\n" + boot)
    sys.stdout.write(out)


if __name__ == "__main__":
    main()
