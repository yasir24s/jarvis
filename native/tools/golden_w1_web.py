"""W1 part 1: Python's web tools over fake transports, and the stdlib pieces they lean on.

Plugin for tools/golden.py. No request leaves the child: `jarvis.is_online` is swapped for the
case's answer and `urllib.request.urlopen` for a fake that serves each case's pages by URL and
records every request (its URL, User-Agent and timeout). A URL the case does not list fails as
an unreachable host would. Each case starts from its own knowledge base in the sandbox's
knowledge.json, and the topics after the call are kept, so kb_remember's writes are checked.

w1_web_search  input {args, online, pages, kb} -> expected {reply, requests, kb}
               execute_tool("web_search", args): DuckDuckGo's Instant Answer JSON, Wikipedia's
               opensearch and REST summary, the knowledge base on- and offline.
w1_weather     the same for execute_tool("get_weather", args) over wttr.in's j1 JSON.
w1_location    the same for execute_tool("get_location", {}) over ipwho.is.
w1_news        the same for execute_tool("get_news", {}) over the default BBC feed.
w1_news_feed   get_news with JARVIS_NEWS_FEED set, so the feed URL comes from the environment.
w1_pyurl       input {s, safe} -> expected {quote, quote_plus}; and {pairs} -> {urlencode}.
w1_html        input {s} -> expected {text} or {error}: html.unescape, every HTML5 entity name
               included (with text after it, so the longest-prefix rule is exercised too).

A page is {"body": <text>} (sent as UTF-8), {"hex": <bytes in hex>}, {"status": <code>} for an
HTTP error, or {"error": "timeout"}.
"""
import contextlib
import html
import html.entities
import json
import os
import urllib.error
import urllib.parse
import urllib.request

from golden import suite

EPOCH = 1790582400


class _Response:
    def __init__(self, data):
        self.data = data

    def read(self):
        return self.data

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class _Net:
    """Stands in for urllib.request.urlopen: serves `pages` by exact URL, records requests."""

    def __init__(self, pages):
        self.pages = pages
        self.requests = []

    def urlopen(self, req, timeout=None, **kw):
        url = req.full_url if isinstance(req, urllib.request.Request) else req
        agent = req.get_header("User-agent") if isinstance(req, urllib.request.Request) else None
        self.requests.append({"url": url, "user_agent": agent, "timeout": timeout})
        page = self.pages.get(url)
        if page is None:
            raise urllib.error.URLError("no route to host (no fixture page for this URL)")
        if "error" in page:
            raise TimeoutError("timed out")
        if "status" in page:
            raise urllib.error.HTTPError(url, page["status"], "fixture status", {}, None)
        if "hex" in page:
            return _Response(bytes.fromhex(page["hex"]))
        return _Response(page["body"].encode("utf-8"))


@contextlib.contextmanager
def _offline_world(J, online, pages):
    net = _Net(pages)
    saved = (J.is_online, urllib.request.urlopen)
    J.is_online = lambda timeout=1.2: online
    urllib.request.urlopen = net.urlopen
    try:
        yield net
    finally:
        J.is_online, urllib.request.urlopen = saved


def _kb_write(J, topics):
    if topics is None:
        if os.path.exists(J.KB_FILE):
            os.remove(J.KB_FILE)
        return
    with open(J.KB_FILE, "w") as f:
        json.dump({"topics": topics, "queue": []}, f, indent=1)


def _kb_read(J):
    try:
        with open(J.KB_FILE) as f:
            return json.load(f).get("topics")
    except FileNotFoundError:
        return None


def _run(ctx, tool, cases):
    J = ctx.J
    out = []
    for c in cases:
        ctx.reset()
        ctx.at(EPOCH)
        _kb_write(J, c.get("kb"))
        with _offline_world(J, c.get("online", True), c.get("pages", {})) as net:
            reply = J.execute_tool(tool, c.get("args", {}))
        out.append({"name": c["name"],
                    "input": {k: c[k] for k in ("args", "online", "pages", "kb") if k in c},
                    "expected": {"reply": reply, "requests": net.requests, "kb": _kb_read(J)}})
    return out


def _ddg(q):
    return "https://api.duckduckgo.com/?" + urllib.parse.urlencode(
        {"q": q, "format": "json", "no_html": 1, "skip_disambig": 1})


def _wiki_search(q):
    return "https://en.wikipedia.org/w/api.php?" + urllib.parse.urlencode(
        {"action": "opensearch", "search": q, "limit": 1, "format": "json"})


def _wiki_summary(title):
    return "https://en.wikipedia.org/api/rest_v1/page/summary/" + urllib.parse.quote(title.replace(" ", "_"))


def _j(obj):
    return {"body": json.dumps(obj)}


LONG = ("Leeds is a city in West Yorkshire, England. " * 20) + "Café été 东京 \U0001F600 end."
KB = {"leeds": {"summary": "Leeds is a city in Yorkshire, invented for this fixture.", "updated": EPOCH - 86400},
      "invented band": {"summary": "An invented band from Leeds.", "updated": EPOCH - 3600}}


@suite("w1_web_search", tz="Europe/London", epoch=EPOCH)
def web_search(ctx):
    empty = _j({"AbstractText": "", "Answer": "", "RelatedTopics": []})
    cases = [
        {"name": "offline/kb exact", "args": {"query": "Leeds"}, "online": False, "kb": KB},
        {"name": "offline/kb overlap", "args": {"query": "tell me about the invented band"}, "online": False, "kb": KB},
        {"name": "offline/kb miss", "args": {"query": "tennis"}, "online": False, "kb": KB},
        {"name": "offline/no kb file", "args": {"query": "tennis"}, "online": False, "kb": None},
        {"name": "offline/empty query", "args": {}, "online": False, "kb": KB},
        {"name": "ddg/abstract", "args": {"query": "Leeds"}, "kb": None,
         "pages": {_ddg("Leeds"): _j({"AbstractText": "Leeds is a city.", "Answer": "ignored"})}},
        {"name": "ddg/abstract long and unicode", "args": {"query": "  Café été  "}, "kb": {},
         "pages": {_ddg("  Café été  "): _j({"AbstractText": LONG})}},
        {"name": "ddg/answer string", "args": {"query": "2+2"}, "kb": {},
         "pages": {_ddg("2+2"): _j({"AbstractText": "", "Answer": "4"})}},
        {"name": "ddg/answer number", "args": {"query": "answer"}, "kb": {},
         "pages": {_ddg("answer"): _j({"AbstractText": "", "Answer": 42})}},
        {"name": "ddg/answer float", "args": {"query": "pi"}, "kb": {},
         "pages": {_ddg("pi"): _j({"Answer": 3.14159})}},
        {"name": "ddg/answer object", "args": {"query": "calc"}, "kb": {},
         "pages": {_ddg("calc"): _j({"Answer": {"from": "calculator", "result": [1, 2.5, True, None]}})}},
        {"name": "ddg/related topics only", "args": {"query": "Mercury"}, "kb": {},
         "pages": {_ddg("Mercury"): _j({"AbstractText": "", "Answer": "", "RelatedTopics": [
             {"Name": "Group", "Topics": [{"Text": "inside a group"}]}, "a string", {"Text": ""},
             {"Text": "Mercury, the planet."}, {"Text": "Mercury, the element."}]})}},
        {"name": "ddg/abstract not a str falls to wikipedia", "args": {"query": "odd"}, "kb": {},
         "pages": {_ddg("odd"): _j({"AbstractText": 7, "Answer": "skipped"}),
                   _wiki_search("odd"): _j(["odd", ["Odd"], [""], ["https://en.wikipedia.org/wiki/Odd"]]),
                   _wiki_summary("Odd"): _j({"extract": "Odd, from Wikipedia."})}},
        {"name": "ddg/related text not a str", "args": {"query": "odd text"}, "kb": {},
         "pages": {_ddg("odd text"): _j({"RelatedTopics": [{"Text": 5}]}),
                   _wiki_search("odd text"): _j(["odd text", []])}},
        {"name": "ddg/related topics null", "args": {"query": "nulls"}, "kb": {},
         "pages": {_ddg("nulls"): _j({"AbstractText": None, "RelatedTopics": None}),
                   _wiki_search("nulls"): _j(["nulls", []])}},
        {"name": "ddg/a list body", "args": {"query": "list"}, "kb": {},
         "pages": {_ddg("list"): _j([1, 2]), _wiki_search("list"): _j(["list", []])}},
        {"name": "ddg/malformed json", "args": {"query": "broken"}, "kb": {},
         "pages": {_ddg("broken"): {"body": "{not json"},
                   _wiki_search("broken"): _j(["broken", ["Broken (film)"], [""], [""]]),
                   _wiki_summary("Broken (film)"): _j({"extract": "Broken is an invented film."})}},
        {"name": "ddg/timeout then wikipedia", "args": {"query": "AC/DC & friends?"}, "kb": {},
         "pages": {_ddg("AC/DC & friends?"): {"error": "timeout"},
                   _wiki_search("AC/DC & friends?"): _j(["AC/DC & friends?", ["AC/DC"], [""], [""]]),
                   _wiki_summary("AC/DC"): _j({"extract": "AC/DC are an invented band here."})}},
        {"name": "ddg/http error then wikipedia unicode title", "args": {"query": "São Paulo"}, "kb": {},
         "pages": {_ddg("São Paulo"): {"status": 503},
                   _wiki_search("São Paulo"): _j(["São Paulo", ["São Paulo FC"], [""], [""]]),
                   _wiki_summary("São Paulo FC"): _j({"extract": LONG})}},
        {"name": "wiki/no extract falls to kb", "args": {"query": "Leeds rhinos"}, "kb": KB,
         "pages": {_ddg("Leeds rhinos"): empty,
                   _wiki_search("Leeds rhinos"): _j(["Leeds rhinos", ["Leeds Rhinos"], [""], [""]]),
                   _wiki_summary("Leeds Rhinos"): _j({"title": "Leeds Rhinos"})}},
        {"name": "wiki/summary 404", "args": {"query": "gone"}, "kb": {},
         "pages": {_ddg("gone"): empty, _wiki_search("gone"): _j(["gone", ["Gone"]]),
                   _wiki_summary("Gone"): {"status": 404}}},
        {"name": "wiki/empty titles", "args": {"query": "nothing here"}, "kb": {},
         "pages": {_ddg("nothing here"): empty, _wiki_search("nothing here"): _j(["nothing here", [], [], []])}},
        {"name": "wiki/title not a str", "args": {"query": "numbers"}, "kb": {},
         "pages": {_ddg("numbers"): empty, _wiki_search("numbers"): _j(["numbers", [12]])}},
        {"name": "nothing at all", "args": {"query": "zzz"}, "kb": {}, "pages": {}},
        {"name": "online/empty query", "args": {"query": ""}, "kb": KB,
         "pages": {_ddg(""): _j({"AbstractText": "An empty search."})}},
        {"name": "online/missing query", "args": {}, "kb": {}, "pages": {_ddg(""): empty, _wiki_search(""): _j(["", []])}},
        {"name": "query null", "args": {"query": None}, "kb": KB,
         "pages": {_ddg("None"): _j({"AbstractText": "None, the invented answer."})}},
        {"name": "query false offline", "args": {"query": False}, "online": False, "kb": KB},
        {"name": "query number", "args": {"query": 5}, "kb": {},
         "pages": {_ddg("5"): _j({"AbstractText": "Five."})}},
        {"name": "query number offline", "args": {"query": 5}, "online": False, "kb": KB},
        {"name": "kb remembers lowercased topic cut", "args": {"query": "  " + "X" * 130 + "  "}, "kb": {},
         "pages": {_ddg("  " + "X" * 130 + "  "): _j({"AbstractText": "Exes."})}},
    ]
    return _run(ctx, "web_search", cases)


def _wttr(loc):
    return "https://wttr.in/" + urllib.parse.quote(loc.strip()) + "?format=j1"


def _j1(desc="Partly cloudy", temp="12", feels="10", area="Leeds"):
    doc = {"current_condition": [{"weatherDesc": [{"value": desc}], "temp_C": temp, "FeelsLikeC": feels}]}
    if area is not None:
        doc["nearest_area"] = [{"areaName": [{"value": area}]}]
    return _j(doc)


@suite("w1_weather", tz="Europe/London", epoch=EPOCH)
def weather(ctx):
    cases = [
        {"name": "offline", "args": {"location": "Leeds"}, "online": False},
        {"name": "here", "args": {}, "pages": {_wttr(""): _j1()}},
        {"name": "named place", "args": {"location": "  New York  "},
         "pages": {_wttr("New York"): _j1("Light Rain Shower", "7", "4", "New York")}},
        {"name": "unicode and slash", "args": {"location": "São Paulo/Brazil"},
         "pages": {_wttr("São Paulo/Brazil"): _j1("ÉclairsÉ", "30", "33", "São Paulo")}},
        {"name": "no nearest_area uses the location", "args": {"location": " York "},
         "pages": {_wttr("York"): _j1(area=None)}},
        {"name": "no nearest_area and no location", "args": {"location": ""}, "pages": {_wttr(""): _j1(area=None)}},
        {"name": "empty area name", "args": {"location": "Leeds"}, "pages": {_wttr("Leeds"): _j1(area="")}},
        {"name": "numbers not strings", "args": {"location": "Oslo"},
         "pages": {_wttr("Oslo"): _j({"current_condition": [{"weatherDesc": [{"value": "SNOW"}], "temp_C": -3,
                                                             "FeelsLikeC": -7.5}],
                                      "nearest_area": [{"areaName": [{"value": 42}]}]})}},
        {"name": "area value null", "args": {"location": "Oslo"},
         "pages": {_wttr("Oslo"): _j({"current_condition": [{"weatherDesc": [{"value": "Fog"}], "temp_C": "1",
                                                             "FeelsLikeC": "0"}],
                                      "nearest_area": [{"areaName": [{"value": None}]}]})}},
        {"name": "malformed", "args": {"location": "Leeds"}, "pages": {_wttr("Leeds"): {"body": "<html>"}}},
        {"name": "missing current_condition", "args": {"location": "Leeds"}, "pages": {_wttr("Leeds"): _j({})}},
        {"name": "description not a str", "args": {"location": "Leeds"},
         "pages": {_wttr("Leeds"): _j({"current_condition": [{"weatherDesc": [{"value": 3}], "temp_C": "1",
                                                              "FeelsLikeC": "1"}]})}},
        {"name": "timeout", "args": {"location": "Leeds"}, "pages": {_wttr("Leeds"): {"error": "timeout"}}},
        {"name": "http error", "args": {"location": "Leeds"}, "pages": {_wttr("Leeds"): {"status": 500}}},
        {"name": "location not a str", "args": {"location": 7}, "pages": {}},
        {"name": "location null", "args": {"location": None}, "pages": {}},
    ]
    return _run(ctx, "get_weather", cases)


@suite("w1_location", tz="Europe/London", epoch=EPOCH)
def location(ctx):
    url = "https://ipwho.is/"
    cases = [
        {"name": "offline", "online": False},
        {"name": "all three", "pages": {url: _j({"success": True, "city": "Leeds", "region": "England",
                                                "country": "United Kingdom"})}},
        {"name": "no region", "pages": {url: _j({"success": True, "city": "Leeds", "region": "",
                                                "country": "United Kingdom"})}},
        {"name": "null city", "pages": {url: _j({"success": True, "city": None, "country": "Japan"})}},
        {"name": "empty bits", "pages": {url: _j({"success": True, "city": "", "region": "", "country": ""})}},
        {"name": "not success", "pages": {url: _j({"success": False, "message": "reserved range"})}},
        {"name": "success 1", "pages": {url: _j({"success": 1, "city": "Zürich"})}},
        {"name": "city a number", "pages": {url: _j({"success": True, "city": 5, "country": "X"})}},
        {"name": "a list body", "pages": {url: _j([1])}},
        {"name": "malformed", "pages": {url: {"body": "nope"}}},
        {"name": "timeout", "pages": {url: {"error": "timeout"}}},
    ]
    return _run(ctx, "get_location", cases)


def _rss(titles):
    items = "".join(f"<item>\n    <title>{t}</title>\n    <link>https://example.invalid/{k}</link>\n</item>\n"
                    for k, t in enumerate(titles))
    return {"body": f'<?xml version="1.0"?><rss><channel><title>Invented</title>{items}</channel></rss>'}


NEWS_TITLES = ["<![CDATA[Invented storm reaches Leeds]]>", "Markets &amp; banks rally", "   ",
               "It&#8217;s a <b>bold</b> claim", "<![CDATA[]]>", "Caf&eacute;s close &#x1F600; early",
               "Seventh &notanentity; story", "Eighth", "Ninth", "Tenth"]


@suite("w1_news", tz="Europe/London", epoch=EPOCH)
def news(ctx):
    feed = "https://feeds.bbci.co.uk/news/rss.xml"
    cases = [
        {"name": "offline", "online": False},
        {"name": "ten items, first four kept", "pages": {feed: _rss(NEWS_TITLES)}},
        {"name": "two items", "pages": {feed: _rss(["One", "Two &lt;3"])}},
        {"name": "item without newline", "pages": {feed: {"body": "<item><title>Tight</title></item>"
                                                                   "<item>\t\r\n<title>\nMulti\nline\n</title></item>"}}},
        {"name": "no items", "pages": {feed: {"body": "<rss><channel><title>Only a channel</title></channel></rss>"}}},
        {"name": "only empty titles", "pages": {feed: _rss(["", "  ", "<![CDATA[  ]]>"])}},
        {"name": "invalid utf-8", "pages": {feed: {"hex": "3c6974656d3e3c7469746c653e4261"
                                                          "64ff2062797465c3282068657265e282"
                                                          "3c2f7469746c653e3c2f6974656d3e"}}},
        {"name": "byte order mark", "pages": {feed: {"hex": "efbbbf3c6974656d3e3c7469746c653e"
                                                            "424f4d3c2f7469746c653e3c2f697465"
                                                            "6d3e"}}},
        {"name": "references", "pages": {feed: _rss(["&#0; &#13; &#128; &#x110000; &#xD800; &#1; &#65;&#66",
                                                     "&amp &ampx &notin; &notit; &AMP;", "&#" + "9" * 4400 + ";"])}},
        {"name": "timeout", "pages": {feed: {"error": "timeout"}}},
        {"name": "http error", "pages": {feed: {"status": 404}}},
    ]
    return _run(ctx, "get_news", cases)


@suite("w1_news_feed", tz="Europe/London", epoch=EPOCH, env={"JARVIS_NEWS_FEED": "https://news.invalid/feed?x=1"})
def news_feed(ctx):
    cases = [{"name": "from the environment", "pages": {"https://news.invalid/feed?x=1": _rss(["From the env"])}}]
    return _run(ctx, "get_news", cases)


QUOTE_CASES = ["", "plain", "New York", "a/b/c", "AC/DC & friends?", "São Paulo", "100% sure+1",
               "~user_name.-", "东京", "\U0001F600", "tab\there", "line\nbreak", "#hash?q=1&r=2",
               "é", "'quotes' \"double\"", "@:;,=$!*()[]{}|\\^`<>"]


@suite("w1_pyurl", tz="UTC", epoch=EPOCH)
def pyurl(ctx):
    cases = []
    for s in QUOTE_CASES:
        for safe in ("/", "", "/:@"):
            cases.append({"name": f"quote {s!r} safe {safe!r}", "input": {"s": s, "safe": safe},
                          "expected": {"quote": urllib.parse.quote(s, safe=safe),
                                       "quote_plus": urllib.parse.quote_plus(s, safe=safe)}})
    pairs = [[["q", "AC/DC & friends?"], ["format", "json"], ["no_html", "1"]],
             [["action", "opensearch"], ["search", "São Paulo"], ["limit", "1"]],
             [["k y", "v=a&b"], ["", ""]]]
    for p in pairs:
        cases.append({"name": f"urlencode {p!r}", "input": {"pairs": p},
                      "expected": {"urlencode": urllib.parse.urlencode([tuple(x) for x in p])}})
    return cases


HTML_CASES = ["no references", "&", "&;", "&#;", "&#x;", "&#xZ", "&#65", "&#65;", "&#x41;x", "&#X41",
              "&#0;", "&#13;", "&#128;", "&#159;", "&#x81;", "&#xD800;", "&#xDFFF;", "&#x10FFFF;", "&#x110000;",
              "&#1;", "&#11;", "&#127;", "&#xFFFE;", "&#x1FFFF;", "&#00000000000065;", "&#x0000000041;",
              "&#99999999999999999999;", "&amp", "&amp;", "&ampx", "&amp;x", "&AMP", "&notin;", "&notit;", "&noti",
              "&not", "&nota", "&lt;3 &gt", "&#38;amp;", "&&amp;", "a &unknown; b", "&" + "a" * 40 + ";",
              "&KHcy;", "&KHcy;", "& amp;", "&\tamp;", "&amép;", "&Eacute&eacute;&eacute",
              "&nbsp;x&nbsp", "&#x1F600;&#128512;", "&#" + "9" * 4300 + ";", "&#" + "9" * 4301 + ";"]


@suite("w1_html", tz="UTC", epoch=EPOCH)
def html_unescape(ctx):
    cases = []
    for s in HTML_CASES:
        cases.append(_unescape_case(f"case {len(cases)}", s))
    for name in sorted(html.entities.html5):
        cases.append(_unescape_case(f"entity {name}", f"x&{name}y z"))
    return cases


def _unescape_case(name, s):
    try:
        return {"name": name, "input": {"s": s}, "expected": {"text": html.unescape(s)}}
    except ValueError as e:
        return {"name": name, "input": {"s": s}, "expected": {"error": str(e)}}
