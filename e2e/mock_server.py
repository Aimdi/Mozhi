#!/usr/bin/env python3
"""Mock Mozhi instance + OpenAI-compatible LLM server for the web E2E suite.

Standard library only. Serves, with open CORS:
  /api/*      a fake Mozhi instance (version, engines, languages, translate, tts)
  /v1/*       a fake OpenAI-compatible provider (models, chat/completions with
              streaming and JSON-mode answers for the AI extras: alternatives,
              insights, dictionary, proofreading, meaning check, refinements)
  /__health   200 "ok" (readiness probe)

Answers are deterministic (no randomness, no clock), so tests can assert on
exact text, e.g. "[refined] ..." after a refinement chip.

Usage: python3 mock_server.py [port]   (default: $MOCK_PORT or 8787)
"""
import json, os, re, sys, time, urllib.parse
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

LANGS = [("auto", "Autodetect"), ("en", "English"), ("fr", "French"), ("de", "German"),
         ("es", "Spanish"), ("ja", "Japanese"), ("zh-CN", "Chinese (Simplified)"), ("ta", "Tamil"),
         ("ru", "Russian"), ("pt", "Portuguese"), ("it", "Italian"), ("ko", "Korean")]
ENGINES = {"all": "All Engines", "some": "Some Engines", "google": "Google", "deepl": "DeepL",
           "duckduckgo": "DuckDuckGo", "mymemory": "MyMemory", "reverso": "Reverso", "yandex": "Yandex"}
DICT = {("hello", "fr"): "bonjour", ("hello", "de"): "hallo", ("hello", "es"): "hola",
        ("good morning", "fr"): "bonjour", ("thank you", "fr"): "merci", ("cat", "fr"): "chat"}

def fake_translate(engine, src, to, text):
    key = (text.strip().lower(), to)
    out = DICT.get(key)
    if out is None:
        out = f"[{to}] " + text
    if engine == "deepl":
        out = out[:1].upper() + out[1:]
    detected = "en" if src == "auto" else ""
    res = {"engine": engine, "detected": detected, "translated-text": out,
           "source_language": src, "target_language": to,
           "word_choices": None, "source_transliteration": "", "target_transliteration": "",
           "source_synonyms": None, "target_synonyms": None, "source_antonyms": None,
           "target_antonyms": None, "source_equivalent_target_lang": None,
           "target_equivalent_source_lang": None}
    if engine == "google" and len(text.split()) <= 2:
        res["word_choices"] = [{"word": text, "definition": "used as a greeting or to begin a phone conversation",
                                "example": "hello there, Katie!", "examples_source": None, "examples_target": None}]
        res["target_synonyms"] = ["salut", "coucou"]
    if to == "ja":
        res["target_transliteration"] = "konnichiwa"
    return res

ALT = {"description": "A neutral, everyday rendering.", "alternatives": [
    {"text": "Salut tout le monde !", "explanation": "More casual, as among friends."},
    {"text": "Bonjour à toutes et à tous !", "explanation": "Inclusive and slightly more formal."},
    {"text": "Coucou !", "explanation": "Very informal, affectionate."}]}
INSIGHTS = {"insights": [{"source": "Hello", "target": "Bonjour", "type": "nuance",
                          "explanation": "'Bonjour' is the default polite greeting during the day.",
                          "variations": [{"text": "Salut", "explanation": "informal"},
                                         {"text": "Bonsoir", "explanation": "used in the evening"}]}]}
SUGG = {"suggestions": [{"label": "Add warmth", "description": "Friendlier tone", "instruction": "Make it warmer and friendlier.", "icon": "casual"}]}
DICTENTRY = {"word": "hello", "pronunciation": "həˈloʊ", "parts_of_speech": ["interjection", "noun"],
             "senses": [{"part_of_speech": "interjection", "definition": "used as a greeting", "translations": ["bonjour", "salut"], "usage": "common"}],
             "examples": [{"source": "Hello, how are you?", "translation": "Bonjour, comment ça va ?"}],
             "synonyms": ["hi", "hey"], "etymology": "From hallo, an alteration of holla.", "notes": ""}
PROOF = {"language": "en", "corrected": "I have a cat. It likes to sleep.",
         "summary": "Two grammar fixes; the tone is neutral.",
         "edits": [{"original": "I has", "replacement": "I have", "explanation": "Subject-verb agreement.", "category": "grammar"},
                   {"original": "like to", "replacement": "likes to", "explanation": "Third person singular.", "category": "grammar"}]}

def llm_answer(messages, json_mode):
    system = "\n".join(m.get("content", "") if isinstance(m.get("content"), str) else "" for m in messages if m["role"] == "system")
    user = messages[-1]["content"] if isinstance(messages[-1]["content"], str) else " ".join(
        p.get("text", "") for p in messages[-1]["content"] if isinstance(p, dict))
    low = (system + "\n" + user).lower()
    if json_mode or "json" in low:
        if "back_translation" in low or "back-translat" in low:
            return json.dumps({"back_translation": "Good morning, how are you today?", "verdict": "minor",
                "issues": [{"source_span": "today", "translation_span": "today", "type": "omission",
                            "problem": "The time reference is weaker in the translation.", "suggestion": "aujourd'hui"}]})
        if "pairs" in low and "align" in low:
            return json.dumps({"pairs": [{"source": "Good morning", "target": "Good morning"}, {"source": "how are you", "target": "how are you"}]})
        if "proofread" in low or "corrected" in low: return json.dumps(PROOF)
        if "insight" in low: return json.dumps(INSIGHTS)
        if "suggestion" in low: return json.dumps(SUGG)
        if "dictionary" in low or "pronunciation" in low: return json.dumps(DICTENTRY)
        if "alternative" in low: return json.dumps(ALT)
        if "detect" in low: return json.dumps({"language": "en", "uncertain": False, "mixed": False, "alternatives": []})
    if "romaniz" in low:
        return "ohayou gozaimasu, ogenki desu ka"
    if "<refinement>" in user or "<refinement>" in system:
        m2 = re.search(r"<translation>\s*(.*?)\s*</translation>", user, re.S)
        return "[refined] " + (m2.group(1) if m2 else "")
    if "explain" in low and "<source>" not in user:
        return "**Bonjour** is the standard greeting.\n\n- *Bonjour* = good day\n- Use *salut* with friends."
    m = re.search(r"<source>\s*(.*?)\s*</source>", user, re.S)
    text = m.group(1) if m else user
    target = "fr"
    tm = re.search(r"into ([A-Z][\w\- ()']+)", system)
    tname = tm.group(1).strip() if tm else "French"
    codes = {"French": "fr", "German": "de", "Spanish": "es", "Japanese": "ja", "English": "en"}
    target = codes.get(tname.split()[0], "fr")
    out = DICT.get((text.strip().lower(), target), f"[AI→{tname}] {text}")
    marker = "[[lang:en]]\n" if "[[lang:" in system else ""
    think = "<think>The user wants a translation. Let me think.</think>\n" if out.startswith("[AI") else ""
    return think + marker + out

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    def send_json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status); self.cors()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def send_text(self, text, status):
        body = text.encode()
        self.send_response(status); self.cors()
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_OPTIONS(self):
        self.send_response(204); self.cors(); self.send_header("Content-Length", "0"); self.end_headers()
    def params(self):
        u = urllib.parse.urlparse(self.path)
        q = dict(urllib.parse.parse_qsl(u.query))
        if self.command == "POST":
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n) if n else b""
            ct = self.headers.get("Content-Type", "")
            if "application/x-www-form-urlencoded" in ct:
                q.update(dict(urllib.parse.parse_qsl(raw.decode())))
            elif "json" in ct and raw:
                q["__json"] = json.loads(raw)
        return u.path, q
    def do_GET(self): self.route()
    def do_POST(self): self.route()
    def route(self):
        path, q = self.params()
        if path == "/__health": return self.send_text("ok", 200)
        if path == "/api/version": return self.send_json({"fiberversion": "v2.52.5", "goversion": "go1.24"})
        if path == "/api/engines": return self.send_json(ENGINES)
        if path in ("/api/source_languages", "/api/target_languages"):
            if not q.get("engine"): return self.send_text("engine is a required query string.", 400)
            langs = LANGS if path.startswith("/api/source") else LANGS[1:]
            return self.send_json([{"Name": n, "Id": i} for i, n in langs])
        if path == "/api/translate":
            eng, src, to, text = q.get("engine"), q.get("from"), q.get("to"), q.get("text")
            if not (eng and src and to and text): return self.send_text("from, to, engine, text are required query strings.", 400)
            time.sleep(0.15)
            if eng == "all" or "," in eng:
                names = [e for e in ENGINES if e not in ("all", "some")] if eng == "all" else eng.split(",")
                return self.send_json([fake_translate(e, src, to, text) for e in names if e != "yandex"])
            if eng not in ENGINES: return self.send_text("Engine does not exist or has been disabled.", 500)
            return self.send_json(fake_translate(eng, src, to, text))
        if path == "/api/tts":
            body = b"ID3\x03\x00\x00\x00\x00\x00\x00" + b"\x00" * 64
            self.send_response(200); self.cors(); self.send_header("Content-Type", "audio/mpeg")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); return self.wfile.write(body)
        if path == "/v1/models":
            return self.send_json({"object": "list", "data": [{"id": "mock-translator-8b"}, {"id": "mock-large"}]})
        if path == "/v1/chat/completions":
            req = q.get("__json", {})
            answer = llm_answer(req.get("messages", []), bool(req.get("response_format")))
            if not req.get("stream"):
                return self.send_json({"choices": [{"message": {"role": "assistant", "content": answer}, "finish_reason": "stop"}]})
            self.send_response(200); self.cors()
            self.send_header("Content-Type", "text/event-stream"); self.send_header("Cache-Control", "no-cache")
            self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
            def chunk(s):
                b = s.encode(); self.wfile.write(f"{len(b):X}\r\n".encode() + b + b"\r\n"); self.wfile.flush()
            pieces = re.findall(r".{1,4}", answer, re.S)
            for p in pieces:
                chunk("data: " + json.dumps({"choices": [{"delta": {"content": p}, "index": 0}]}) + "\n\n")
                time.sleep(0.02)
            chunk("data: [DONE]\n\n"); self.wfile.write(b"0\r\n\r\n"); self.wfile.flush(); return
        self.send_text("not found", 404)

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else int(os.environ.get("MOCK_PORT", "8787"))
    server = ThreadingHTTPServer(("127.0.0.1", port), H)
    server.daemon_threads = True
    print(f"mock server on http://127.0.0.1:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
