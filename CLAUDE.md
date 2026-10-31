# Working in this repository

Brownie reads someone's messages. This repository is public. Those two facts together decide most of what
follows, and the first rule is the one that has actually been broken.

## Fixtures are invented — never real

**Never put a real person into this repository.** Not in a test, not in a doc comment, not in a commit message,
not in a prompt or an eval case, not "just as an example".

That means no real phone number, email address, postal address, person's name, company name, group or chat
name, account id, registry or cloud account number, container image name, device id, or message text copied
from a real conversation. It applies to the person writing the code, to their colleagues, and to anyone who
ever appeared in a chat on the machine the work was done on.

It is easy to do by accident, because the natural way to write a test for this app is to paste in something
that actually happened. It has happened here: a contact's mobile number reached 89 places across 17 files and
was public for weeks, and a cloud account id sat in a test fixture next to its region.

Use the invented cast and the fixture blocks in [CONTRIBUTING.md](CONTRIBUTING.md#fixtures-are-invented).
`./Scripts/no-real-data.sh` checks the lines a change adds, and CI runs it on every pull request.

If you need a realistic case from real data, **re-write it** before it lands: change the name, change the
number, change the amount, keep the shape. The shape is the only part a test needs.

## Everything else

The invariants, the layering rule, what "covered" means for tests, and the clean-room rule are in
[CONTRIBUTING.md](CONTRIBUTING.md). Read it before a first change; it is short and every rule in it has a test
behind it.

Two things worth knowing before you run anything:

- `swift test` runs the unit suites in seconds. `swift test --filter EvalTests` additionally needs the 3.7 GB
  on-device reader, so leave it out unless you are changing a prompt.
- Credentials live in `.secrets/brownie.env`, which is git-ignored and read only by Debug builds. Never move a
  key out of it, never echo one in a test, and never paste one into a commit message or an issue.
