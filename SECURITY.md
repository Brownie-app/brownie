# Security

Brownie reads private data — messages, mail, files — on the user's Mac. Bugs that could leak that data are the ones we care about most.

**Report privately** through GitHub's private vulnerability reporting: https://github.com/Brownie-app/brownie/security/advisories/new — only the maintainers see it. Please don't open a public issue. Expect an acknowledgement within 3 days.

In scope: anything that lets raw data leave the Mac, lets a sensitive item leave a trace, lets Hands act without the user's tap, weakens the root wake helper (socket permissions, deadman), or exposes stored keys.

Out of scope: issues in the user's chosen brain provider, or in TDLib/LiteRT-LM/Sparkle themselves (report those upstream, but tell us too).

## Handling of secrets in this repo

Founder-only credentials live in `.secrets/brownie.env`, which is git-ignored and read only by Debug builds. If you ever find a real key in the history, report it as above; it will be rotated.
