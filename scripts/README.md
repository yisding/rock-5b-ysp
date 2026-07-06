# scripts/ - repository maintenance checks

Cross-project validation helpers that do not belong to a single package or
driver area.

| Script | Purpose |
|--------|---------|
| [`check-markdown-links.py`](check-markdown-links.py) | Checks local Markdown links for missing files and missing same-repo section anchors. |

Run these before presenting or handing off a large documentation cleanup:

```bash
python3 scripts/check-markdown-links.py
git diff --check
```
