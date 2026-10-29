'use strict';

const $app = document.getElementById('app');
const $crumb = document.getElementById('crumb');

const ICON = {
  prev: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M6 5h2.2v14H6zM19.5 5.6v12.8L9.6 12z"/></svg>',
  next: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M15.8 5H18v14h-2.2zM4.5 5.6v12.8L14.4 12z"/></svg>',
  play: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M7.5 4.8v14.4L19.5 12z"/></svg>',
  pause: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M6.5 4.8h4v14.4h-4zM13.5 4.8h4v14.4h-4z"/></svg>',
  restart: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M4.5 12a7.5 7.5 0 1 0 2.2-5.3"/><path d="M4.5 4.5v4.2h4.2"/></svg>',
  upload: '<svg class="drop-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 15V4M7.5 8.5 12 4l4.5 4.5"/><path d="M4 14.5V18a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-3.5"/></svg>',
};

const BUSY = ['queued', 'prepare', 'transcribe', 'segment', 'translate'];
const DEFAULTS = { reps: 20, gap: 0.6, speed: 1, after: 'stop', hideDirections: true };

const store = {
  get(key, fallback) {
    try { const v = localStorage.getItem(key); return v == null ? fallback : JSON.parse(v); }
    catch (e) { return fallback; }
  },
  set(key, value) {
    try { localStorage.setItem(key, JSON.stringify(value)); } catch (e) { /* 사생활 보호 모드 등 */ }
  },
};
const settings = Object.assign({}, DEFAULTS, store.get('lcr.settings', {}));
const saveSettings = () => store.set('lcr.settings', settings);

const $ = (sel, root = document) => root.querySelector(sel);
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
const round3 = v => Math.round(v * 1000) / 1000;
const isBusy = st => BUSY.includes(st && st.stage);

function fmtClock(sec) {
  const m = Math.floor(sec / 60);
  const s = sec - m * 60;
  return `${m}:${s.toFixed(1).padStart(4, '0')}`;
}
function fmtDuration(sec) {
  const m = Math.floor(sec / 60);
  return `${m}분 ${Math.round(sec - m * 60)}초`;
}
function fmtDate(ts) {
  return ts ? new Date(ts * 1000).toLocaleString('ko-KR',
    { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' }) : '';
}

async function api(path, opts) {
  const res = await fetch(path, opts);
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || res.statusText);
  return data;
}

let toastTimer = null;
function toast(msg, ms = 2400) {
  let el = $('.toast');
  if (!el) { el = document.createElement('div'); el.className = 'toast'; document.body.appendChild(el); }
  el.textContent = msg;
  el.classList.add('show');
  clearTimeout(toastTimer);
  if (ms) toastTimer = setTimeout(() => el.classList.remove('show'), ms);
}

// 누른 버튼에 포커스가 남으면 Space가 그 버튼을 다시 누르므로 바로 풀어 준다
document.addEventListener('click', e => {
  const b = e.target.closest('button');
  if (b) b.blur();
});
// 끌어다 놓기 영역 밖에 떨어뜨려도 브라우저가 파일을 열지 않게
window.addEventListener('dragover', e => e.preventDefault());
window.addEventListener('drop', e => e.preventDefault());

// ---------- 라우터 ----------

let cleanup = null;
let setup = null;          // /api/setup 결과. 모델이 준비되면 다시 묻지 않는다
let setupSkipped = false;  // 모델 없이 이미 처리한 음원만 보겠다고 했을 때
async function route() {
  if (cleanup) { cleanup(); cleanup = null; }
  window.scrollTo(0, 0);
  const m = location.hash.match(/^#\/l\/([\w-]+)/);
  if (m) { showLesson(m[1]); return; }
  if (!setup || !setup.model.ready) {
    try { setup = await api('/api/setup'); } catch (e) { setup = null; }
    if (setup && !setup.model.ready && !setupSkipped) { showSetup(); return; }
  }
  showHome();
}
window.addEventListener('hashchange', route);

// ---------- 첫 실행: 모델 내려받기 ----------

const MB = 1024 * 1024;

function showSetup() {
  $crumb.textContent = '처음 준비';
  $app.innerHTML = `
    <div class="working setup">
      <h2>처음 한 번, 음성 인식 모델을 내려받을게요</h2>
      <p>Whisper large-v3-turbo (약 547MB)를 huggingface.co에서 받아 이 맥에만 저장합니다.
         중간에 끊기면 받은 데까지 이어서 받습니다.</p>
      <div class="progress"><i id="dlbar" style="width:0%"></i></div>
      <p id="dltext" class="dl-text"></p>
      <p id="dlerror" class="error-text" hidden></p>
      <div><button class="btn solid" id="dlbtn">내려받기</button></div>
      <p id="skip" hidden><a href="#/">건너뛰고 이미 처리한 음원 보기</a></p>
      ${setup && !setup.claude ? `<p class="note">번역에는 Claude Code가 필요해요. 설치하고 터미널에서 <code>claude</code>를 실행해 로그인해 두면
         자동으로 번역이 붙습니다. 없어도 문장 반복은 쓸 수 있어요.</p>` : ''}
    </div>`;

  let alive = true;
  let timer = null;
  cleanup = () => { alive = false; clearTimeout(timer); };

  function render(st) {
    const pct = st.total ? st.received / st.total * 100 : 0;
    $('#dlbar').style.width = pct.toFixed(1) + '%';
    $('#dltext').textContent = st.downloading || st.received
      ? `${Math.round(st.received / MB)}MB${st.total ? ' / ' + Math.round(st.total / MB) + 'MB (' + Math.floor(pct) + '%)' : ''}`
      : '';
    const err = $('#dlerror');
    err.hidden = !st.error;
    err.textContent = st.error ? '내려받지 못했어요: ' + st.error : '';
    const btn = $('#dlbtn');
    btn.disabled = st.downloading;
    btn.textContent = st.downloading ? '내려받는 중…' : (st.error || st.received ? '이어서 받기' : '내려받기');
  }

  async function poll() {
    let s;
    try { s = await api('/api/setup'); } catch (e) { s = null; }
    if (!alive) return;
    if (s) {
      setup = s;
      if (s.model.ready) { toast('준비가 끝났어요'); route(); return; }
      render(s.model);
      if (!s.model.downloading) return;     // 끝났거나 실패하면 폴링 멈춤
    }
    timer = setTimeout(poll, 700);
  }

  $('#dlbtn').addEventListener('click', async () => {
    try {
      render(await api('/api/setup/download', { method: 'POST' }));
    } catch (e) {
      toast('시작하지 못했어요: ' + e.message);
      return;
    }
    clearTimeout(timer);
    timer = setTimeout(poll, 500);
  });
  $('#skip a').addEventListener('click', e => { e.preventDefault(); setupSkipped = true; route(); });
  api('/api/lessons').then(list => { if (alive && list.length) $('#skip').hidden = false; }).catch(() => {});
  if (setup) render(setup.model);
  if (setup && setup.model.downloading) poll();
}

// ---------- 홈 ----------

let refreshHome = null;

function statusChip(st, count) {
  st = st || {};
  if (st.stage === 'done') {
    return st.error ? '<span class="chip warn">번역 없음</span>' : `<span class="chip ok">문장 ${count}개</span>`;
  }
  if (st.stage === 'error') return '<span class="chip err">오류</span>';
  return `<span class="chip busy">${esc(st.label || '처리 중')} ${Math.round((st.progress || 0) * 100)}%</span>`;
}

function showHome() {
  $crumb.textContent = '';
  document.title = 'LC Repeater';
  $app.innerHTML = `
    <label class="drop" id="drop">
      <input type="file" id="file" accept="audio/*,.mp3,.m4a,.wav" multiple hidden>
      ${ICON.upload}
      <div class="drop-title">mp3 파일을 끌어다 놓거나 눌러서 고르세요</div>
      <div class="drop-sub">음성 인식 → 문장 나누기 → 한국어 번역까지 자동으로 합니다</div>
    </label>
    ${setup && !setup.model.ready ? `<div class="banner" style="margin-top:12px"><span class="msg">음성 인식 모델이 없어서 새 음원은 아직 올릴 수 없어요.</span>
      <button class="btn" id="toSetup">모델 내려받기</button></div>` : ''}
    <div class="section-title">내 음원</div>
    <ul class="lessons" id="lessons"><li class="empty">불러오는 중…</li></ul>`;

  if ($('#toSetup')) $('#toSetup').addEventListener('click', () => { setupSkipped = false; route(); });
  const drop = $('#drop');
  const input = $('#file');
  input.addEventListener('change', () => { uploadFiles(input.files); input.value = ''; });
  ['dragenter', 'dragover'].forEach(ev => drop.addEventListener(ev, e => {
    e.preventDefault(); drop.classList.add('over');
  }));
  ['dragleave', 'drop'].forEach(ev => drop.addEventListener(ev, () => drop.classList.remove('over')));
  drop.addEventListener('drop', e => { e.preventDefault(); uploadFiles(e.dataTransfer.files); });

  let alive = true;
  let timer = null;
  async function refresh() {
    clearTimeout(timer);
    try {
      const list = await api('/api/lessons');
      if (!alive) return;
      $('#lessons').innerHTML = list.length ? list.map(l => `
        <li><a class="lesson-item" href="#/l/${l.id}">
          <span class="lesson-title">${esc(l.title)}</span>
          ${statusChip(l.status, l.count)}
          <span class="lesson-sub">${fmtDate(l.created)}${l.duration ? ' · ' + fmtDuration(l.duration) : ''}</span>
        </a></li>`).join('') : '<li class="empty">아직 올린 음원이 없어요.</li>';
      timer = setTimeout(refresh, list.some(l => isBusy(l.status)) ? 1500 : 6000);
    } catch (e) {
      if (alive) timer = setTimeout(refresh, 3000);
    }
  }
  refreshHome = refresh;
  refresh();
  cleanup = () => { alive = false; clearTimeout(timer); refreshHome = null; };
}

async function uploadFiles(fileList) {
  const files = Array.from(fileList || []).filter(f => /\.(mp3|m4a|wav|aac|ogg|flac|mp4)$/i.test(f.name));
  if (!files.length) { toast('mp3 같은 오디오 파일만 올릴 수 있어요'); return; }
  let lastId = null;
  for (const f of files) {
    toast(`올리는 중: ${f.name}`, 0);
    try {
      const r = await api('/api/lessons', {
        method: 'POST', headers: { 'X-Filename': encodeURIComponent(f.name) }, body: f,
      });
      lastId = r.id;
    } catch (e) {
      toast('올리기 실패: ' + e.message);
      return;
    }
  }
  if (files.length === 1) {
    toast('올렸어요. 처리를 시작합니다');
    location.hash = '#/l/' + lastId;
  } else {
    toast(`${files.length}개를 올렸어요. 차례로 처리합니다`);
    if (refreshHome) refreshHome();
  }
}

// ---------- 레슨 ----------

function showLesson(id) {
  $app.innerHTML = '<div class="working"><p>불러오는 중…</p></div>';
  let alive = true;
  let timer = null;
  let player = null;
  cleanup = () => { alive = false; clearTimeout(timer); if (player) player.destroy(); };

  async function poll() {
    let data;
    try {
      data = await api('/api/lessons/' + id);
    } catch (e) {
      if (alive) $app.innerHTML = '<div class="working"><h2>레슨을 찾을 수 없어요</h2><p><a href="#/">처음으로</a></p></div>';
      return;
    }
    if (!alive) return;
    const st = data.status || {};
    if (data.lesson && (st.stage === 'done' || st.stage === 'translate')) {
      player = new Player(id, data);
      return;
    }
    if (st.stage === 'error') {
      $app.innerHTML = `<div class="working"><h2>처리하지 못했어요</h2>
        <p class="error-text">${esc(st.error)}</p><p><a href="#/">처음으로</a></p></div>`;
      return;
    }
    const pct = Math.round((st.progress || 0) * 100);
    $crumb.textContent = '처리 중';
    $app.innerHTML = `<div class="working">
      <h2>${esc(st.label || '처리 중')}</h2>
      <div class="progress"><i style="width:${pct}%"></i></div>
      <p>${pct}% · 문장 나누기가 끝나면 번역을 기다리지 않고 바로 들을 수 있어요.</p>
      <p><a href="#/">목록으로</a></p></div>`;
    timer = setTimeout(poll, 1000);
  }
  poll();
}

class Player {
  constructor(id, data) {
    this.id = id;
    this.lesson = data.lesson;
    this.S = this.lesson.sentences;
    this.status = data.status || {};
    this.order = [];
    this.pos = 0;
    this.showKo = false;
    this.rep = 0;
    this.phase = 'idle';          // idle | playing | gap | paused | done
    this.timer = null;
    this.statusTimer = null;

    this.audio = new Audio();
    this.audio.preload = 'auto';
    this.audio.preservesPitch = true;          // 속도를 바꿔도 음 높이 유지
    this.audio.webkitPreservesPitch = true;
    this.onEnded = () => this.handleEnded();
    this.onError = () => { if (this.audio.src) toast('오디오를 불러오지 못했어요'); };
    this.audio.addEventListener('ended', this.onEnded);
    this.audio.addEventListener('error', this.onError);
    this.onKey = e => this.handleKey(e);
    document.addEventListener('keydown', this.onKey);

    $crumb.textContent = this.lesson.title;
    document.title = this.lesson.title + ' · LC Repeater';
    this.mount();
    this.computeOrder(store.get('lcr.pos.' + id, null));
    this.renderList();
    this.renderAll();
    this.loadCurrent();
    this.setupMediaSession();
    if (this.status.stage === 'translate') this.pollStatus();
  }

  destroy() {
    clearTimeout(this.timer);
    clearTimeout(this.statusTimer);
    this.audio.pause();
    this.audio.removeEventListener('ended', this.onEnded);
    this.audio.removeEventListener('error', this.onError);
    this.audio.removeAttribute('src');
    document.removeEventListener('keydown', this.onKey);
    this.dead = true;
  }

  mount() {
    const opt = (vals, cur) => vals.map(([v, label]) =>
      `<option value="${v}"${String(v) === String(cur) ? ' selected' : ''}>${label}</option>`).join('');
    $app.innerHTML = `
    <div class="player">
      <div class="stage">
        <div id="banner"></div>
        <div class="card" id="card" tabindex="0" role="button" aria-label="영어와 한국어 전환">
          <div class="card-meta"><span id="pos"></span><span class="lang" id="lang">EN</span></div>
          <p class="sentence" id="sentence"></p>
          <div class="card-hint" id="hint"></div>
        </div>
        <div class="counter">
          <div class="count-row"><div class="count" id="count"></div><div class="phase" id="phase"></div></div>
          <div class="progress"><i id="bar"></i></div>
        </div>
        <div class="controls">
          <button class="btn-icon" id="restart" title="처음부터 다시 (R)" aria-label="처음부터 다시">${ICON.restart}</button>
          <button class="btn-icon" id="prev" title="이전 문장 (←)" aria-label="이전 문장">${ICON.prev}</button>
          <button class="btn-icon primary" id="play" aria-label="재생/정지"></button>
          <button class="btn-icon" id="next" title="다음 문장 (→)" aria-label="다음 문장">${ICON.next}</button>
          <button class="btn-icon" id="langBtn" title="번역 보기 (T)" aria-label="번역 보기"><b>한</b></button>
        </div>
        <div class="panel">
          <div class="settings">
            <label class="field">반복 횟수
              <select id="reps">${opt([[1, '1회'], [3, '3회'], [5, '5회'], [10, '10회'], [15, '15회'], [20, '20회'], [30, '30회'], [50, '50회'], [100, '100회'], [0, '무한']], settings.reps)}</select></label>
            <label class="field">반복 사이 쉼
              <select id="gap">${opt([[0, '없음'], [0.3, '0.3초'], [0.6, '0.6초'], [1, '1초'], [1.5, '1.5초'], [2, '2초'], [3, '3초'], [-1, '문장 길이만큼(섀도잉)']], settings.gap)}</select></label>
            <label class="field">속도
              <select id="speed">${opt([[0.7, '0.7×'], [0.8, '0.8×'], [0.9, '0.9×'], [1, '1.0×'], [1.1, '1.1×'], [1.2, '1.2×'], [1.3, '1.3×']], settings.speed)}</select></label>
            <label class="field">다 들으면
              <select id="after">${opt([['stop', '멈추기'], ['next', '다음 문장으로']], settings.after)}</select></label>
          </div>
          <label class="check"><input type="checkbox" id="hideDir"${settings.hideDirections ? ' checked' : ''}> 시험 안내 문장(문항 번호, 파트 설명) 건너뛰기</label>
        </div>
        <div class="panel trim">
          <span>구간 조절</span>
          <span class="trim-group">시작 <button class="btn-sm" data-trim="start" data-d="-0.1">−0.1</button><button class="btn-sm" data-trim="start" data-d="0.1">+0.1</button></span>
          <span class="trim-group">끝 <button class="btn-sm" data-trim="end" data-d="-0.1">−0.1</button><button class="btn-sm" data-trim="end" data-d="0.1">+0.1</button></span>
          <span class="trim-range" id="range"></span>
        </div>
        <div class="keys"><kbd>Space</kbd> 재생/정지 · <kbd>←</kbd> <kbd>→</kbd> 이전/다음 · <kbd>T</kbd> 번역 · <kbd>R</kbd> 처음부터</div>
        <div class="panel export-panel" id="exportPanel">
          <a class="btn" id="exportLink" download>아이폰용 레슨 내보내기</a>
          <span>AirDrop이나 iCloud Drive로 옮긴 뒤 아이폰 앱에서 가져오세요.</span>
        </div>
      </div>
      <aside class="list-wrap">
        <div class="list-head">문장 목록 <span id="listCount"></span></div>
        <ol class="sent-list" id="list"></ol>
      </aside>
    </div>`;

    this.el = {};
    ['banner', 'card', 'pos', 'lang', 'sentence', 'hint', 'count', 'phase', 'bar', 'restart', 'prev',
      'play', 'next', 'langBtn', 'range', 'list', 'listCount', 'reps', 'gap', 'speed', 'after', 'hideDir', 'exportPanel', 'exportLink']
      .forEach(k => { this.el[k] = document.getElementById(k); });
    const el = this.el;

    el.card.addEventListener('click', () => this.toggleLang());
    el.langBtn.addEventListener('click', () => this.toggleLang());
    el.play.addEventListener('click', () => this.togglePlay());
    el.restart.addEventListener('click', () => this.restart());
    el.prev.addEventListener('click', () => this.go(this.pos - 1));
    el.next.addEventListener('click', () => this.go(this.pos + 1));
    el.list.addEventListener('click', e => {
      const li = e.target.closest('li[data-p]');
      if (li) this.go(Number(li.dataset.p));
    });
    $app.querySelectorAll('[data-trim]').forEach(b =>
      b.addEventListener('click', () => this.trim(b.dataset.trim, Number(b.dataset.d))));

    const onSetting = (key, parse) => e => {
      settings[key] = parse(e.target);
      saveSettings();
      e.target.blur();
      if (key === 'speed') this.audio.playbackRate = settings.speed;
      if (key === 'hideDirections') { this.computeOrder(this.cur().i); this.renderList(); }
      if (key === 'reps' && this.phase === 'gap' && settings.reps && this.rep >= settings.reps) this.finish();
      this.renderAll();
    };
    el.reps.addEventListener('change', onSetting('reps', t => Number(t.value)));
    el.gap.addEventListener('change', onSetting('gap', t => Number(t.value)));
    el.speed.addEventListener('change', onSetting('speed', t => Number(t.value)));
    el.after.addEventListener('change', onSetting('after', t => t.value));
    el.hideDir.addEventListener('change', onSetting('hideDirections', t => t.checked));
  }

  // ---- 상태 ----

  computeOrder(keepI) {
    const all = this.S.map((s, k) => k);
    this.order = all.filter(k => !(settings.hideDirections && this.S[k].kind === 'direction'));
    if (!this.order.length) this.order = all;
    if (keepI == null) { this.pos = 0; return; }
    const p = this.order.findIndex(k => this.S[k].i >= keepI);
    this.pos = p < 0 ? this.order.length - 1 : p;
  }

  cur() { return this.S[this.order[this.pos]]; }

  clipUrl(s) {
    return `/api/lessons/${this.id}/clip/${Math.round(s.start * 1000)}-${Math.round(s.end * 1000)}.wav`;
  }

  loadCurrent() {
    const url = this.clipUrl(this.cur());
    if (this.audio.dataset.url !== url) {
      this.audio.src = url;
      this.audio.dataset.url = url;
    }
  }

  preloadNext() {
    const k = this.order[this.pos + 1];
    if (k != null) fetch(this.clipUrl(this.S[k])).catch(() => {});
  }

  // ---- 재생 ----

  playOnce() {
    clearTimeout(this.timer);
    this.loadCurrent();
    this.audio.currentTime = 0;
    this.audio.defaultPlaybackRate = settings.speed;
    this.audio.playbackRate = settings.speed;
    this.phase = 'playing';
    const p = this.audio.play();
    if (p && p.catch) {
      p.catch(err => {
        if (this.dead || err.name === 'AbortError') return;
        this.phase = 'paused';
        this.renderCounter();
        toast('재생 버튼을 눌러 주세요');
      });
    }
    this.renderCounter();
  }

  handleEnded() {
    if (this.phase !== 'playing') return;
    this.rep += 1;
    if (!settings.reps || this.rep < settings.reps) {
      const s = this.cur();
      const gap = settings.gap < 0 ? (s.end - s.start) / settings.speed : settings.gap;
      this.phase = 'gap';
      this.timer = setTimeout(() => this.playOnce(), gap * 1000);
      this.renderCounter();
    } else {
      this.finish();
    }
  }

  finish() {
    clearTimeout(this.timer);
    this.phase = 'done';
    if (settings.after === 'next' && this.pos < this.order.length - 1) {
      this.timer = setTimeout(() => this.go(this.pos + 1), 900);
    }
    this.renderCounter();
  }

  togglePlay() {
    const a = this.audio;
    if (this.phase === 'playing') {
      a.pause();
      this.phase = 'paused';
    } else if (this.phase === 'gap') {
      clearTimeout(this.timer);
      this.phase = 'paused';
    } else if (this.phase === 'paused' && a.currentTime > 0 && !a.ended) {
      this.phase = 'playing';
      a.play().catch(() => {});
    } else {
      if (this.phase === 'done') this.rep = 0;
      this.playOnce();
      return;
    }
    this.renderCounter();
  }

  restart() {
    clearTimeout(this.timer);
    this.audio.pause();
    this.rep = 0;
    this.playOnce();
  }

  go(p) {
    if (p < 0 || p >= this.order.length) return;
    clearTimeout(this.timer);
    this.audio.pause();
    this.pos = p;
    this.rep = 0;
    this.showKo = false;
    store.set('lcr.pos.' + this.id, this.cur().i);
    this.renderAll();
    this.playOnce();      // 클릭 이벤트 안에서 바로 재생해야 iOS에서도 소리가 난다
    this.preloadNext();
  }

  toggleLang() {
    this.showKo = !this.showKo;
    this.renderCard();
  }

  trim(which, delta) {
    const s = this.cur();
    if (which === 'start') s.start = round3(clamp(s.start + delta, 0, s.end - 0.3));
    else s.end = round3(clamp(s.end + delta, s.start + 0.3, this.lesson.duration));
    this.renderCard();
    api(`/api/lessons/${this.id}/sentences/${s.i}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ start: s.start, end: s.end }),
    }).catch(e => toast('구간 저장 실패: ' + e.message));
    this.playOnce();      // 바뀐 구간을 바로 들려준다
  }

  handleKey(e) {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.target.closest && e.target.closest('input, select, textarea')) return;
    switch (e.code) {
      case 'Space': e.preventDefault(); this.togglePlay(); break;
      case 'ArrowRight': e.preventDefault(); this.go(this.pos + 1); break;
      case 'ArrowLeft': e.preventDefault(); this.go(this.pos - 1); break;
      case 'KeyT': case 'Enter': e.preventDefault(); this.toggleLang(); break;
      case 'KeyR': this.restart(); break;
      default:
    }
  }

  setupMediaSession() {
    if (!('mediaSession' in navigator)) return;
    const ms = navigator.mediaSession;
    try {
      ms.metadata = new MediaMetadata({ title: this.lesson.title, artist: 'LC Repeater' });
      ms.setActionHandler('play', () => { if (this.phase !== 'playing') this.togglePlay(); });
      ms.setActionHandler('pause', () => { if (this.phase === 'playing' || this.phase === 'gap') this.togglePlay(); });
      ms.setActionHandler('nexttrack', () => this.go(this.pos + 1));
      ms.setActionHandler('previoustrack', () => this.go(this.pos - 1));
    } catch (e) { /* 지원하지 않는 동작은 건너뛴다 */ }
  }

  // ---- 번역 상태 ----

  async retranslate() {
    try {
      await api(`/api/lessons/${this.id}/translate`, { method: 'POST' });
      this.status = { stage: 'translate', label: '번역 중', progress: 0.75 };
      this.renderBanner();
      this.pollStatus();
    } catch (e) {
      toast('번역을 시작하지 못했어요: ' + e.message);
    }
  }

  async pollStatus() {
    clearTimeout(this.statusTimer);
    let data;
    try { data = await api('/api/lessons/' + this.id); } catch (e) { data = null; }
    if (this.dead) return;
    if (data) {
      this.status = data.status || {};
      if (this.status.stage === 'done' && data.lesson) {
        const byI = new Map(data.lesson.sentences.map(s => [s.i, s]));
        const keep = this.cur().i;
        this.S.forEach(s => {
          const n = byI.get(s.i);
          if (n) { s.en = n.en; s.ko = n.ko; s.kind = n.kind; }
        });
        this.computeOrder(keep);
        this.renderList();
        this.renderAll();
        if (!this.status.error) toast('번역이 끝났어요');
        return;
      }
      this.renderBanner();
    }
    this.statusTimer = setTimeout(() => this.pollStatus(), 1500);
  }

  // ---- 그리기 ----

  renderAll() {
    this.renderBanner();
    this.renderCard();
    this.renderCounter();
    this.highlightList();
  }

  renderBanner() {
    const st = this.status;
    const el = this.el.banner;
    this.el.exportPanel.style.display = st.stage === 'done' ? '' : 'none';
    this.el.exportLink.href = `/api/lessons/${this.id}/export`;
    if (st.stage === 'translate') {
      el.innerHTML = `<div class="banner busy"><span class="msg">번역하는 중… ${Math.round((st.progress || 0) * 100)}% · 그동안 영어로 먼저 들을 수 있어요</span></div>`;
    } else if (st.stage === 'done' && st.error) {
      el.innerHTML = `<div class="banner"><span class="msg">번역하지 못했어요: ${esc(st.error)}</span>
        <button class="btn" id="retranslate">번역 다시 하기</button></div>`;
      $('#retranslate', el).addEventListener('click', () => this.retranslate());
    } else {
      el.innerHTML = '';
    }
  }

  renderCard() {
    const el = this.el;
    const s = this.cur();
    el.pos.textContent = `${this.pos + 1} / ${this.order.length}`;
    el.lang.textContent = this.showKo ? 'KO' : 'EN';
    el.card.classList.toggle('ko', this.showKo);
    el.sentence.classList.remove('muted');
    if (!this.showKo) {
      el.sentence.innerHTML = esc(s.en) + (s.kind === 'direction' ? '<span class="tag-direction">안내</span>' : '');
    } else if (s.ko) {
      el.sentence.textContent = s.ko;
    } else {
      el.sentence.textContent = this.status.stage === 'translate' ? '번역하는 중이에요…' : '번역이 아직 없어요';
      el.sentence.classList.add('muted');
    }
    el.hint.textContent = this.showKo ? '탭하면 영어' : '탭하면 한국어';
    el.prev.disabled = this.pos <= 0;
    el.next.disabled = this.pos >= this.order.length - 1;
    el.range.textContent = `${fmtClock(s.start)} – ${fmtClock(s.end)} (${(s.end - s.start).toFixed(1)}초)`;
  }

  renderCounter() {
    const el = this.el;
    const total = settings.reps;
    const shown = this.phase === 'playing' ? this.rep + 1 : this.rep;
    el.count.innerHTML = `<b>${total ? Math.min(shown, total) : shown}</b> / ${total || '∞'}회`;
    el.bar.style.width = total ? `${Math.min(this.rep, total) / total * 100}%` : '0%';
    const nextSoon = this.phase === 'done' && settings.after === 'next' && this.pos < this.order.length - 1;
    el.phase.textContent = {
      idle: '재생을 눌러 시작',
      playing: '재생 중',
      gap: '잠깐 쉬는 중',
      paused: '일시정지',
      done: nextSoon ? '다 들었어요 · 다음 문장으로' : '다 들었어요',
    }[this.phase];
    const playing = this.phase === 'playing' || this.phase === 'gap';
    el.play.innerHTML = playing ? ICON.pause : ICON.play;
    el.play.title = playing ? '정지 (Space)' : '재생 (Space)';
  }

  renderList() {
    this.el.list.innerHTML = this.order.map((k, p) => {
      const s = this.S[k];
      return `<li data-p="${p}"${s.kind === 'direction' ? ' class="direction"' : ''}><span class="num">${p + 1}</span><span>${esc(s.en)}</span></li>`;
    }).join('');
    this.el.listCount.textContent = `${this.order.length}개`;
    this.highlightList();
  }

  highlightList() {
    const list = this.el.list;
    const prev = list.querySelector('li.active');
    if (prev) prev.classList.remove('active');
    const li = list.querySelector(`li[data-p="${this.pos}"]`);
    if (!li) return;
    li.classList.add('active');
    // 페이지 전체가 아니라 목록 안에서만 스크롤
    const top = li.offsetTop;
    if (top < list.scrollTop || top + li.offsetHeight > list.scrollTop + list.clientHeight) {
      list.scrollTop = top - list.clientHeight / 3;
    }
  }
}

route();
