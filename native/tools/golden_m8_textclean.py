"""M8 golden suite: m8_textclean, the text cleaning in speak() (jarvis.py 723-729).

Plugin for tools/golden.py. The REAL speak() runs on each input, with get_piper patched to
return None and _system_say patched to record its argument, so the expected value is the text
Python would have handed to its last-resort voice (None when speak() returns without speaking).
Only the inputs are typed here. One "patterns" case holds the two re.sub patterns read from
speak()'s own AST, in source order, which the Swift test compares with TextClean's.

Inputs: markdown (bold, italic, code, headings, links, tables, quotes, lists), bullets,
newlines and other whitespace (tabs, CR LF, NBSP, U+3000, the \\x1c-\\x1f separators, U+0085,
U+2028), emoji (ZWJ, flags, skin tones, keycaps), quotes, digits and symbols, and inputs that
clean to nothing.
"""
import ast

from golden import suite

_INPUTS = [
    ("empty", ""),
    ("spaces", "   "),
    ("newlines_only", "\n\n"),
    ("plain", "Hello, sir."),
    ("bold", "**Bold** move, sir."),
    ("italic_underscores", "_italic_ and __double__"),
    ("inline_code", "Run `ls -la` now."),
    ("fenced_code", "Code:\n```python\nprint('hi')\n```"),
    ("heading", "# Heading\nText under it."),
    ("subheading", "## Sub-heading"),
    ("link", "See [the docs](https://example.com/page) first."),
    ("nested_link", "Nested [**bold link**](https://example.com)"),
    ("table_pipes", "Table | with | pipes"),
    ("markdown_table", "Table:\n| a | b |\n|---|---|\n| 1 | 2 |"),
    ("strike", "~strike~ and ~~through~~"),
    ("blockquote", "> quoted line"),
    ("nested_quote", ">> deeper quote"),
    ("bullets", "• bullet one\n• bullet two"),
    ("bullet_glued", "Bullet•glued"),
    ("dash_list", "- dash bullet\n- another"),
    ("star_list", "* star bullet\n* another"),
    ("numbered_list", "1. first\n2. second"),
    ("tabs", "Tabs\tand\tspaces   inside"),
    ("crlf", "Line one\r\nLine two"),
    ("trailing_newline", "Trailing newline\n"),
    ("leading_newlines", "\n\nLeading newlines"),
    ("blank_lines", "Multiple    spaces\n\n\nand newlines"),
    ("vt_ff", "Mixed\twhitespace\x0b\x0cend"),
    ("nbsp", "Non-breaking\u00a0space"),
    ("ideographic_space", "Ideographic\u3000space"),
    ("zero_width_space", "Zero\u200bwidth space"),
    ("file_separator", "Separator\x1cchars\x1fhere"),
    ("next_line", "Next\x85line"),
    ("line_separator", "Line\u2028separator"),
    ("emoji", "Emoji 😀 stays"),
    ("zwj_family", "Family 👨\u200d👩\u200d👧 emoji"),
    ("flag", "Flag 🇬🇧 here"),
    ("skin_tone", "Thumbs 👍🏽 up"),
    ("keycap", "Keycap 1️⃣ two"),
    ("precomposed", "Café déjà vu"),
    ("decomposed", "Cafe\u0301 decomposed"),
    ("straight_quotes", "\"Double quotes\" and 'single'"),
    ("curly_quotes", "Curly “quotes” and ‘single’"),
    ("apostrophe", "It's what you'd expect."),
    ("time", "It's 3:45 PM."),
    ("percent", "Your battery is at 64%."),
    ("pounds", "That costs £20."),
    ("dollars_parens", "Price: $5 (approx.)"),
    ("math_star", "Math: 2 * 3 = 6"),
    ("snake_case", "Under_score_name"),
    ("hashtag", "#hashtag"),
    ("less_greater", "a > b and b < c"),
    ("backslash", "Backslash \\ alone"),
    ("windows_path", "C:\\Temp\\notes.txt"),
    ("pipes_everywhere", "Pipes || everywhere |"),
    ("tilde", "Tilde ~ approximately"),
    ("dashes", "Ellipsis… and dash — and en–dash"),
    ("punctuation_run", "Question? Exclaim! Done."),
    ("ends_bang", "Ends with punctuation!!!"),
    ("asterisk_in_word", "Asterisk*in*word"),
    ("greek", "Greek ΟΔΟΣ and Σ"),
    ("arabic", "Arabic مرحبا"),
    ("cjk", "CJK 你好世界"),
    ("only_stars", "***"),
    ("only_brackets", "[]()"),
    ("only_bullets", "• • •"),
    ("only_markup_and_space", " ** __ ## \n > "),
    ("mixed_markup", "Mixed **bold** and _italic_ with `code`."),
]


def _speak_patterns(J):
    """The pattern strings of speak()'s re.sub calls, in source order."""
    tree = ast.parse(open(J.__file__, encoding="utf-8").read())
    found = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "speak"]
    if len(found) != 1:
        raise AssertionError(f"jarvis.py has {len(found)} top-level functions named speak, expected 1")
    patterns = []
    for n in ast.walk(found[0]):
        if (isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == "sub"
                and isinstance(n.func.value, ast.Name) and n.func.value.id == "re"):
            patterns.append((n.lineno, n.col_offset, n.args[0].value))
    if len(patterns) != 2:
        raise AssertionError(f"speak() has {len(patterns)} re.sub calls, expected 2")
    return [p for _, _, p in sorted(patterns)]


@suite("m8_textclean")
def textclean(ctx):
    J = ctx.J
    said = []
    J.get_piper = lambda: None
    J._system_say = lambda text: said.append(text)
    if J._barge_in_triggered.is_set():
        raise AssertionError("_barge_in_triggered is set; speak() would not reach _system_say")
    cases = [{"name": "patterns", "input": {}, "expected": {"patterns": _speak_patterns(J)}}]
    for name, text in _INPUTS:
        said.clear()
        J.speak(text)
        if len(said) > 1:
            raise AssertionError(f"{name}: speak() called _system_say {len(said)} times")
        cases.append({"name": name, "input": {"text": text}, "expected": {"spoken": said[0] if said else None}})
    return cases
