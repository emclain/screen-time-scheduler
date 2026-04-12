See [AGENTS.md](AGENTS.md) for all agent instructions.


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

See AGENTS.md for the full Land + Reflect procedure. In brief — work is NOT
complete until `git push` succeeds:

```bash
bd export > .beads/issues.jsonl
git add .beads/issues.jsonl
git diff --cached --quiet || git commit -m "bd sync: <description>"
git fetch origin main && git merge origin/main
git push
```

Never use `git pull --rebase` (use merge) or `bd dolt push` (no remote configured).
<!-- END BEADS INTEGRATION -->
