## Summary

ADR-0060 §11, the renderer half. Pairs with worktree.nvim `feat/reviews-section` (the store policy) and needs it for the new surfaces; without it the tree renders exactly as it does today.

Review JSONs were reachable only under the commit they name, which is the one place they cannot always be found: the filename carries the sha, so after a rebase or an amend no commit row names the file and the review is invisible in the panel — exactly when someone needs to find it and re-point it.

```
▾ auto-core                                    (bare)
  ▸ main                          ● watched  (base)
  ▸ fix/annotate-composer
  ▾ reviews  (3)
      1cfe731.r1.review.json  [must-fix]
      e5407f1.r2.review.json  [approved]
      ba32de5.r9.review.json  [malformed]
```

- A **`reviews` node on each repository**, a sibling of its worktrees. Johno's shape was `Repo -> [commits, reviews]`; the worktree tier the diagram omits still sits between them. The per-commit rows stay where they were — a review is reachable from its commit *and* from the repo.
- Rows are **`<commit>.r<N>.review.json  [worst severity]`**. The `<slug>@` prefix is elided (every file in the directory carries it, and it is already the row above); what remains still names the commit. The badge falls back to the `verdict` for a review with no comments, and `malformed` is **additive, never a replacement** — a review can carry real findings and still fail validation, and hiding either half loses one.
- Rows use auto-core's annotation groups, so a finding is the same colour here as inline in the diff view (foreground only, per §10). **Both** review row kinds render through this one label and colour: the same file listed in two places reading two different ways is how a reader stops trusting either.
- **`i`** describes a review — full sha, revision, created, reviewer, verdict, comment/resolved counts, severity tally, files touched with per-file counts, summary, and any parse or validation error, including a document whose own revision disagrees with its filename. `i` on the section names the store directory.
- **`[feedback]`** on a commit's changed files where a reviewer has written, merged across revisions. Just the word: the row already carries its status colour and the finding is one `<CR>` or `o` away.
- **Two tiers of cost**, keeping §2.2's zero-cost repaint: the count on the collapsed row is one directory scan, documents open only on expand, and a commit's rows plus its badges come from one read pass. Every new call is guarded on the **surface**, not a version.

**Not in this change:** remove and re-attach. §11.6 records why re-attach is more than a keypress — revision collision at the target sha, the paired canonical Markdown that must move with the JSON, and comments anchored to lines a rebase may have moved.

## Tests

`tests/adr0060-repos-render.lua` p9, suite **67/0**; `tests/run-all.sh` OK (smoke 708/0, adr0048 154/0, git-actions 53/0, adr0065-p3 80/0, adr0069 43/0, sandbox contract 9/0).

p9 pins the section and its count, that nothing is listed until it is expanded, the label and its elision, the severity colour, that `<CR>` has a real file, the metadata `i` prints, a **control** that the per-commit lookup goes blind on a rewritten sha while the section still lists the review, and the badge present on the reviewed file and absent on an unreviewed one.

Mutation controls: making `tally_paths` return nothing fails both badge pins; removing the elision fails the label pin.

## Release

Patch bump to v0.4.13 after review, tagged together with auto-core and worktree.nvim (one release for the whole §10/§11 set, at Johno's request). Consumers pin `^0.4.0`.
