#!/bin/zsh
# Fixtures must be invented. This refuses a change that puts a real person back into the repo.
#
# It reads only the lines a change ADDS, so the cost of a false positive is one line of a diff and never a
# bisect through history. Three checks, in order of how sure each one is:
#
#   1. A value we have already scrubbed, coming back. Exact, and never wrong — but the whole point of the scrub
#      was to get those strings out of the repository, so they cannot be listed here in the clear. What is
#      stored is a truncated SHA-256 of each one, and the check hashes the words of your diff to compare. The
#      list is write-only: you can add to it (Scripts/scrubbed-digests.txt) without ever publishing what it
#      holds.
#   2. A phone number that is not from the fixture block. Only digits in a telephone-shaped context count — a
#      leading +, or a phone:/whatsapp:/imessage:/telegram: handle — so hash constants and unix timestamps,
#      which are the same length, are left alone.
#   3. An email at a domain that is not a documentation domain.
#
# Usage:
#   ./Scripts/no-real-data.sh                 # lines your working tree adds on top of main
#   ./Scripts/no-real-data.sh --staged        # lines you are about to commit
#   ./Scripts/no-real-data.sh <base>..<head>  # lines a range adds (what CI runs)
set -u
cd "$(dirname "$0")/.."

# The fixture blocks. Anything outside them has to be invented before it can be committed.
#   phones: +91 90000 0xxxx — a real Indian prefix so formatting and last-10 matching behave, a body no
#           operator issues. The 10-digit form is 900000xxxx.
#   email:  the RFC 2606 documentation domains, plus the project's own.
PHONE_OK='^(91)?900000[0-9]{4}$'
# RFC 2606 and RFC 6761 set aside .test, .example, .invalid and example.com/.org/.net precisely so that nobody
# has to invent a domain and accidentally pick a real one. A fixture company goes at <name>.test.
DOMAIN_OK='^(.+\.)?(test|example|invalid|localhost)$|^(.+\.)?example\.(com|org|net)$'
# Domains that are a real service on purpose, where the fixture is the local part and the domain is the shape
# being tested: an Apple address has to look like one. The local part still has to be invented.
DOMAIN_SERVICE_OK='^(icloud\.com|s\.whatsapp\.net|usebrownie\.com|anthropic\.com|users\.noreply\.github\.com)$'
# Whole addresses that are deliberately real: the project's own inboxes, and senders a fixture names.
EMAIL_LITERAL_OK='^(security|hello|conduct)@usebrownie\.com$|^billing@google\.com$|^noreply@'

DIGESTS=Scripts/scrubbed-digests.txt

# macOS ships shasum, Linux ships sha256sum; CI runs this on whichever is cheaper that day.
if whence -p shasum >/dev/null 2>&1; then sha() { shasum -a 256 }; else sha() { sha256sum }; fi

case "${1:-}" in
  --staged) DIFF=(git diff --cached --unified=0) ;;
  "")       DIFF=(git diff --unified=0 main...HEAD) ;;
  *)        DIFF=(git diff --unified=0 "$1") ;;
esac

# Only added lines, and never this script or its own digest list — both are allowed to describe the patterns.
added=$("${DIFF[@]}" -- . ':(exclude)Scripts/no-real-data.sh' ':(exclude)Scripts/scrubbed-digests.txt' \
        | grep '^+' | grep -v '^+++' | sed 's/^+//')
[ -z "$added" ] && { echo "no added lines to check"; exit 0 }

fail=0
say() { fail=1; printf '  %s\n' "$1" }

# 1. Something we scrubbed, coming back.
if [ -s "$DIGESTS" ]; then
  # Every word and every digit run in the diff, folded the way the list was built: lower-cased, 4 characters
  # or more. Hashed one per line, then compared against the stored prefixes.
  hits=$(print -r -- "$added" \
    | tr '[:upper:]' '[:lower:]' | grep -oE '[a-z]{4,}|[0-9]{4,}' | sort -u \
    | while read -r w; do
        printf '%s %s\n' "$(printf '%s' "$w" | sha | cut -c1-12)" "$w"
      done \
    | grep -Ff <(grep -vE '^\s*(#|$)' "$DIGESTS" | awk '{print $1}') - 2>/dev/null)
  if [ -n "$hits" ]; then
    echo "A value that was scrubbed from this repository is back:"
    print -r -- "$hits" | while read -r _ w; do say "\"$w\" — invent one instead; see CONTRIBUTING.md \"Fixtures are invented\""; done
  fi
fi

# 2. A telephone number from outside the fixture block.
print -r -- "$added" | grep -oiE '(\+|phone:|whatsapp:\+?|imessage:\+?|telegram:\+?|tel:\+?)[0-9][0-9 .-]{8,17}' \
  | sed -E 's/^[^0-9]*//; s/[ .-]//g' | sort -u \
  | while read -r n; do
      # Under ten digits is not a telephone number — it is a placeholder like "+91 90000 0xxxx" with the body
      # written out, or a partial run that the surrounding text continues in letters.
      [ ${#n} -ge 10 ] || continue
      [[ "$n" =~ $PHONE_OK ]] || say "phone \"$n\" is not from the fixture block (+91 90000 0xxxx)"
    done

# 3. An email outside the documentation domains.
print -r -- "$added" | grep -oiE '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}' | tr '[:upper:]' '[:lower:]' | sort -u \
  | while read -r e; do
      [[ "$e" =~ $EMAIL_LITERAL_OK ]] && continue
      d="${e##*@}"
      [[ "$d" =~ $DOMAIN_OK || "$d" =~ $DOMAIN_SERVICE_OK ]] \
        || say "email \"$e\" is at \"$d\", which is somebody's real domain — fixtures go at <name>.test"
    done

if [ "$fail" -ne 0 ]; then
  cat <<'EOF'

Fixtures in this repository are invented people. Real names, numbers and addresses are not test data: this is
an app that reads someone's messages, and the repository is public, so a contact who lands in a doc comment is
published. Use the cast in CONTRIBUTING.md, and if you are certain a flagged line is fine, say why in the PR.
EOF
  exit 1
fi
echo "no real-looking people in the added lines"
