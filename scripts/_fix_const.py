"""Iteratively removes `const` keywords that analyzer reports as invalid after the recolor refactor."""
import re
import subprocess

APP = r"D:\NhanSam\MoneyManage\moma\apps\android"
ERR = re.compile(r"lib\\(\S+?\.dart):(\d+):(\d+) - (\w+)")
CODES = {"const_with_non_const", "non_constant_argument", "invalid_constant", "const_initialized_with_non_constant_value", "non_constant_list_element", "const_eval_method_invocation", "const_eval_type_bool_num_string", "const_constructor_param_type_mismatch", "non_constant_map_element", "non_constant_default_value", "const_eval_extension_method"}


def run():
    out = subprocess.run(
        ["C:\\dev\\flutter\\bin\\flutter.bat", "analyze"], cwd=APP, capture_output=True, text=True, encoding="utf8"
    ).stdout
    return out


for rnd in range(40):
    out = run()
    errs = []
    for line in out.splitlines():
        m = ERR.search(line)
        if m and m.group(4) in CODES or (m and "constant" in line.lower()):
            errs.append((m.group(1).replace("\\", "/"), int(m.group(2)), int(m.group(3))))
    print("round", rnd, "errors:", len(errs))
    if not errs:
        break
    # fix one error per file per round (positions shift after edits)
    seen = set()
    for f, ln, col in errs:
        if f in seen:
            continue
        seen.add(f)
        path = APP + "\\lib\\" + f.replace("/", "\\")
        lines = open(path, encoding="utf8", newline="").read().split("\n")
        # walk backwards from the error position to the closest `const ` keyword
        i, c = ln - 1, col - 1
        found = False
        while i >= 0:
            text = lines[i][:c] if i == ln - 1 else lines[i]
            k = text.rfind("const ")
            if k >= 0:
                lines[i] = lines[i][:k] + lines[i][k + 6 :]
                found = True
                break
            i -= 1
            c = 10**6
        if not found:
            print("no const found for", f, ln)
        open(path, "w", encoding="utf8", newline="").write("\n".join(lines))
print(run()[-600:])
