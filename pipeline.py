#!/usr/bin/env python3
"""mp3 → 문장별 시간 + 한국어 번역(lesson.json)

    python3 pipeline.py 파일.mp3 [--lang en|ja] [--title 제목] [--no-translate]

처리 순서
  1. 맥 내장 afconvert로 재생용 master.wav(32kHz 모노)와 인식용 16kHz wav를 만든다.
  2. whisper.cpp로 받아쓰기(토큰별 DTW 시간 포함).
  3. 문장부호와 무음 구간으로 문장을 나누고, 경계를 무음 구간 안으로 맞춘다.
  4. `claude -p`로 문장 목록을 한 번에 번역한다.
"""
import argparse
import array
import io
import json
import math
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
from desktop_runtime import child_process_options

ROOT = os.path.dirname(os.path.abspath(__file__))
# PyInstaller로 묶은 앱이면 함께 넣은 파일(static/, bin/)은 여기에 있다
BUNDLE_DIR = getattr(sys, '_MEIPASS', ROOT)
DATA_DIR = os.environ.get('LCR_DATA_DIR') or os.path.join(ROOT, 'data')

MODEL_NAME = 'ggml-large-v3-turbo-q5_0.bin'
MODEL_URL = os.environ.get('LCR_MODEL_URL') or \
    'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/' + MODEL_NAME

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
SENTENCE_END_CJK = re.compile(r'[。．？！?!][」』"\')\]）]*$')
CJK_PUNCT = re.compile(r'[、。，．？！?!,.;:「」『』（）()\s]')
CJK_ITEM_START = re.compile(r'^\s*([0-9０-９一二三四五六七八九十]+\s*番|問題)')

# 원문 언어. 레슨의 'lang'(없으면 en). 문장 필드 이름은 호환을 위해 원문 'en', 번역 'ko'를 그대로 쓴다.
LANGS = {
    'en': {'name': '영어', 'cjk': False},
    'ja': {'name': '일본어', 'cjk': True},
}
DEFAULT_LANG = 'en'

# 문장 나누기 기준. 영어는 단어 수, 일본어(띄어쓰기 없음)는 문장부호를 뺀 글자 수로 센다.
SEGMENT_RULES = {
    False: {'min_split': 6, 'min_side': 3, 'unpunctuated': 8, 'short': 2, 'tiny': 1},
    True: {'min_split': 10, 'min_side': 5, 'unpunctuated': 16, 'short': 4, 'tiny': 2},
}


def lang_of(obj):
    """레슨·메타 정보의 언어 코드. 없거나 모르는 값이면 영어(예전 레슨)."""
    lang = (obj or {}).get('lang')
    return lang if lang in LANGS else DEFAULT_LANG

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

def find_bin(name, env_key, login_shell=False):
    """실행 파일 경로. 없으면 None.

    Finder에서 연 앱은 PATH가 /usr/bin:/bin 정도라 Homebrew 경로를 따로 보고,
    그래도 없으면 로그인 셸에게 물어본다(npm·nvm 등으로 설치한 claude).
    """
    if os.environ.get(env_key):
        return os.environ[env_key]
    if sys.platform == 'win32':
        # Native Claude installs here; npm shims are resolved below if necessary.
        for directory in (os.path.expanduser('~/.local/bin'),):
            p = os.path.join(directory, name + '.exe')
            if os.path.isfile(p):
                return p
        return shutil.which(name + '.exe') or shutil.which(name)
    found = shutil.which(name)
    if found:
        return found
    for d in ('/opt/homebrew/bin', '/usr/local/bin', os.path.expanduser('~/.local/bin')):
        p = os.path.join(d, name)
        if os.path.exists(p):
            return p
    if login_shell:
        shell = os.environ.get('SHELL') or '/bin/zsh'
        try:
            out = subprocess.run([shell, '-ilc', 'command -v ' + name],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, universal_newlines=True, timeout=8).stdout
            for line in reversed(out.splitlines()):
                line = line.strip()
                if line.startswith('/') and os.path.exists(line):
                    return line
        except (OSError, subprocess.SubprocessError):
            pass
    return None


def bundled_bin(name):
    p = os.path.join(BUNDLE_DIR, 'bin', name + ('.exe' if sys.platform == 'win32' else ''))
    return p if os.path.exists(p) else None


AFCONVERT = find_bin('afconvert', 'AFCONVERT_BIN')
FFMPEG = os.environ.get('FFMPEG_BIN') or bundled_bin('ffmpeg') or find_bin('ffmpeg', 'FFMPEG_BIN')
WHISPER = os.environ.get('WHISPER_BIN') or bundled_bin('whisper-cli') or find_bin('whisper-cli', 'WHISPER_BIN')
WHISPER_MODEL = os.environ.get('WHISPER_MODEL') or os.path.join(ROOT, 'models', MODEL_NAME)
CLAUDE_MODEL = os.environ.get('CLAUDE_MODEL', 'sonnet')
_claude = []


def claude_bin():
    """claude CLI 경로(처음 한 번만 찾는다). 없으면 None."""
    if not _claude:
        _claude.append(find_bin('claude', 'CLAUDE_BIN', login_shell=True))
    return _claude[0]


def claude_command(path):
    if sys.platform == 'win32' and os.path.splitext(path)[1].lower() in ('.cmd', '.bat'):
        # Invoke the npm JavaScript entry point directly: cmd.exe would reinterpret
        # quotes/metacharacters in the translation prompt passed as an argument.
        entry = os.path.join(os.path.dirname(path), 'node_modules', '@anthropic-ai', 'claude-code', 'cli.js')
        node = shutil.which('node.exe')
        if not node or not os.path.isfile(entry):
            raise NotLoggedIn('Claude Code 네이티브 Windows 버전을 설치하고 로그인해 주세요.')
        return [node, entry]
    return [path]


def configure(data_dir=None, model_path=None):
    """앱에서 데이터·모델 위치를 바꿀 때 쓴다."""
    global DATA_DIR, WHISPER_MODEL
    if data_dir:
        DATA_DIR = data_dir
    if model_path:
        WHISPER_MODEL = model_path


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
    """오디오를 16비트 모노 WAV로. 맥 내장 afconvert를 쓰고, 못 읽는 형식(ogg 등)만 ffmpeg로."""
    if AFCONVERT:
        proc = subprocess.run([AFCONVERT, '-f', 'WAVE', '-d', 'LEI16@%d' % rate, '-c', '1', src, dst],
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              encoding='utf-8', errors='replace', **child_process_options())
        if proc.returncode == 0:
            return
        if not FFMPEG:
            raise RuntimeError('이 오디오 형식은 읽을 수 없습니다(mp3, m4a, wav를 써 주세요): '
                               + proc.stdout.strip()[-300:])
    if not FFMPEG:
        raise RuntimeError('오디오 변환 도구(afconvert 또는 ffmpeg)가 없습니다')
    proc = subprocess.run(
        [FFMPEG, '-nostdin', '-loglevel', 'error', '-y', '-i', src,
         '-ac', '1', '-ar', str(rate), '-c:a', 'pcm_s16le', dst],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        encoding='utf-8', errors='replace', **child_process_options())
    if proc.returncode:
        raise RuntimeError('오디오 변환 실패: ' + proc.stdout.strip()[-500:])


def wav_duration(path):
    with wave.open(path, 'rb') as w:
        return w.getnframes() / float(w.getframerate())


def detect_silences(path, min_dur=0.15, window=0.01):
    """무음 구간 [(시작, 끝), ...].

    10ms 창마다 최대 진폭을 보고, 기준 음량보다 작은 창이 min_dur 이상 이어지면 무음으로 본다.
    기준 음량은 파일 평균 음량(RMS)보다 16dB 낮게 잡는다(-50~-28dB 사이).
    """
    with wave.open(path, 'rb') as w:
        rate = w.getframerate()
        samples = array.array('h')
        samples.frombytes(w.readframes(w.getnframes()))
    if sys.byteorder == 'big':
        samples.byteswap()
    if not samples:
        return []

    step = 8   # 평균 음량은 솎아서 계산해도 충분하다
    sub = samples[::step]
    mean_sq = sum(x * x for x in sub) / float(len(sub))
    mean_db = 10 * math.log10(mean_sq / 32768.0 ** 2) if mean_sq > 0 else -90.0
    noise_db = max(-50.0, min(-28.0, mean_db - 16.0))
    limit = 32768.0 * 10 ** (noise_db / 20.0)

    win = max(1, int(rate * window))
    need = int(round(min_dur / window))
    silences, run_start = [], None
    n_win = (len(samples) + win - 1) // win
    for k in range(n_win):
        chunk = samples[k * win:(k + 1) * win]
        quiet = max(max(chunk), -min(chunk)) < limit
        if quiet and run_start is None:
            run_start = k
        elif not quiet and run_start is not None:
            if k - run_start >= need:
                silences.append((run_start * window, k * window))
            run_start = None
    if run_start is not None and n_win - run_start >= need:
        silences.append((run_start * window, len(samples) / float(rate)))
    return [(round(s, 3), round(e, 3)) for s, e in silences]


# ---------- 2. 받아쓰기 ----------

def transcribe(wav16, out_prefix, on_progress=None, lang=DEFAULT_LANG):
    if not WHISPER:
        raise RuntimeError('whisper-cli를 찾을 수 없습니다. 앱을 다시 설치하거나 WHISPER_BIN을 설정해 주세요.')
    if not os.path.isfile(WHISPER_MODEL):
        raise RuntimeError('Whisper 모델이 없습니다: ' + WHISPER_MODEL)
    cmd = [WHISPER, '-m', WHISPER_MODEL, '-f', wav16, '-l', lang,
           '-ojf', '-of', out_prefix, '-pp', '-sns',
           '-mc', '0',                 # 앞 문장 문맥을 끊어 보기 기호(A. B. C.) 환각을 막는다
           '-nfa', '-dtw', 'large.v3.turbo',
           '-t', str(min(8, os.cpu_count() or 4))]
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                            stdin=subprocess.DEVNULL, encoding='utf-8', errors='replace', bufsize=1,
                            **child_process_options())
    tail = []
    for line in proc.stderr:
        tail = (tail + [line])[-20:]
        m = re.search(r'progress\s*=\s*(\d+)%', line)
        if m and on_progress:
            on_progress(int(m.group(1)) / 100.0)
    if proc.wait() != 0:
        raise RuntimeError('whisper-cli 실패:\n' + ''.join(tail))
    return load_whisper_json(out_prefix + '.json')


def load_whisper_json(path):
    """whisper.cpp는 토큰을 바이트 단위로 써서 한 글자가 여러 토큰에 걸치면 UTF-8이 깨진다(일본어 등).
    깨진 바이트를 그대로 들고 읽었다가 토큰을 합친 뒤 extract_words에서 되살린다."""
    with open(path, 'rb') as f:
        return json.loads(f.read().decode('utf-8', 'surrogateescape'))


def _utf8(raw, errors='strict'):
    return raw.encode('utf-8', 'surrogateescape').decode('utf-8', errors)


def _complete(raw):
    try:
        _utf8(raw)
        return True
    except UnicodeError:
        return False


def extract_words(wjson, lang=DEFAULT_LANG):
    """토큰을 단어로 묶는다. t는 단어 시작 추정 시각(초).

    영어는 공백으로 시작하는 토큰에서 새 단어를 시작한다. 일본어는 띄어쓰기가 없어서
    토큰마다 따로 두되, 글자가 덜 끝난(UTF-8이 잘린) 토큰은 다음 토큰과 합친다.
    """
    cjk = LANGS[lang]['cjk']
    words = []
    for seg_no, seg in enumerate(wjson.get('transcription', [])):
        seg_from = seg['offsets']['from'] / 1000.0
        seg_to = seg['offsets']['to'] / 1000.0
        first = True
        for tok in seg.get('tokens', []):
            text = tok.get('text', '')
            if not text or text.startswith('[_') or text.startswith('<|'):
                continue
            if cjk:
                new_word = first or not words or _complete(words[-1]['raw'])
            else:
                new_word = text.startswith(' ') or not words or first
            if new_word:
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
        w['raw'] = _utf8(w['raw'], 'replace')
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


def unit_len(w, cjk):
    return len(CJK_PUNCT.sub('', w['text'])) if cjk else 1


def group_len(ws, cjk):
    return sum(unit_len(w, cjk) for w in ws)


def group_text(ws, cjk):
    return ''.join(w['raw'] for w in ws).strip() if cjk else ' '.join(w['text'] for w in ws)


def ends_sentence(cur, word, nxt, cjk=False):
    text = word['text']
    if cjk:
        return bool(SENTENCE_END_CJK.search(text))
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


def is_unpunctuated(group, cjk=False):
    """Whisper가 가끔 문장부호·대문자 없이 받아쓰는 구간인가"""
    marks = r'[、。，．？！?!,.;:]' if cjk else r'[.,?!;:]'
    return group_len(group, cjk) >= SEGMENT_RULES[cjk]['unpunctuated'] and \
        not any(re.search(marks, w['text']) for w in group[:-1])


def split_long(group, silences, cjk=False):
    """문장부호로 못 나눈 덩어리를 쉼 길이로 나눈다.

    - 문장부호가 없으면: 0.33초 이상 쉬는 곳마다 자른다(문장 끝 쉼은 대개 이보다 길고 쉼표 자리는 짧다).
    - 문장부호가 있어도 MAX_SENTENCE_SEC를 넘으면: 가장 긴 쉼에서 자른다.
    양쪽 모두 3단어(일본어는 5글자) 이상이 되게 자른다.
    """
    rules = SEGMENT_RULES[cjk]
    lens = [unit_len(w, cjk) for w in group]
    total = sum(lens)
    if total < rules['min_split']:
        return [group]
    duration = group[-1]['t'] - group[0]['t'] + 0.5
    best = None
    left = 0
    for j in range(len(group) - 1):             # j번째 단어 뒤에서 자른다
        left += lens[j]
        right = total - left
        if left < rules['min_side'] or right < rules['min_side']:
            continue
        pause = longest_pause(silences, group[j]['t'], group[j + 1]['t'])
        if group[j]['text'].endswith((',', '、', '，')):
            pause += 0.05
        balance = abs(left - right) / float(total)
        key = (round(pause, 2), -balance)
        if best is None or key > best[0]:
            best = (key, j, pause)
    if best is None:
        return [group]
    _, j, pause = best
    if (is_unpunctuated(group, cjk) and pause >= UNPUNCTUATED_SPLIT_PAUSE) or \
            (duration > MAX_SENTENCE_SEC and pause >= 0.12):
        return split_long(group[:j + 1], silences, cjk) + split_long(group[j + 1:], silences, cjk)
    return [group]


def split_sentences(words, silences, lang=DEFAULT_LANG):
    cjk = LANGS[lang]['cjk']
    rules = SEGMENT_RULES[cjk]
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
        if ends_sentence(cur, w, nxt, cjk):
            groups.append(cur)
            cur = []
    if cur:
        groups.append(cur)
    groups = [part for g in groups for part in split_long(g, silences, cjk)]

    # 아주 짧은 문장은 다음 문장과 합친다
    #  - 2단어 이하("C. Yes.", "Of course.") · 일본어 4글자 이하: 쉼 없이 이어질 때
    #  - 1단어("Yes.", "Sure.") · 일본어 2글자 이하("はい。"): 0.8초 미만으로 쉬고 이어질 때.
    #    다음이 보기·문항 번호면 합치지 않는다
    merged, i = [], 0
    while i < len(groups):
        g = groups[i]
        nxt = groups[i + 1] if i + 1 < len(groups) else None
        merge = False
        if nxt:
            pause = longest_pause(silences, g[-1]['t'], nxt[0]['t'])
            if cjk:
                size = group_len(g, cjk)
                starts_new_item = bool(CJK_ITEM_START.match(group_text(nxt[:6], cjk)))
            else:
                size = len(content_words(g))
                starts_new_item = bool(CHOICE_LABEL.match(nxt[0]['text'])) or \
                    nxt[0]['text'].lower().startswith(('number', 'question'))
            merge = (size <= rules['short'] and pause < 0.35) or \
                (size <= rules['tiny'] and pause < 0.8 and not starts_new_item)
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


def place_boundaries(groups, silences, duration, lang=DEFAULT_LANG):
    cjk = LANGS[lang]['cjk']
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
            'en': group_text(s['words'], cjk),   # 원문(일본어 레슨이면 일본어)
            'ko': '',
            'kind': 'content',
        })
    return out


# ---------- 4. 번역 ----------

TRANSLATE_PROMPT_EN = """아래는 토익 LC 음원을 음성 인식한 영어 문장 목록이다. 각 줄은 '번호<TAB>문장' 형식이다.
모든 문장에 대해 아래 필드를 가진 JSON 배열만 출력하라. 설명이나 코드블록 표시는 쓰지 마라.
- i: 번호 그대로
- en: 영어 문장. 음성 인식 오류가 명백할 때만 고친다(철자, 3.15 → 3:15 같은 시각 표기, 문맥상 어색한 단어). 보기 기호는 "A." 형태로 맞춘다. 그 외에는 그대로 둔다.
- ko: 자연스러운 한국어 번역. 보기 기호가 있으면 번역 앞에도 "A." 형태로 붙인다.
- kind: 시험 진행 안내(파트 설명, "Number 7.", "Look at the picture marked number 1 in your test book.", "Questions 32 through 34 refer to the following conversation." 등)는 "direction", 나머지는 "content"
형식: [{"i":1,"en":"...","ko":"...","kind":"content"}]"""

TRANSLATE_PROMPT_JA = """아래는 일본어 듣기 음원(JLPT 청해 등)을 음성 인식한 일본어 문장 목록이다. 각 줄은 '번호<TAB>문장' 형식이다.
모든 문장에 대해 아래 필드를 가진 JSON 배열만 출력하라. 설명이나 코드블록 표시는 쓰지 마라.
- i: 번호 그대로
- ja: 일본어 문장. 음성 인식 오류가 명백할 때만 고친다(잘못 변환된 한자, 문맥상 어색한 단어, 빠진 「。」「、」). 그 외에는 그대로 두고, 띄어쓰기를 새로 넣지 않는다.
- ko: 자연스러운 한국어 번역.
- kind: 시험 진행 안내(「1番」, 「問題1」, 「まず質問を聞いてください。」, 「それから話を聞いて、問題用紙の1から4の中から、最もよいものを一つ選んでください。」 등)는 "direction", 나머지는 "content"
형식: [{"i":1,"ja":"...","ko":"...","kind":"content"}]"""

# 언어별 (번역 지시문, 응답에서 원문을 담는 키)
TRANSLATE_PROMPTS = {'en': (TRANSLATE_PROMPT_EN, 'en'), 'ja': (TRANSLATE_PROMPT_JA, 'ja')}


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


def translate_chunk(chunk, lang=DEFAULT_LANG):
    claude = claude_bin()
    if not claude:
        raise NotLoggedIn('claude CLI를 찾을 수 없습니다. Claude Code를 설치하고 터미널에서 '
                          'claude를 실행해 /login 한 뒤 "번역 다시 하기"를 누르세요.')
    prompt = TRANSLATE_PROMPTS[lang][0]
    lines = '\n'.join('%d\t%s' % (s['i'], s['en']) for s in chunk)
    last_err = None
    for _ in range(2):
        with tempfile.TemporaryDirectory() as tmp:
            proc = subprocess.run(
                claude_command(claude) + ['-p', prompt, '--output-format', 'json',
                 '--model', CLAUDE_MODEL, '--no-session-persistence'],
                input=lines, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                encoding='utf-8', errors='replace', cwd=tmp, env=_claude_env(), timeout=900,
                **child_process_options())
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


def translate(sentences, on_progress=None, lang=DEFAULT_LANG):
    source_key = TRANSLATE_PROMPTS[lang][1]
    chunks = [sentences[i:i + TRANSLATE_CHUNK]
              for i in range(0, len(sentences), TRANSLATE_CHUNK)]
    done = [0]
    lock = threading.Lock()

    def work(chunk):
        result = translate_chunk(chunk, lang)
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
        if (t.get(source_key) or '').strip():
            s['en'] = t[source_key].strip()
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
                           lambda f: set_status(d, 'transcribe', f), lang_of(meta))
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


def segment_lesson(lesson_id, wjson, title, meta, log=print, lang=None):
    d = lesson_dir(lesson_id)
    lang = lang or lang_of(meta)
    set_status(d, 'segment')
    master = os.path.join(d, 'master.wav')
    duration = wav_duration(master)
    silences = detect_silences(master)
    words = extract_words(wjson, lang)
    sentences = place_boundaries(split_sentences(words, silences, lang), silences, duration, lang)
    lesson = {'id': lesson_id, 'title': title, 'lang': lang, 'duration': round(duration, 3),
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
        wjson = load_whisper_json(os.path.join(d, 'whisper.json'))
        lang = old.get('lang') if old.get('lang') in LANGS else lang_of(meta)
        sentences = segment_lesson(lesson_id, wjson, title, meta, log, lang)
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
        translate(lesson['sentences'], lambda f: set_status(d, 'translate', f), lang_of(lesson))
    except Exception as e:
        set_status(d, 'done', error=str(e)[-800:])
        log('번역 실패: %s' % e)
        return False
    write_json(path, lesson)
    set_status(d, 'done')
    log('번역 %.1f초' % (time.time() - t0))
    return True


def import_file(path, title=None, lang=DEFAULT_LANG):
    """mp3를 data/<id>/source.<ext>로 복사하고 id를 돌려준다."""
    if lang not in LANGS:
        raise ValueError('지원하지 않는 언어입니다: %s' % lang)
    lesson_id = new_lesson_id(path)
    d = lesson_dir(lesson_id)
    os.makedirs(d)
    ext = os.path.splitext(path)[1].lower() or '.mp3'
    shutil.copyfile(path, os.path.join(d, 'source' + ext))
    write_json(os.path.join(d, 'meta.json'), {
        'title': title or os.path.splitext(os.path.basename(path))[0],
        'lang': lang, 'created': time.time()})
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
    ap.add_argument('--lang', choices=sorted(LANGS), default=DEFAULT_LANG, help='음원 언어 (기본 en)')
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
        lesson_id = import_file(args.audio, args.title, args.lang)
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
