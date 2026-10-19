#!/usr/bin/env python3
"""mp3 → 문장별 시간 + 한국어 번역(lesson.json)

    python3 pipeline.py 파일.mp3 [--title 제목] [--no-translate]

처리 순서
  1. ffmpeg로 재생용 master.wav(32kHz 모노)와 인식용 16kHz wav를 만든다.
  2. whisper.cpp로 받아쓰기(토큰별 DTW 시간 포함).
  3. 문장부호와 무음 구간으로 문장을 나누고, 경계를 무음 구간 안으로 맞춘다.
  4. `claude -p`로 문장 목록을 한 번에 번역한다.
"""
import argparse
import array
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import wave
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(ROOT, 'data')

MASTER_RATE = 32000
PAD_START = 0.12   # 문장 시작 앞 여유(초)
PAD_END = 0.20     # 문장 끝 뒤 여유(초)
DTW_LAG = 0.15     # DTW 토큰 시간이 실제 발음보다 늦는 정도(초)
MAX_SENTENCE_SEC = 10.0          # 이보다 긴 문장은 가장 긴 쉼에서 나눈다
UNPUNCTUATED_SPLIT_PAUSE = 0.33  # 문장부호 없이 받아쓴 구간은 이 이상 쉬는 곳에서 나눈다

TRANSLATE_CHUNK = 40
TRANSLATE_WORKERS = 3

ABBREVIATIONS = {
    'mr.', 'mrs.', 'ms.', 'dr.', 'st.', 'jr.', 'sr.', 'inc.', 'ltd.', 'co.',
    'corp.', 'vs.', 'etc.', 'a.m.', 'p.m.', 'e.g.', 'i.e.', 'no.', 'ave.',
    'dept.', 'mt.', 'u.s.', 'approx.',
}
CHOICE_LABEL = re.compile(r'^\(?[A-D][.)]?,?$')
SENTENCE_END = re.compile(r'[.?!]["\')\]]*$')

STAGES = {
    'queued': ('대기 중', 0.0, 0.0),
    'prepare': ('오디오 준비 중', 0.0, 0.05),
    'transcribe': ('음성 인식 중', 0.05, 0.70),
    'segment': ('문장 나누는 중', 0.70, 0.75),
    'translate': ('번역 중', 0.75, 1.0),
    'done': ('완료', 1.0, 1.0),
    'error': ('오류', 0.0, 0.0),
}


# ---------- 도구 경로 ----------

def find_bin(name, env_key):
    if os.environ.get(env_key):
        return os.environ[env_key]
    found = shutil.which(name)
    if found:
        return found
    # 앱/런처에서 실행하면 PATH에 Homebrew 경로가 빠져 있을 수 있다
    for d in ('/opt/homebrew/bin', '/usr/local/bin', os.path.expanduser('~/.local/bin')):
        p = os.path.join(d, name)
        if os.path.exists(p):
            return p
    return name


FFMPEG = find_bin('ffmpeg', 'FFMPEG_BIN')
WHISPER = find_bin('whisper-cli', 'WHISPER_BIN')
CLAUDE = find_bin('claude', 'CLAUDE_BIN')
WHISPER_MODEL = os.environ.get(
    'WHISPER_MODEL', os.path.join(ROOT, 'models', 'ggml-large-v3-turbo-q5_0.bin'))
CLAUDE_MODEL = os.environ.get('CLAUDE_MODEL', 'sonnet')


# ---------- 레슨 폴더와 상태 ----------

def lesson_dir(lesson_id):
    return os.path.join(DATA_DIR, lesson_id)


def new_lesson_id(filename):
    stem = os.path.splitext(os.path.basename(filename))[0]
    slug = re.sub(r'[^A-Za-z0-9]+', '-', stem).strip('-').lower()[:30]
    lid = time.strftime('%Y%m%d-%H%M%S')
    return lid + ('-' + slug if slug else '')


def write_json(path, obj):
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def read_json(path, default=None):
    try:
        with open(path, encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def set_status(d, stage, frac=0.0, error=None):
    label, lo, hi = STAGES[stage]
    write_json(os.path.join(d, 'status.json'), {
        'stage': stage,
        'label': label,
        'progress': round(lo + (hi - lo) * max(0.0, min(1.0, frac)), 3),
        'error': error,
        'updated': time.time(),
    })


# ---------- 1. 오디오 준비 ----------

def decode(src, dst, rate):
    subprocess.run(
        [FFMPEG, '-nostdin', '-loglevel', 'error', '-y', '-i', src,
         '-ac', '1', '-ar', str(rate), '-c:a', 'pcm_s16le', dst],
        check=True)


def wav_duration(path):
    with wave.open(path, 'rb') as w:
        return w.getnframes() / float(w.getframerate())


def detect_silences(path, min_dur=0.15):
    """무음 구간 [(시작, 끝), ...]. 기준 음량은 파일 평균 음량에서 정한다."""
    out = subprocess.run(
        [FFMPEG, '-nostdin', '-nostats', '-i', path, '-af', 'volumedetect', '-f', 'null', '-'],
        stderr=subprocess.PIPE, stdout=subprocess.DEVNULL, universal_newlines=True).stderr
    m = re.search(r'mean_volume:\s*(-?[\d.]+) dB', out)
    mean = float(m.group(1)) if m else -20.0
    noise = max(-50.0, min(-28.0, mean - 16.0))

    out = subprocess.run(
        [FFMPEG, '-nostdin', '-nostats', '-i', path,
         '-af', 'silencedetect=noise=%.1fdB:d=%.2f' % (noise, min_dur), '-f', 'null', '-'],
        stderr=subprocess.PIPE, stdout=subprocess.DEVNULL, universal_newlines=True).stderr
    silences, start = [], None
    for kind, val in re.findall(r'silence_(start|end): (-?[\d.]+)', out):
        if kind == 'start':
            start = max(0.0, float(val))
        elif start is not None:
            silences.append((start, float(val)))
            start = None
    if start is not None:
        silences.append((start, wav_duration(path)))
    return silences


# ---------- 2. 받아쓰기 ----------

def transcribe(wav16, out_prefix, on_progress=None):
    cmd = [WHISPER, '-m', WHISPER_MODEL, '-f', wav16, '-l', 'en',
           '-ojf', '-of', out_prefix, '-pp', '-sns',
           '-mc', '0',                 # 앞 문장 문맥을 끊어 보기 기호(A. B. C.) 환각을 막는다
           '-nfa', '-dtw', 'large.v3.turbo',
           '-t', str(min(8, os.cpu_count() or 4))]
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                            universal_newlines=True, bufsize=1)
    tail = []
    for line in proc.stderr:
        tail = (tail + [line])[-20:]
        m = re.search(r'progress\s*=\s*(\d+)%', line)
        if m and on_progress:
            on_progress(int(m.group(1)) / 100.0)
    if proc.wait() != 0:
        raise RuntimeError('whisper-cli 실패:\n' + ''.join(tail))
    with open(out_prefix + '.json', encoding='utf-8') as f:
        return json.load(f)


def extract_words(wjson):
    """토큰을 단어로 묶는다. t는 단어 시작 추정 시각(초)."""
    words = []
    for seg_no, seg in enumerate(wjson.get('transcription', [])):
        seg_from = seg['offsets']['from'] / 1000.0
        seg_to = seg['offsets']['to'] / 1000.0
        first = True
        for tok in seg.get('tokens', []):
            text = tok.get('text', '')
            if not text or text.startswith('[_') or text.startswith('<|'):
                continue
            if text.startswith(' ') or not words or first:
                if first:
                    t = seg_from          # 구간 시작 시각이 토큰 시각보다 정확하다
                elif tok.get('t_dtw', -1) >= 0:
                    t = tok['t_dtw'] / 100.0 - DTW_LAG
                else:
                    t = tok['offsets']['from'] / 1000.0
                if words and t < words[-1]['t']:
                    t = words[-1]['t']
                words.append({'raw': text, 't': t, 'seg': seg_no,
                              'first_in_seg': first, 'seg_to': seg_to})
                first = False
            else:
                words[-1]['raw'] += text
    for w in words:
        w['text'] = w['raw'].strip()
    return [w for w in words if w['text']]


# ---------- 3. 문장 나누기 ----------

def longest_pause(silences, t_from, t_to):
    """t_from 이후에 시작해서 t_to(+여유) 전에 끝나는 가장 긴 무음의 길이(초)"""
    best = 0.0
    for s, e in silences:
        if s >= t_from and e <= t_to + 0.3:
            best = max(best, e - s)
    return best


def silence_between(silences, t_from, t_to, min_len):
    return longest_pause(silences, t_from, t_to) >= min_len


def ends_sentence(cur, word, nxt):
    text = word['text']
    if not SENTENCE_END.search(text):
        return False
    if len(cur) == 1 and CHOICE_LABEL.match(text):
        return False                      # "A." 다음에 보기 문장이 이어진다
    low = text.lower().strip('"\')]')
    if low in ABBREVIATIONS:
        return nxt is None or nxt['first_in_seg']
    return True


def content_words(ws):
    return [w for w in ws if not (w is ws[0] and CHOICE_LABEL.match(w['text']))]


def is_unpunctuated(group):
    """Whisper가 가끔 문장부호·대문자 없이 받아쓰는 구간인가"""
    return len(group) >= 8 and not any(re.search(r'[.,?!;:]', w['text']) for w in group[:-1])


def split_long(group, silences):
    """문장부호로 못 나눈 덩어리를 쉼 길이로 나눈다.

    - 문장부호가 없으면: 0.33초 이상 쉬는 곳마다 자른다(문장 끝 쉼은 대개 이보다 길고 쉼표 자리는 짧다).
    - 문장부호가 있어도 MAX_SENTENCE_SEC를 넘으면: 가장 긴 쉼에서 자른다.
    양쪽 모두 3단어 이상이 되게 자른다.
    """
    if len(group) < 6:
        return [group]
    duration = group[-1]['t'] - group[0]['t'] + 0.5
    best = None
    for j in range(2, len(group) - 3):          # j번째 단어 뒤에서 자른다
        pause = longest_pause(silences, group[j]['t'], group[j + 1]['t'])
        if group[j]['text'].endswith(','):
            pause += 0.05
        balance = abs((j + 1) - (len(group) - j - 1)) / float(len(group))
        key = (round(pause, 2), -balance)
        if best is None or key > best[0]:
            best = (key, j, pause)
    if best is None:
        return [group]
    _, j, pause = best
    if (is_unpunctuated(group) and pause >= UNPUNCTUATED_SPLIT_PAUSE) or \
            (duration > MAX_SENTENCE_SEC and pause >= 0.12):
        return split_long(group[:j + 1], silences) + split_long(group[j + 1:], silences)
    return [group]


def split_sentences(words, silences):
    for w in words:
        for s, e in silences:
            # 추정 시각이 무음 안에 떨어진 단어는 무음이 끝나는 지점(실제 발화 시작)으로 옮긴다
            if s <= w['t'] < e - 0.01:
                w['t'] = e
                break
            # Whisper 구간 시작은 앞 발화 끝자락으로 잡힐 때가 있다. 바로 뒤에 쉼이 있으면 그 뒤가 시작이다
            if w['first_in_seg'] and w['t'] <= s <= w['t'] + 0.4 and e - s >= 0.3:
                w['t'] = e
                break
    groups, cur = [], []
    for i, w in enumerate(words):
        nxt = words[i + 1] if i + 1 < len(words) else None
        if cur:
            prev = cur[-1]
            long_pause = silence_between(silences, prev['t'], w['t'], 0.7)
            seg_pause = w['first_in_seg'] and silence_between(silences, prev['t'], w['t'], 0.4)
            if long_pause or seg_pause:
                groups.append(cur)
                cur = []
        cur.append(w)
        if ends_sentence(cur, w, nxt):
            groups.append(cur)
            cur = []
    if cur:
        groups.append(cur)
    groups = [part for g in groups for part in split_long(g, silences)]

    # 아주 짧은 문장은 다음 문장과 합친다
    #  - 2단어 이하("C. Yes.", "Of course."): 쉼 없이 이어질 때
    #  - 1단어("Yes.", "Sure."): 0.8초 미만으로 쉬고 이어질 때. 다음이 보기·문항 번호면 합치지 않는다
    merged, i = [], 0
    while i < len(groups):
        g = groups[i]
        nxt = groups[i + 1] if i + 1 < len(groups) else None
        merge = False
        if nxt:
            n_words = len(content_words(g))
            pause = longest_pause(silences, g[-1]['t'], nxt[0]['t'])
            starts_new_item = bool(CHOICE_LABEL.match(nxt[0]['text'])) or \
                nxt[0]['text'].lower().startswith(('number', 'question'))
            merge = (n_words <= 2 and pause < 0.35) or \
                (n_words <= 1 and pause < 0.8 and not starts_new_item)
        if merge:
            groups[i + 1] = g + nxt
        else:
            merged.append(g)
        i += 1
    return merged


def nearest_silence(silences, t, lo, hi, after=None):
    """끝나는 시각이 t(다음 발화 시작 추정)에 가장 가까운 무음. 길수록 우선."""
    best, best_score = None, None
    for s, e in silences:
        if e < t - lo or e > t + hi:
            continue
        if after is not None and s < after:
            continue
        score = abs(e - t) - 0.3 * min(e - s, 1.0)
        if best_score is None or score < best_score:
            best, best_score = (s, e), score
    return best


def place_boundaries(groups, silences, duration):
    sents = [{'start': g[0]['t'], 'end': None, 'words': g} for g in groups]
    for k, s in enumerate(sents):
        if k == 0:
            sil = nearest_silence(silences, s['start'], 0.8, 0.6)
            s['start'] = max(sil[1] - PAD_START, sil[0]) if sil else max(0.0, s['start'] - 0.2)
        if k + 1 < len(sents):
            nxt = sents[k + 1]
            t_est = nxt['words'][0]['t']
            sil = nearest_silence(silences, t_est, 0.8, 0.6, after=s['words'][0]['t'])
            if sil:
                mid = (sil[0] + sil[1]) / 2
                s['end'] = min(sil[0] + PAD_END, mid)
                nxt['start'] = max(sil[1] - PAD_START, mid)
            else:
                s['end'] = nxt['start'] = t_est   # 쉼 없이 이어지면 추정 시각에서 자른다
        else:
            last_t = s['words'][-1]['t']
            after = [x for x in silences if x[0] >= last_t]
            s['end'] = min(after[0][0] + PAD_END, after[0][1]) if after else duration
    out = []
    for i, s in enumerate(sents):
        start = round(max(0.0, s['start']), 3)
        end = round(min(duration, max(s['end'], s['start'] + 0.3)), 3)
        out.append({
            'i': i + 1,
            'start': start,
            'end': end,
            'en': ' '.join(w['text'] for w in s['words']),
            'ko': '',
            'kind': 'content',
        })
    return out


# ---------- 4. 번역 ----------

TRANSLATE_PROMPT = """아래는 토익 LC 음원을 음성 인식한 영어 문장 목록이다. 각 줄은 '번호<TAB>문장' 형식이다.
모든 문장에 대해 아래 필드를 가진 JSON 배열만 출력하라. 설명이나 코드블록 표시는 쓰지 마라.
- i: 번호 그대로
- en: 영어 문장. 음성 인식 오류가 명백할 때만 고친다(철자, 3.15 → 3:15 같은 시각 표기, 문맥상 어색한 단어). 보기 기호는 "A." 형태로 맞춘다. 그 외에는 그대로 둔다.
- ko: 자연스러운 한국어 번역. 보기 기호가 있으면 번역 앞에도 "A." 형태로 붙인다.
- kind: 시험 진행 안내(파트 설명, "Number 7.", "Look at the picture marked number 1 in your test book.", "Questions 32 through 34 refer to the following conversation." 등)는 "direction", 나머지는 "content"
형식: [{"i":1,"en":"...","ko":"...","kind":"content"}]"""


class NotLoggedIn(RuntimeError):
    pass


def _claude_env():
    env = dict(os.environ)
    if 'CLAUDECODE' in env:
        # Claude Code 세션 안에서 서버를 띄우면 그 세션 전용 설정이 자식 claude에 넘어가
        # 사용자 로그인을 못 읽는다. 일반 터미널에서 실행한 것처럼 지운다.
        for k in list(env):
            if k.startswith('CLAUDE') or k == 'ANTHROPIC_BASE_URL':
                del env[k]
    return env


def translate_chunk(chunk):
    lines = '\n'.join('%d\t%s' % (s['i'], s['en']) for s in chunk)
    last_err = None
    for _ in range(2):
        with tempfile.TemporaryDirectory() as tmp:
            proc = subprocess.run(
                [CLAUDE, '-p', TRANSLATE_PROMPT, '--output-format', 'json',
                 '--model', CLAUDE_MODEL, '--no-session-persistence'],
                input=lines, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                universal_newlines=True, cwd=tmp, env=_claude_env(), timeout=900)
        try:
            try:
                outer = json.loads(proc.stdout)
            except ValueError:
                raise RuntimeError((proc.stderr or proc.stdout).strip()[-500:]
                                   or 'claude 실행 실패 (코드 %d)' % proc.returncode)
            if outer.get('is_error') or proc.returncode != 0:
                msg = str(outer.get('result'))
                if 'Not logged in' in msg or '/login' in msg:
                    raise NotLoggedIn('claude CLI에 로그인되어 있지 않습니다. '
                                      '터미널에서 claude를 실행해 /login 한 뒤 "번역 다시 하기"를 누르세요.')
                raise RuntimeError(msg[:500])
            text = outer.get('result', '')
            items = json.loads(text[text.index('['):text.rindex(']') + 1])
            return {int(x['i']): x for x in items if 'i' in x}
        except NotLoggedIn:
            raise
        except (ValueError, KeyError, RuntimeError) as e:
            last_err = e
    raise RuntimeError('번역 실패: %s' % last_err)


def translate(sentences, on_progress=None):
    chunks = [sentences[i:i + TRANSLATE_CHUNK]
              for i in range(0, len(sentences), TRANSLATE_CHUNK)]
    done = [0]
    lock = threading.Lock()

    def work(chunk):
        result = translate_chunk(chunk)
        with lock:
            done[0] += 1
            if on_progress:
                on_progress(done[0] / float(len(chunks)))
        return result

    with ThreadPoolExecutor(TRANSLATE_WORKERS) as ex:
        results = list(ex.map(work, chunks))
    by_i = {}
    for r in results:
        by_i.update(r)
    for s in sentences:
        t = by_i.get(s['i'])
        if not t:
            continue
        s['ko'] = (t.get('ko') or '').strip()
        if (t.get('en') or '').strip():
            s['en'] = t['en'].strip()
        if t.get('kind') in ('content', 'direction'):
            s['kind'] = t['kind']


# ---------- 전체 처리 ----------

def find_source(d):
    for name in os.listdir(d):
        if name.startswith('source.'):
            return os.path.join(d, name)
    raise FileNotFoundError('source 파일이 없습니다: ' + d)


def process(lesson_id, title=None, do_translate=True, log=print):
    d = lesson_dir(lesson_id)
    meta = read_json(os.path.join(d, 'meta.json'), {}) or {}
    title = title or meta.get('title') or lesson_id
    try:
        set_status(d, 'prepare')
        src = find_source(d)
        master = os.path.join(d, 'master.wav')
        wav16 = os.path.join(d, 'whisper16k.wav')
        decode(src, master, MASTER_RATE)
        decode(src, wav16, 16000)
        duration = wav_duration(master)
        log('길이 %.1f초' % duration)

        set_status(d, 'transcribe')
        t0 = time.time()
        wjson = transcribe(wav16, os.path.join(d, 'whisper'),
                           lambda f: set_status(d, 'transcribe', f))
        os.remove(wav16)
        log('음성 인식 %.1f초' % (time.time() - t0))

        sentences = segment_lesson(lesson_id, wjson, title, meta, log)
    except Exception as e:  # 상태 파일에 남겨 화면에서 보이게 한다
        set_status(d, 'error', error=str(e)[-800:])
        raise
    if do_translate and sentences:
        translate_lesson(lesson_id, log)
    else:
        set_status(d, 'done')
    return read_json(os.path.join(d, 'lesson.json'))


def segment_lesson(lesson_id, wjson, title, meta, log=print):
    d = lesson_dir(lesson_id)
    set_status(d, 'segment')
    master = os.path.join(d, 'master.wav')
    duration = wav_duration(master)
    silences = detect_silences(master)
    words = extract_words(wjson)
    sentences = place_boundaries(split_sentences(words, silences), silences, duration)
    lesson = {'id': lesson_id, 'title': title, 'duration': round(duration, 3),
              'created': meta.get('created', time.time()), 'sentences': sentences}
    write_json(os.path.join(d, 'lesson.json'), lesson)
    log('문장 %d개' % len(sentences))
    return sentences


def resegment(lesson_id, do_translate=True, log=print):
    """받아쓰기(whisper.json)는 그대로 두고 문장 나누기와 번역만 다시 한다."""
    d = lesson_dir(lesson_id)
    meta = read_json(os.path.join(d, 'meta.json'), {}) or {}
    old = read_json(os.path.join(d, 'lesson.json'), {}) or {}
    title = old.get('title') or meta.get('title') or lesson_id
    try:
        with open(os.path.join(d, 'whisper.json'), encoding='utf-8') as f:
            wjson = json.load(f)
        sentences = segment_lesson(lesson_id, wjson, title, meta, log)
    except Exception as e:
        set_status(d, 'error', error=str(e)[-800:])
        raise
    if do_translate and sentences:
        translate_lesson(lesson_id, log)
    else:
        set_status(d, 'done')
    return read_json(os.path.join(d, 'lesson.json'))


def translate_lesson(lesson_id, log=print):
    """번역만 (다시) 한다. 실패해도 문장 반복은 쓸 수 있게 'done' + 경고로 남긴다."""
    d = lesson_dir(lesson_id)
    path = os.path.join(d, 'lesson.json')
    lesson = read_json(path)
    set_status(d, 'translate')
    t0 = time.time()
    try:
        translate(lesson['sentences'], lambda f: set_status(d, 'translate', f))
    except Exception as e:
        set_status(d, 'done', error=str(e)[-800:])
        log('번역 실패: %s' % e)
        return False
    write_json(path, lesson)
    set_status(d, 'done')
    log('번역 %.1f초' % (time.time() - t0))
    return True


def import_file(path, title=None):
    """mp3를 data/<id>/source.<ext>로 복사하고 id를 돌려준다."""
    lesson_id = new_lesson_id(path)
    d = lesson_dir(lesson_id)
    os.makedirs(d)
    ext = os.path.splitext(path)[1].lower() or '.mp3'
    shutil.copyfile(path, os.path.join(d, 'source' + ext))
    write_json(os.path.join(d, 'meta.json'), {
        'title': title or os.path.splitext(os.path.basename(path))[0],
        'created': time.time()})
    set_status(d, 'queued')
    return lesson_id


# ---------- 재생 구간 잘라내기 ----------

def read_clip(lesson_id, start, end, fade=0.006):
    """master.wav에서 [start, end] 구간을 잘라 WAV 바이트로 돌려준다(양끝 짧은 페이드)."""
    with wave.open(os.path.join(lesson_dir(lesson_id), 'master.wav'), 'rb') as w:
        rate = w.getframerate()
        total = w.getnframes()
        a = max(0, min(total, int(round(start * rate))))
        b = max(a, min(total, int(round(end * rate))))
        w.setpos(a)
        frames = w.readframes(b - a)
    samples = array.array('h')
    samples.frombytes(frames)
    if sys.byteorder == 'big':
        samples.byteswap()
    n = min(int(fade * rate), len(samples) // 2)
    for k in range(n):
        g = k / float(n)
        samples[k] = int(samples[k] * g)
        samples[-1 - k] = int(samples[-1 - k] * g)
    if sys.byteorder == 'big':
        samples.byteswap()
    buf = io.BytesIO()
    with wave.open(buf, 'wb') as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(rate)
        out.writeframes(samples.tobytes())
    return buf.getvalue()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('audio', nargs='?')
    ap.add_argument('--title')
    ap.add_argument('--no-translate', action='store_true')
    ap.add_argument('--retranslate', metavar='LESSON_ID', help='이미 처리한 레슨의 번역만 다시')
    ap.add_argument('--resegment', metavar='LESSON_ID', help='받아쓰기는 그대로 두고 문장 나누기와 번역을 다시')
    args = ap.parse_args()
    if args.resegment:
        lesson_id = args.resegment
        lesson = resegment(lesson_id, do_translate=not args.no_translate)
    elif args.retranslate:
        lesson_id = args.retranslate
        translate_lesson(lesson_id)
        lesson = read_json(os.path.join(lesson_dir(lesson_id), 'lesson.json'))
    elif args.audio:
        lesson_id = import_file(args.audio, args.title)
        print('레슨 id:', lesson_id)
        lesson = process(lesson_id, do_translate=not args.no_translate)
    else:
        ap.error('mp3 경로나 --retranslate LESSON_ID 가 필요합니다')
    for s in lesson['sentences']:
        print('%3d %7.2f-%7.2f %-9s %s' % (s['i'], s['start'], s['end'], s['kind'], s['en']))
        if s['ko']:
            print('%28s %s' % ('', s['ko']))


if __name__ == '__main__':
    main()
