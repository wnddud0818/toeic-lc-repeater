"""Japanese transcription → sentences, without whisper or claude."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import pipeline as P


def token_json(text_bytes, t):
    # whisper.cpp writes token bytes as-is, even when a token ends mid-character.
    return b'{"text": "' + text_bytes + b'", "offsets": {"from": %d}, "t_dtw": %d}' % (t * 1000, t * 100 + 15)


def whisper_file(folder, segments):
    parts = []
    for start, end, tokens in segments:
        toks = b', '.join(token_json(b, t) for b, t in tokens)
        parts.append(b'{"offsets": {"from": %d, "to": %d}, "tokens": [%s]}' % (start * 1000, end * 1000, toks))
    path = Path(folder) / 'whisper.json'
    path.write_bytes(b'{"transcription": [' + b', '.join(parts) + b']}')
    return path


class JapanesePipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)

    def load(self, segments):
        return P.load_whisper_json(whisper_file(self.temp.name, segments))

    def test_split_utf8_tokens_are_rejoined_without_spaces(self):
        gi = '議'.encode('utf-8')
        wjson = self.load([(0, 3, [
            ('会'.encode(), 0.0), (gi[:2], 0.3), (gi[2:] + 'は'.encode(), 0.4),
            ('三時'.encode(), 0.8), ('からです。'.encode(), 1.2),
        ])])
        words = P.extract_words(wjson, 'ja')
        self.assertEqual([w['text'] for w in words], ['会', '議は', '三時', 'からです。'])
        sentences = P.place_boundaries(P.split_sentences(words, [], 'ja'), [], 3.0, 'ja')
        self.assertEqual([s['en'] for s in sentences], ['会議は三時からです。'])

    def test_japanese_punctuation_ends_sentences_and_short_replies_merge(self):
        wjson = self.load([(0, 6, [
            ('すみません、'.encode(), 0.0), ('駅は'.encode(), 0.6), ('どこですか？'.encode(), 1.0),
            ('はい。'.encode(), 2.0), ('まっすぐ'.encode(), 2.3), ('行ってください。'.encode(), 2.8),
        ])])
        words = P.extract_words(wjson, 'ja')
        sentences = P.place_boundaries(P.split_sentences(words, [], 'ja'), [], 6.0, 'ja')
        self.assertEqual([s['en'] for s in sentences],
                         ['すみません、駅はどこですか？', 'はい。まっすぐ行ってください。'])

    def test_item_number_is_not_merged_into_previous_reply(self):
        wjson = self.load([(0, 4, [('はい。'.encode(), 0.0), ('2番'.encode(), 1.0), ('。'.encode(), 1.3)])])
        silences = [(0.5, 0.9)]
        sentences = P.place_boundaries(P.split_sentences(P.extract_words(wjson, 'ja'), silences, 'ja'),
                                       silences, 4.0, 'ja')
        self.assertEqual([s['en'] for s in sentences], ['はい。', '2番。'])

    def test_long_unpunctuated_japanese_splits_at_pauses(self):
        chunk = 'きょうはかいぎがあります'
        tokens = [(c.encode(), 0.2 * k) for k, c in enumerate(chunk * 2)]
        wjson = self.load([(0, 6, tokens)])
        pause_at = 0.2 * len(chunk) - 0.05
        silences = [(pause_at, pause_at + 0.4)]
        words = P.extract_words(wjson, 'ja')
        sentences = P.split_sentences(words, silences, 'ja')
        self.assertEqual([P.group_text(g, True) for g in sentences], [chunk, chunk])

    def test_english_lessons_keep_spaces(self):
        wjson = self.load([(0, 2, [(b' Hello,', 0.0), (b' world.', 0.5)])])
        sentences = P.place_boundaries(P.split_sentences(P.extract_words(wjson), []), [], 2.0)
        self.assertEqual([s['en'] for s in sentences], ['Hello, world.'])

    def test_language_is_recorded_and_old_lessons_default_to_english(self):
        self.assertEqual(P.lang_of({}), 'en')
        self.assertEqual(P.lang_of({'lang': 'ja'}), 'ja')
        self.assertEqual(P.lang_of({'lang': 'xx'}), 'en')
        audio = Path(self.temp.name) / 'a.mp3'
        audio.write_bytes(b'x')
        old = P.DATA_DIR
        P.configure(data_dir=self.temp.name)
        try:
            lid = P.import_file(str(audio), lang='ja')
            meta = json.loads((Path(P.lesson_dir(lid)) / 'meta.json').read_text(encoding='utf-8'))
            self.assertEqual(meta['lang'], 'ja')
            with self.assertRaises(ValueError):
                P.import_file(str(audio), lang='fr')
        finally:
            P.DATA_DIR = old

    def test_translation_uses_japanese_prompt_and_reads_corrected_japanese(self):
        sentences = [{'i': 1, 'en': '会議わ三時です', 'ko': '', 'kind': 'content'}]
        calls = []

        def fake(chunk, lang):
            calls.append(lang)
            return {1: {'i': 1, 'ja': '会議は三時です。', 'en': 'ignored', 'ko': '회의는 3시입니다.', 'kind': 'content'}}
        with patch.object(P, 'translate_chunk', fake):
            P.translate(sentences, lang='ja')
        self.assertEqual(calls, ['ja'])
        self.assertEqual(sentences[0]['en'], '会議は三時です。')
        self.assertEqual(sentences[0]['ko'], '회의는 3시입니다.')
        self.assertIn('일본어', P.TRANSLATE_PROMPTS['ja'][0])


if __name__ == '__main__':
    unittest.main()
