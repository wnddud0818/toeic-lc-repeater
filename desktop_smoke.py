"""Opt-in packaged-app UI check used by Windows CI, with synthetic lesson data."""
import io
import json
import os
import time
import urllib.request
import wave


def check_window(window, base_url, report_path):
    result = {'ok': False}
    try:
        for _ in range(100):
            if window.evaluate_js('Boolean(document.getElementById("sentence"))'):
                break
            time.sleep(0.2)
        else:
            raise RuntimeError('Player did not load in the WebView2 window')
        result['ui'] = window.evaluate_js('''(() => {
            const card = document.getElementById('card');
            const sentence = document.getElementById('sentence');
            const read = () => ({filter: getComputedStyle(sentence).filter,
                lang: document.getElementById('lang').textContent,
                hidden: sentence.getAttribute('aria-hidden'),
                text: sentence.textContent, label: card.getAttribute('aria-label')});
            const states = [read()];
            card.click(); states.push(read());
            document.getElementById('langBtn').click(); states.push(read());
            document.dispatchEvent(new KeyboardEvent('keydown', {code: 'KeyT', bubbles: true}));
            states.push(read());
            card.click();
            document.getElementById('next').click(); states.push(read());
            return {states, position: document.getElementById('pos').textContent};
        })()''')
        states = result['ui']['states']
        assert [s['filter'] for s in states] == ['blur(8px)', 'none', 'none', 'blur(8px)', 'blur(8px)'], states
        assert [s['lang'] for s in states] == ['EN', 'EN', 'KO', 'EN', 'EN'], states
        assert result['ui']['position'] == '2 / 2', result['ui']
        assert states[0]['hidden'] == 'true' and states[0]['text'] not in states[0]['label']
        with urllib.request.urlopen(base_url + '/api/lessons/test-lesson/clip/400-1200.wav', timeout=10) as response:
            with wave.open(io.BytesIO(response.read())) as audio:
                assert (audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) == (32000, 1, 2)
                assert audio.getnframes() > 0
        with urllib.request.urlopen(base_url + '/api/lessons/test-lesson/export', timeout=10) as response:
            assert response.read(8) == b'LCRLESS1'
        result['ok'] = True
    except Exception as error:
        result['error'] = repr(error)
    finally:
        with open(report_path + '.tmp', 'w', encoding='utf-8') as report:
            json.dump(result, report, ensure_ascii=False, indent=2)
        os.replace(report_path + '.tmp', report_path)
        window.destroy()
