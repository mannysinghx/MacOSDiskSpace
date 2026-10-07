# Ops Log

One line per action with a side effect outside the working tree:
**timestamp · what · why · how to undo · verified?**

- 2026-10-07 08:26–08:31 PT · Created a 64 MB exFAT disk image in the Claude scratchpad, mounted it hidden (`-nobrowse`) under the scratchpad 3 times for the exFAT tests, then detached it each time · test copy/move/migrate against exFAT (the format of "Extreme Pro") · undo: nothing to undo; image is in the session scratchpad only · verified: `hdiutil detach` succeeded each time and the image was empty after tests
- 2026-10-07 08:29 PT · Launched `build/Mac Space Finder.app` once with `-StartPath ~/PROJECTS` (pid 220) · smoke test that the app starts · undo: quit the app · verified: process running, no crash report, no error/fault log entries. Nothing was written to any disk by the app.
- 2026-10-07 · `git init` + first local commit in this folder (no remote, nothing pushed) · user's standing rule: commit after build · undo: `rm -rf .git` · verified: `git log`
