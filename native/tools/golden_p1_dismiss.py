"""P1 golden suite: p1_dismiss, the dismissal that ends a conversation (jarvis.py 5606-5611).

Plugin for tools/golden.py. `is_dismiss(t)` is nested in the voice loop, so it is not an
attribute of the module. Its `def` is taken from jarvis.py's source with ast and compiled on
its own (it closes over nothing); this plugin never imports jarvis, it reads the file the
harness already imported. Every expected value comes from running that REAL function. Only
the inputs are typed here.

p1_dismiss  one "literals" case holding the function's phrases, read from its own AST in
            source order (the `"<phrase>" in t` tests, then the `t in (...)` tuple), then
            is_dismiss over each phrase alone, padded, capitalised, upper-cased, embedded,
            with words before or after, punctuated and addressed, and over near misses,
            Unicode whitespace, None and "".

Sample text uses neutral stand-ins only (Robin, Safari).
"""
import ast

from golden import suite


def _is_dismiss_node(J):
    tree = ast.parse(open(J.__file__, encoding="utf-8").read())
    found = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == "is_dismiss"]
    if len(found) != 1:
        raise AssertionError(f"jarvis.py has {len(found)} functions named is_dismiss, expected 1")
    return found[0]


def _compiled(J, node):
    """The nested def as a function of its own. It must not read any enclosing name."""
    free = {n.id for n in ast.walk(node) if isinstance(n, ast.Name)} - {"t"}
    if free:
        raise AssertionError(f"is_dismiss reads names outside itself: {sorted(free)}")
    ns = {}
    exec(compile(ast.Module(body=[node], type_ignores=[]), J.__file__, "exec"), ns)
    return ns["is_dismiss"]


def _phrases(node):
    """(contained, exact): the `"<phrase>" in t` phrases and the `t in (...)` tuple."""
    contained, exact = [], []
    for n in ast.walk(node):
        if not (isinstance(n, ast.Compare) and len(n.ops) == 1 and isinstance(n.ops[0], ast.In)):
            continue
        left, right = n.left, n.comparators[0]
        if isinstance(left, ast.Constant) and isinstance(left.value, str):
            contained.append(left.value)
        elif isinstance(right, ast.Tuple):
            exact.extend(e.value for e in right.elts)
    if not contained or not exact:
        raise AssertionError("is_dismiss: phrases not found")
    return contained, exact


@suite("p1_dismiss")
def dismiss(ctx):
    node = _is_dismiss_node(ctx.J)
    is_dismiss = _compiled(ctx.J, node)
    contained, exact = _phrases(node)
    inputs = []
    for p in contained + exact:
        inputs += [(f"alone/{p}", p),
                   (f"padded/{p}", f"  {p} \n"),
                   (f"capitalised/{p}", p.capitalize()),
                   (f"upper/{p}", p.upper()),
                   (f"embedded/{p}", f"well {p} then"),
                   (f"before/{p}", f"ok {p}"),
                   (f"after/{p}", f"{p} now"),
                   (f"full_stop/{p}", f"{p}."),
                   (f"addressed/{p}", f"{p}, jarvis"),
                   (f"doubled_space/{p}", p.replace(" ", "  "))]
    inputs += [("none", None), ("empty", ""), ("spaces", "   "), ("newline", "\n"),
               ("nbsp_padded", " thanks "), ("ideographic_padded", "　goodbye　"),
               ("zwsp_prefix", "​thanks"), ("tab_inside", "thank\tyou"),
               ("curly_apostrophe", "that’s all"), ("thankyou", "thankyou"), ("bye", "bye"),
               ("thanks_bang", "thanks!"), ("goodbye_full_stop", "goodbye."), ("goodbye_upper", "Goodbye"),
               ("thanks_jarvis_upper", "Thanks JARVIS"), ("thats_all_jarvis", "that's all jarvis"),
               ("not_dismissed", "you are not dismissed"), ("undismissed", "undismissed"),
               ("sleepy", "go to sleepy mode"), ("downstairs", "stand downstairs"),
               ("thanks_open", "thanks, now open safari"), ("thank_you_open", "thank you, now open safari"),
               ("thanks_jarvis_open", "thanks jarvis open safari"), ("thank_you_for", "thank you for the help"),
               ("thanks_robin", "thanks robin"), ("that_is_all_for_now", "that is all for now"),
               ("is_that_all", "is that all"), ("bye_jarvis_upper", "Bye Jarvis"),
               ("goodbye_jarvis_full_stop", "goodbye jarvis."), ("combining_acute", "thankś")]
    cases = [{"name": "literals", "input": {}, "expected": {"contained": contained, "exact": exact}}]
    for name, t in inputs:
        cases.append({"name": name, "input": {"t": t}, "expected": {"dismiss": is_dismiss(t)}})
    return cases
