"""M9 golden suite: m9_vocabulary, the transcriber's vocabulary (jarvis.py 915-931).

Plugin for tools/golden.py. Each case writes profile.json and corrections.json into the
sandbox (or leaves them out), sets WHISPER_PROMPT for the cases about JARVIS_WHISPER_PROMPT,
and records what the REAL _whisper_prompt() returns. The Swift test writes the same files,
reads the name and the meant words through CoreState.whisperVocabularyInputs(), and checks
that Vocabulary.prompt gives Python's string byte for byte, which pins the extras (the name,
then the last 12 corrections' meant words, de-duplicated with dict.fromkeys) that
Vocabulary.contextualStrings appends to the prompt's own words.

Inputs: no files; a name; an empty or missing name; a name that is not an object; a corrupt
profile; 3 and 15 corrections (the last 12 count); repeats, including a meant word equal to the
name; entries _corrections_load drops; precomposed and decomposed accents (different keys);
and prompts with no "Vocabulary:", two of them, odd spacing, and an empty prompt.
"""
import json
import os

from golden import suite


def _put(path, text):
    if os.path.exists(path):
        os.remove(path)
    if text is not None:
        with open(path, "wb") as f:
            f.write(text.encode("utf-8"))


def _profile(name):
    return json.dumps({"facts": {"name": {"value": name, "updated": 1790582400.0}}}, indent=1)


def _pairs(meants):
    return json.dumps([{"heard": f"heard {i}", "meant": m, "at": 1790582400.0 + i}
                       for i, m in enumerate(meants)], indent=1)


_CUSTOM = "Words for the decoder. Vocabulary: Ada, Lovelace."
_CASES = [
    # (name, base or None for the default, profile.json text, corrections.json text)
    ("no_files", None, None, None),
    ("name_only", None, _profile("Ada"), None),
    ("empty_name", None, _profile(""), None),
    ("no_name_fact", None, json.dumps({"facts": {"city": {"value": "Leeds"}}}, indent=1), None),
    ("name_not_object", None, json.dumps({"facts": {"name": "Ada"}}, indent=1), None),
    ("corrupt_profile", None, "{not json", _pairs(["Safari"])),
    ("three_corrections", None, None, _pairs(["Grace Hopper", "Zanzibar", "kettle"])),
    ("fifteen_corrections", None, _profile("Ada"), _pairs([f"word{i:02d}" for i in range(15)])),
    ("repeats", None, _profile("Ada"), _pairs(["kettle", "Ada", "kettle", "toaster", "Ada"])),
    ("meant_in_prompt", None, _profile("Jarvis"), _pairs(["calendar", "Chrome"])),
    ("dropped_entries", None, None, json.dumps([
        {"heard": "x y", "meant": ""}, {"heard": "", "meant": "lost"}, "not a pair",
        {"meant": "no heard"}, {"heard": "kept one", "meant": "Pembrokeshire"}], indent=1)),
    ("accents", None, _profile("Zoë"), _pairs(["café", "café", "café"])),
    ("unicode_name", None, _profile("李华"), _pairs(["naïve"])),
    ("custom_prompt", _CUSTOM, _profile("Grace"), None),
    ("no_vocabulary_label", "Just a sentence about JARVIS.", None, _pairs(["kettle"])),
    ("two_labels", "Vocabulary: one, two. Vocabulary: three , four.", None, None),
    ("odd_spacing", "Vocabulary:  alpha ,beta.. , ,  gamma .", None, None),
    ("empty_prompt", "", _profile("Ada"), None),
    ("empty_prompt_no_extras", "", None, None),
]


@suite("m9_vocabulary")
def vocabulary(ctx):
    J = ctx.J
    default = J.WHISPER_PROMPT
    cases = [{"name": "default_prompt", "input": {}, "expected": {"whisper_prompt": default}}]
    for name, base, profile, corrections in _CASES:
        ctx.reset()                                   # _corr_cache = None: the file is read again
        _put(J.PROFILE_FILE, profile)
        _put(J.CORR_FILE, corrections)
        J.WHISPER_PROMPT = default if base is None else base
        try:
            got = J._whisper_prompt()
        finally:
            J.WHISPER_PROMPT = default
        cases.append({"name": name,
                      "input": {"base": J.WHISPER_PROMPT if base is None else base,
                                "profile": profile, "corrections": corrections},
                      "expected": {"prompt": got}})
    _put(J.PROFILE_FILE, None)
    _put(J.CORR_FILE, None)
    return cases
