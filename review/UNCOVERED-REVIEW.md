<!-- REVIEW.md's step 2 tells the model to Read this file directly (../review/UNCOVERED-REVIEW.md
     from its working directory) - checks here are ours, not covered by /code-review or
     /security-review. Kept separate purely for our own readability. -->

#### 2.1 PR title & commit messages (category `style`, severity `low`)
Commit subject: capitalized, no trailing period, imperative mood, non-empty (`wip`/`.` fail). Conventional-commit prefixes (`feat:`, `fix:`, ...) are never a violation either way; merge commits are exempt entirely. Omit `locations` entirely (not tied to a file).

#### 2.2 Code comment language (category `style`, severity `medium`)
New/changed code comments must be English (inline/block only — not UI strings, i18n, identifiers, test data, markdown, generated files, string literals). The automated check already catches non-ASCII; you only need to report ASCII non-English and transliterations (e.g. a phonetically-spelled non-English word).
