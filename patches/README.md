# Local patches to vendored dependencies

`Dependencies/` is excluded by `.gitignore:89` — a leftover from the stock Swift
template's "Accio dependency management" section — and `Dependencies/AltSign`
is an orphaned submodule (its `.git` file points at `.git/modules/...`, which no
longer exists). So AltSign is NOT tracked in this repo.

The IPA is built from the working tree, so edits there DO ship — but they exist
only on the machine that made them and are invisible to git. Any patch applied
to a vendored dependency must therefore be recorded here so it can be re-applied
if the folder is ever re-cloned or reset.

Apply with: `git apply patches/<name>.patch` from the repo root.
